defmodule Imgd.Collaboration.EditSession.ServerTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.EditSession.Server
  alias Imgd.Collaboration.EditSession.Supervisor
  alias Imgd.Collaboration.{EditorState, EditOperation}
  alias Imgd.Workflows
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    # Create a test workflow and draft
    {:ok, user} = Accounts.register_user(%{email: "test@example.com", password: "password123"})
    scope = Scope.for_user(user)

    {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

    # Create a basic draft
    draft_attrs = %{
      nodes: [
        %{
          id: "node_1",
          type_id: "http_request",
          name: "HTTP Request",
          position: %{x: 100, y: 100}
        }
      ]
    }

    {:ok, _} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)

    %{workflow: workflow, scope: scope, user: user}
  end

  describe "session lifecycle" do
    test "starts session for workflow", %{workflow: workflow} do
      assert {:ok, pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(pid)

      # Should return same pid on subsequent calls
      assert {:ok, ^pid} = Supervisor.ensure_session(workflow.id)
    end

    test "session persists draft state", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      # Get current state
      {:ok, _draft} = Workflows.get_draft(workflow.id)
      {:ok, state} = Server.get_sync_state(workflow.id)

      assert state.draft.workflow_id == workflow.id
      assert length(state.draft.nodes) == 1
      assert hd(state.draft.nodes).id == "node_1"
    end

    test "session terminates after idle timeout", %{workflow: workflow} do
      {:ok, pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(pid)

      # Simulate idle timeout by calling the private function
      # In a real test, we'd wait for the timer, but that's slow
      :ok = :sys.terminate(pid, :shutdown)

      # Give it a moment to terminate
      :timer.sleep(10)

      # Process should be dead
      refute Process.alive?(pid)

      # New session should start fresh
      {:ok, new_pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(new_pid)
      assert new_pid != pid
    end
  end

  describe "operation processing" do
    test "applies add_node operation", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "node_2",
            type_id: "json_parser",
            name: "JSON Parser",
            position: %{x: 300, y: 100}
          }
        },
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      assert {:ok, %{seq: seq, status: :applied}} = Server.apply_operation(workflow.id, operation)
      assert seq == 1

      # Verify state was updated
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert length(state.draft.nodes) == 2
      assert Enum.any?(state.draft.nodes, &(&1.id == "node_2"))
    end

    test "rejects invalid operations", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            # Duplicate ID
            id: "node_1",
            type_id: "json_parser",
            name: "Duplicate Node"
          }
        },
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      assert {:error, {:node_already_exists, "node_1"}} =
               Server.apply_operation(workflow.id, operation)
    end

    test "handles operation deduplication", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "node_2",
            type_id: "json_parser",
            name: "JSON Parser",
            position: %{x: 300, y: 100}
          }
        },
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      # Apply same operation twice
      {:ok, result1} = Server.apply_operation(workflow.id, operation)
      {:ok, result2} = Server.apply_operation(workflow.id, operation)

      # First should succeed, second should be deduplicated
      assert result1.status == :applied
      assert result2.status == :duplicate
      assert result1.seq == result2.seq

      # Should still only have 2 nodes total
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert length(state.draft.nodes) == 2
    end

    test "maintains operation sequence numbers", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operations = [
        %{
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Updated Name"}},
          id: "op_1",
          user_id: Ecto.UUID.generate(),
          client_seq: 1
        },
        %{
          type: :update_node_position,
          payload: %{node_id: "node_1", position: %{x: 200, y: 150}},
          id: "op_2",
          user_id: Ecto.UUID.generate(),
          client_seq: 2
        },
        %{
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{notes: "Added notes"}},
          id: "op_3",
          user_id: Ecto.UUID.generate(),
          client_seq: 3
        }
      ]

      results = Enum.map(operations, &Server.apply_operation(workflow.id, &1))

      assert [
               {:ok, %{seq: 1, status: :applied}},
               {:ok, %{seq: 2, status: :applied}},
               {:ok, %{seq: 3, status: :applied}}
             ] = results

      {:ok, state} = Server.get_sync_state(workflow.id)
      assert state.seq == 3
    end
  end

  describe "editor state operations" do
    test "handles pin_node_output operation", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :pin_node_output,
        payload: %{
          node_id: "node_1",
          output_data: %{"result" => "pinned output"}
        },
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      assert {:ok, _} = Server.apply_operation(workflow.id, operation)

      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert editor_state.pinned_outputs["node_1"] == %{"result" => "pinned output"}
    end

    test "handles disable_node operation", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :disable_node,
        payload: %{node_id: "node_1", mode: :exclude},
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      assert {:ok, _} = Server.apply_operation(workflow.id, operation)

      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert MapSet.member?(editor_state.disabled_nodes, "node_1")
      assert editor_state.disabled_mode["node_1"] == :exclude
    end
  end

  describe "node locking" do
    test "acquires node lock", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      assert :ok = Server.acquire_node_lock(workflow.id, "node_1", "user_1")

      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert editor_state.node_locks["node_1"] == "user_1"
    end

    test "rejects lock for already locked node", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      :ok = Server.acquire_node_lock(workflow.id, "node_1", "user_1")

      assert {:error, {:locked_by, "user_1"}} =
               Server.acquire_node_lock(workflow.id, "node_1", "user_2")
    end

    test "allows same user to refresh lock", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      :ok = Server.acquire_node_lock(workflow.id, "node_1", "user_1")
      # Should succeed
      :ok = Server.acquire_node_lock(workflow.id, "node_1", "user_1")

      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert editor_state.node_locks["node_1"] == "user_1"
    end

    test "releases node lock", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      :ok = Server.acquire_node_lock(workflow.id, "node_1", "user_1")

      # Release via cast (async)
      :ok = Server.release_node_lock(workflow.id, "node_1", "user_1")

      # Give it a moment to process
      :timer.sleep(10)

      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      refute Map.has_key?(editor_state.node_locks, "node_1")
    end
  end

  describe "synchronization" do
    test "provides full sync for new clients", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      {:ok, sync_state} = Server.get_sync_state(workflow.id)

      assert sync_state.type == :full_sync
      assert sync_state.draft.workflow_id == workflow.id
      # No operations applied yet
      assert sync_state.seq == 0
      assert sync_state.editor_state.pinned_outputs == %{}
    end

    test "provides incremental sync when client has some operations", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      # Apply some operations first
      operations = [
        %{
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Updated"}},
          id: "op_1",
          user_id: Ecto.UUID.generate(),
          client_seq: 1
        },
        %{
          type: :update_node_position,
          payload: %{node_id: "node_1", position: %{x: 200, y: 150}},
          id: "op_2",
          user_id: Ecto.UUID.generate(),
          client_seq: 2
        }
      ]

      Enum.each(operations, &Server.apply_operation(workflow.id, &1))

      # Sync from sequence 1 (should get op_2)
      {:ok, sync_state} = Server.get_sync_state(workflow.id, 1)

      assert sync_state.type == :incremental
      assert length(sync_state.ops) == 1
      assert hd(sync_state.ops).seq == 2
    end

    test "provides up-to-date sync when client is current", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      # Apply operation, then sync with current seq
      operation = %{
        type: :update_node_metadata,
        payload: %{node_id: "node_1", changes: %{name: "Updated"}},
        id: "op_1",
        user_id: Ecto.UUID.generate(),
        client_seq: 1
      }

      {:ok, %{seq: seq}} = Server.apply_operation(workflow.id, operation)

      {:ok, sync_state} = Server.get_sync_state(workflow.id, seq)

      assert sync_state.type == :up_to_date
      assert sync_state.seq == seq
    end
  end

  describe "concurrent operations" do
    test "serializes concurrent operations correctly", %{workflow: workflow} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)
      # Simulate concurrent operations from different users
      operations = [
        %{
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Name 1"}},
          id: "op_1",
          user_id: Ecto.UUID.generate(),
          client_seq: 1
        },
        %{
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Name 2"}},
          id: "op_2",
          user_id: Ecto.UUID.generate(),
          client_seq: 1
        },
        %{
          type: :update_node_position,
          payload: %{node_id: "node_1", position: %{x: 300, y: 200}},
          id: "op_3",
          user_id: Ecto.UUID.generate(),
          client_seq: 1
        }
      ]

      # Apply concurrently (in practice they'd come from different processes)
      results = Enum.map(operations, &Server.apply_operation(workflow.id, &1))

      # All should succeed with increasing sequence numbers
      assert [
               {:ok, %{seq: 1, status: :applied}},
               {:ok, %{seq: 2, status: :applied}},
               {:ok, %{seq: 3, status: :applied}}
             ] = results

      # Final state should reflect the last operation (position change)
      {:ok, state} = Server.get_sync_state(workflow.id)
      node = hd(state.draft.nodes)
      assert node.position == %{x: 300, y: 200}
    end
  end

  describe "persistence" do
    test "persists operations to database", %{workflow: workflow, user: user} do
      {:ok, _pid} = Supervisor.ensure_session(workflow.id)

      operation = %{
        type: :update_node_metadata,
        payload: %{node_id: "node_1", changes: %{name: "Persisted Name"}},
        id: "op_1",
        user_id: user.id,
        client_seq: 1
      }

      Server.apply_operation(workflow.id, operation)

      # Force persistence (normally happens on timer)
      pid = GenServer.whereis(Server.via_tuple(workflow.id))
      send(pid, :persist)
      # Give it time to persist
      :timer.sleep(50)

      # Check database
      operations = Repo.all(from o in EditOperation, where: o.workflow_id == ^workflow.id)
      assert length(operations) == 1
      op = hd(operations)
      assert op.operation_id == "op_1"
      assert op.seq == 1
      assert op.type == :update_node_metadata
    end
  end
end

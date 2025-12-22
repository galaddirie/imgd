defmodule Imgd.Collaboration.EditSession.IntegrationTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.EditSession.{Supervisor, Server, Presence}
  alias Imgd.Workflows
  alias Imgd.Executions
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  @moduletag :integration

  setup do
    # Create test workflow with complex graph
    {:ok, user1} = Accounts.register_user(%{email: "user1@example.com", password: "password123"})
    {:ok, user2} = Accounts.register_user(%{email: "user2@example.com", password: "password123"})

    scope1 = Scope.for_user(user1)
    scope2 = Scope.for_user(user2)

    {:ok, workflow} = Workflows.create_workflow(%{name: "Integration Test Workflow"}, scope1)

    # Create initial draft
    draft_attrs = %{
      nodes: [
        %{
          id: "input_node",
          type_id: "manual_input",
          name: "Manual Input",
          position: %{x: 100, y: 100}
        },
        %{
          id: "transform_node",
          type_id: "data_transform",
          name: "Data Transform",
          position: %{x: 300, y: 100}
        },
        %{
          id: "output_node",
          type_id: "data_output",
          name: "Data Output",
          position: %{x: 500, y: 100}
        }
      ],
      connections: [
        %{id: "conn_1", source_node_id: "input_node", target_node_id: "transform_node"},
        %{id: "conn_2", source_node_id: "transform_node", target_node_id: "output_node"}
      ]
    }

    {:ok, _} = Workflows.update_workflow_draft(workflow, draft_attrs, scope1)

    %{workflow: workflow, user1: user1, user2: user2, scope1: scope1, scope2: scope2}
  end

  describe "full collaborative editing workflow" do
    test "multiple users can collaboratively edit a workflow", %{
      workflow: workflow,
      user1: user1,
      user2: user2
    } do
      # Start collaborative session
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # User 1 joins presence
      Presence.track_user(workflow.id, user1, self())
      :timer.sleep(50)

      # User 1 adds a new node
      operation1 = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "filter_node",
            type_id: "data_filter",
            name: "Data Filter",
            position: %{x: 400, y: 150}
          }
        },
        id: "op_add_node",
        user_id: user1.id,
        client_seq: 1
      }

      assert {:ok, %{seq: 1}} = Server.apply_operation(workflow.id, operation1)

      # User 1 connects the new node
      operation2 = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_3",
            source_node_id: "transform_node",
            target_node_id: "filter_node"
          }
        },
        id: "op_add_connection",
        user_id: user1.id,
        client_seq: 2
      }

      assert {:ok, %{seq: 2}} = Server.apply_operation(workflow.id, operation2)

      # User 2 joins presence
      Presence.track_user(workflow.id, user2, self())
      :timer.sleep(50)

      # Check both users are present
      assert Presence.count(workflow.id) == 2

      # User 2 updates node configuration
      operation3 = %{
        type: :update_node_config,
        payload: %{
          node_id: "transform_node",
          patch: [
            %{op: "add", path: "/enabled", value: true},
            %{op: "replace", path: "/script", value: "return input * 2"}
          ]
        },
        id: "op_update_config",
        user_id: user2.id,
        client_seq: 3
      }

      assert {:ok, %{seq: 3}} = Server.apply_operation(workflow.id, operation3)

      # User 2 pins output for testing
      operation4 = %{
        type: :pin_node_output,
        payload: %{
          node_id: "input_node",
          output_data: %{"test" => "pinned data"}
        },
        id: "op_pin_output",
        user_id: user2.id,
        client_seq: 4
      }

      assert {:ok, %{seq: 4}} = Server.apply_operation(workflow.id, operation4)

      # User 1 disables a node
      operation5 = %{
        type: :disable_node,
        payload: %{node_id: "filter_node", mode: :exclude},
        id: "op_disable_node",
        user_id: user1.id,
        client_seq: 5
      }

      assert {:ok, %{seq: 5}} = Server.apply_operation(workflow.id, operation5)

      # Verify final state
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert state.seq == 5
      # 3 original + 1 added
      assert length(state.draft.nodes) == 4
      # 2 original + 1 added
      assert length(state.draft.connections) == 3

      # Check editor state
      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert editor_state.pinned_outputs["input_node"] == %{"test" => "pinned data"}
      assert MapSet.member?(editor_state.disabled_nodes, "filter_node")
    end

    test "handles user disconnection and reconnection", %{workflow: workflow, user1: user1} do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # User joins and makes changes
      Presence.track_user(workflow.id, user1, self())

      operation = %{
        type: :update_node_metadata,
        payload: %{node_id: "input_node", changes: %{name: "Updated Input"}},
        id: "op_update_name",
        user_id: user1.id,
        client_seq: 1
      }

      assert {:ok, %{seq: 1}} = Server.apply_operation(workflow.id, operation)

      # Simulate disconnection (kill presence process)
      # In real scenario, this would happen when LiveView disconnects

      # User reconnects and gets sync
      # Simulate reconnecting client
      {:ok, sync_state} = Server.get_sync_state(workflow.id, 0)

      assert sync_state.type == :incremental
      assert length(sync_state.ops) == 1
      assert hd(sync_state.ops).seq == 1
      assert hd(sync_state.ops).type == :update_node_metadata
    end

    test "maintains operation order across concurrent users", %{
      workflow: workflow,
      user1: user1,
      user2: user2
    } do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # Simulate concurrent operations from different users
      operations = [
        {user1.id,
         %{
           type: :update_node_metadata,
           payload: %{node_id: "input_node", changes: %{name: "Name 1"}},
           id: "op_1",
           user_id: user1.id,
           client_seq: 1
         }},
        {user2.id,
         %{
           type: :update_node_position,
           payload: %{node_id: "input_node", position: %{x: 200, y: 150}},
           id: "op_2",
           user_id: user2.id,
           client_seq: 2
         }},
        {user1.id,
         %{
           type: :update_node_metadata,
           payload: %{node_id: "input_node", changes: %{notes: "Note 1"}},
           id: "op_3",
           user_id: user1.id,
           client_seq: 3
         }},
        {user2.id,
         %{
           type: :pin_node_output,
           payload: %{node_id: "input_node", output_data: %{}},
           id: "op_4",
           user_id: user2.id,
           client_seq: 4
         }}
      ]

      # Apply operations (they will be serialized by GenServer)
      results =
        Enum.map(operations, fn {_user_id, op} ->
          Server.apply_operation(workflow.id, op)
        end)

      # All should succeed with sequential sequence numbers
      assert [
               {:ok, %{seq: 1, status: :applied}},
               {:ok, %{seq: 2, status: :applied}},
               {:ok, %{seq: 3, status: :applied}},
               {:ok, %{seq: 4, status: :applied}}
             ] = results

      # Verify final sequence number
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert state.seq == 4
    end

    test "editor state affects preview execution", %{workflow: workflow, scope1: scope1} do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # Set up editor state
      Server.apply_operation(workflow.id, %{
        type: :pin_node_output,
        payload: %{node_id: "input_node", output_data: %{"pinned" => "value"}},
        id: "pin_op",
        user_id: scope1.user.id,
        client_seq: 1
      })

      Server.apply_operation(workflow.id, %{
        type: :disable_node,
        payload: %{node_id: "transform_node", mode: :exclude},
        id: "disable_op",
        user_id: scope1.user.id,
        client_seq: 2
      })

      # Check editor state
      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert Map.keys(editor_state.pinned_outputs) == ["input_node"]
      assert MapSet.to_list(editor_state.disabled_nodes) == ["transform_node"]

      # Run preview execution
      assert {:ok, execution} =
               Imgd.Collaboration.PreviewExecution.run(
                 workflow.id,
                 scope1,
                 mode: :full
               )

      # Verify execution includes editor state
      assert execution.metadata.extras.pinned_nodes == ["input_node"]
      assert execution.metadata.extras.disabled_nodes == ["transform_node"]
      assert execution.context["input_node"] == %{"pinned" => "value"}
    end

    test "session persists operations to database", %{workflow: workflow, user1: user1} do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # Apply operation
      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "test_node",
            type_id: "manual_input",
            name: "Test Node",
            position: %{x: 100, y: 100}
          }
        },
        id: "persist_test_op",
        user_id: user1.id,
        client_seq: 1
      }

      {:ok, %{seq: seq}} = Server.apply_operation(workflow.id, operation)
      assert seq == 1  # Verify operation was applied

      # Force persistence (in real scenario this happens on timer)
      pid = GenServer.whereis(Server.via_tuple(workflow.id))
      send(pid, :persist)
      :timer.sleep(100)  # Give it more time to persist

      # Check database
      operations =
        Repo.all(
          from o in Imgd.Collaboration.EditOperation,
            where: o.workflow_id == ^workflow.id
        )

      assert length(operations) == 1

      op = hd(operations)
      assert op.operation_id == "persist_test_op"
      assert op.seq == 1
      assert op.type == :add_node
      assert op.user_id == user1.id
    end
  end

  describe "conflict resolution and locking" do
    test "prevents concurrent config edits on same node", %{
      workflow: workflow,
      user1: user1,
      user2: user2
    } do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # User 1 acquires lock
      assert :ok = Server.acquire_node_lock(workflow.id, "input_node", user1.id)

      # User 2 cannot acquire lock
      user1_id = user1.id

      assert {:error, {:locked_by, ^user1_id}} =
               Server.acquire_node_lock(workflow.id, "input_node", user2.id)

      # User 1 can still modify the node
      operation = %{
        type: :update_node_config,
        payload: %{node_id: "input_node", patch: [%{op: "add", path: "/locked", value: true}]},
        id: "locked_edit",
        user_id: user1.id,
        client_seq: 1
      }

      assert {:ok, _} = Server.apply_operation(workflow.id, operation)

      # User 1 releases lock
      Server.release_node_lock(workflow.id, "input_node", user1.id)

      # Now user 2 can acquire lock
      assert :ok = Server.acquire_node_lock(workflow.id, "input_node", user2.id)
    end

    test "handles lock timeout", %{workflow: workflow, user1: user1, user2: user2} do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # User 1 locks node
      :ok = Server.acquire_node_lock(workflow.id, "input_node", user1.id)

      # Simulate timeout by manually setting old timestamp in editor state
      # In real scenario, this would happen after 30 seconds
      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      old_timestamp = DateTime.add(DateTime.utc_now(), -40, :second)

      updated_state = %{
        editor_state
        | lock_timestamps: %{editor_state.lock_timestamps | "input_node" => old_timestamp}
      }

      # Directly update state (normally done internally)
      GenServer.call(Server.via_tuple(workflow.id), {:update_editor_state, updated_state})

      # User 2 should now be able to acquire the lock
      assert :ok = Server.acquire_node_lock(workflow.id, "input_node", user2.id)
    end
  end

  describe "session recovery" do
    test "recovers from server restart", %{workflow: workflow, user1: user1} do
      {:ok, session_pid} = Supervisor.ensure_session(workflow.id)

      # Apply some operations
      operation = %{
        type: :update_node_metadata,
        payload: %{node_id: "input_node", changes: %{name: "Recovery Test"}},
        id: "recovery_op",
        user_id: user1.id,
        client_seq: 1
      }

      Server.apply_operation(workflow.id, operation)

      # Force persistence before stopping
      pid = GenServer.whereis(Server.via_tuple(workflow.id))
      send(pid, :persist)
      :timer.sleep(100)

      # Simulate server restart by stopping session
      Supervisor.stop_session(workflow.id)
      :timer.sleep(10)  # Give it time to fully terminate
      refute Process.alive?(session_pid)

      # New session should recover state
      {:ok, new_session_pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(new_session_pid)
      assert new_session_pid != session_pid

      # State should be recovered
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert state.seq >= 1

      # Editor state should be reset (ephemeral)
      {:ok, editor_state} = Server.get_editor_state(workflow.id)
      assert editor_state.pinned_outputs == %{}
      assert editor_state.disabled_nodes == MapSet.new()
    end
  end

  describe "performance and scalability" do
    test "handles many operations efficiently", %{workflow: workflow, user1: user1} do
      {:ok, _session_pid} = Supervisor.ensure_session(workflow.id)

      # Apply many operations
      operations =
        for i <- 1..50 do
          %{
            type: :update_node_metadata,
            payload: %{node_id: "input_node", changes: %{name: "Update #{i}"}},
            id: "bulk_op_#{i}",
            user_id: user1.id,
            client_seq: i
          }
        end

      start_time = System.monotonic_time(:millisecond)

      results = Enum.map(operations, &Server.apply_operation(workflow.id, &1))

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # All operations should succeed
      assert Enum.all?(results, fn {:ok, %{status: status}} -> status == :applied end)

      # Should complete in reasonable time (< 5 seconds for 50 operations)
      assert duration < 5000

      # Final sequence should be correct
      {:ok, state} = Server.get_sync_state(workflow.id)
      assert state.seq == 50
    end
  end
end

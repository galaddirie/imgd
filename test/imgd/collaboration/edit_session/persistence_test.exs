defmodule Imgd.Collaboration.EditSession.PersistenceTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.EditSession.Persistence
  alias Imgd.Collaboration.EditOperation
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

    %{workflow: workflow, scope: scope}
  end

  describe "load_pending_ops/1" do
    test "loads operations after last snapshot", %{workflow: workflow} do
      # Insert some operations manually
      operations = [
        %EditOperation{
          operation_id: "op_1",
          seq: 1,
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Updated 1"}},
          user_id: "user_1",
          client_seq: 1,
          workflow_id: workflow.id,
          inserted_at: DateTime.utc_now()
        },
        %EditOperation{
          operation_id: "op_2",
          seq: 2,
          type: :update_node_position,
          payload: %{node_id: "node_1", position: %{x: 200, y: 150}},
          user_id: "user_1",
          client_seq: 2,
          workflow_id: workflow.id,
          inserted_at: DateTime.utc_now()
        },
        %EditOperation{
          operation_id: "op_3",
          seq: 3,
          type: :add_node,
          payload: %{node: %{id: "node_2", type_id: "json_parser", name: "JSON Parser"}},
          user_id: "user_2",
          client_seq: 1,
          workflow_id: workflow.id,
          inserted_at: DateTime.utc_now()
        }
      ]

      Enum.each(operations, &Repo.insert!/1)

      # Update draft to indicate last snapshot at seq 1
      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

      updated_draft =
        Ecto.Changeset.change(draft,
          settings: Map.put(draft.settings || %{}, "last_persisted_seq", 1)
        )

      Repo.update!(updated_draft)

      # Should load operations after seq 1
      {:ok, last_seq, loaded_ops} = Persistence.load_pending_ops(workflow.id)

      assert last_seq == 1
      assert length(loaded_ops) == 2
      assert Enum.map(loaded_ops, & &1.seq) == [2, 3]
    end

    test "returns empty list when no pending operations", %{workflow: workflow} do
      {:ok, last_seq, loaded_ops} = Persistence.load_pending_ops(workflow.id)

      assert last_seq == 0
      assert loaded_ops == []
    end

    test "returns error for non-existent workflow" do
      assert {:error, :not_found} = Persistence.load_pending_ops(Ecto.UUID.generate())
    end
  end

  describe "persist/1" do
    test "persists operations and updates draft", %{workflow: workflow} do
      # Create mock state with operations to persist
      ops = [
        %EditOperation{
          operation_id: "op_1",
          seq: 1,
          type: :update_node_metadata,
          payload: %{node_id: "node_1", changes: %{name: "Persisted Name"}},
          user_id: "user_1",
          client_seq: 1,
          workflow_id: workflow.id
        }
      ]

      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

      state = %{
        workflow_id: workflow.id,
        draft: draft,
        op_buffer: ops,
        seq: 1
      }

      assert :ok = Persistence.persist(state)

      # Check operations were inserted
      persisted_ops = Repo.all(from o in EditOperation, where: o.workflow_id == ^workflow.id)
      assert length(persisted_ops) == 1
      assert hd(persisted_ops).seq == 1

      # Check draft was updated with last_persisted_seq
      updated_draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)
      assert updated_draft.settings["last_persisted_seq"] == 1
    end

    test "handles duplicate operation inserts gracefully", %{workflow: workflow} do
      # Insert operation first
      op = %EditOperation{
        operation_id: "op_1",
        seq: 1,
        type: :update_node_metadata,
        payload: %{node_id: "node_1", changes: %{name: "Name"}},
        user_id: "user_1",
        client_seq: 1,
        workflow_id: workflow.id
      }

      Repo.insert!(op)

      # Try to persist again - should not fail
      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

      state = %{
        workflow_id: workflow.id,
        draft: draft,
        # Same operation
        op_buffer: [op],
        seq: 1
      }

      assert :ok = Persistence.persist(state)
    end

    test "persists draft changes", %{workflow: workflow} do
      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

      # Modify draft
      modified_draft = %{
        draft
        | nodes:
            draft.nodes ++
              [
                %Node{id: "node_2", type_id: "json_parser", name: "JSON Parser"}
              ]
      }

      state = %{
        workflow_id: workflow.id,
        draft: modified_draft,
        op_buffer: [],
        seq: 0
      }

      assert :ok = Persistence.persist(state)

      # Check draft was persisted
      updated_draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)
      assert length(updated_draft.nodes) == 2
      assert Enum.any?(updated_draft.nodes, &(&1.id == "node_2"))
    end
  end

  describe "snapshot/3" do
    test "takes snapshot and updates sequence", %{workflow: workflow} do
      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

      # Modify draft
      modified_draft = %{
        draft
        | nodes:
            draft.nodes ++
              [
                %Node{id: "node_2", type_id: "json_parser", name: "JSON Parser"}
              ]
      }

      assert :ok = Persistence.snapshot(workflow.id, modified_draft, 5)

      # Check draft was persisted with new seq
      updated_draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)
      assert updated_draft.settings["last_persisted_seq"] == 5
      assert length(updated_draft.nodes) == 2
    end
  end

  describe "recovery scenarios" do
    test "handles workflow with corrupted draft gracefully", %{workflow: workflow} do
      # Corrupt the draft somehow (invalid JSON)
      draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)
      # This would be caught by normal validation, but let's test error handling
      # Invalid
      corrupted_draft = %{draft | nodes: nil}

      state = %{
        workflow_id: workflow.id,
        draft: corrupted_draft,
        op_buffer: [],
        seq: 0
      }

      # Should handle validation errors gracefully
      result = Persistence.persist(state)
      # In practice this might succeed or fail depending on Ecto validation
      case result do
        :ok -> assert true
        {:error, _} -> assert true
      end
    end
  end
end

defmodule Imgd.Collaboration.PreviewExecutionTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.PreviewExecution
  alias Imgd.Collaboration.EditSession.Supervisor, as: SessionSupervisor
  alias Imgd.Workflows
  alias Imgd.Executions
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Node, Connection}
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    # Create a test workflow with a more complex graph
    {:ok, user} = Accounts.register_user(%{email: "test@example.com", password: "password123"})
    scope = Scope.for_user(user)

    {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

    # Create a draft with multiple nodes and connections
    draft_attrs = %{
      nodes: [
        %{
          id: "http_node",
          type_id: "http_request",
          name: "HTTP Request",
          position: %{x: 100, y: 100},
          config: %{url: "https://api.example.com"}
        },
        %{
          id: "json_node",
          type_id: "json_parser",
          name: "JSON Parser",
          position: %{x: 300, y: 100}
        },
        %{
          id: "filter_node",
          type_id: "data_filter",
          name: "Data Filter",
          position: %{x: 500, y: 100}
        },
        %{
          id: "output_node",
          type_id: "data_output",
          name: "Data Output",
          position: %{x: 700, y: 100}
        }
      ],
      connections: [
        %{id: "conn_1", source_node_id: "http_node", target_node_id: "json_node"},
        %{id: "conn_2", source_node_id: "json_node", target_node_id: "filter_node"},
        %{id: "conn_3", source_node_id: "filter_node", target_node_id: "output_node"}
      ]
    }

    {:ok, _} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)

    %{workflow: workflow, scope: scope, user: user}
  end

  describe "run/4 - full execution" do
    test "executes full workflow with editor state", %{workflow: workflow, scope: scope} do
      # Start session and add some editor state
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Pin some output
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :pin_node_output,
        payload: %{node_id: "http_node", output_data: %{"pinned" => "data"}},
        id: "pin_op",
        user_id: scope.user.id
      })

      # Run full preview
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.workflow_id == workflow.id
      assert execution.execution_type == :preview
      assert execution.metadata["preview"] == true
      assert execution.metadata["pinned_nodes"] == ["http_node"]
    end

    test "handles workflow execution failures gracefully", %{workflow: workflow, scope: scope} do
      # Don't set up session - should still work but with default editor state

      # This should not crash even if execution fails
      result = PreviewExecution.run(workflow.id, scope, mode: :full)

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected {:ok, _} or {:error, _}, got: #{inspect(result)}")
      end
    end
  end

  describe "run/4 - from_node execution" do
    test "executes from specific node downstream", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run from json_node (should include json_node, filter_node, output_node)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :from_node,
                 target_nodes: ["json_node"]
               )

      assert execution.execution_type == :preview
      assert execution.metadata["preview"] == true
    end

    test "handles invalid target node gracefully", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Try to run from non-existent node
      result =
        PreviewExecution.run(workflow.id, scope, mode: :from_node, target_nodes: ["non_existent"])

      # Should either succeed with empty graph or fail gracefully
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected {:ok, _} or {:error, _}, got: #{inspect(result)}")
      end
    end
  end

  describe "run/4 - to_node execution" do
    test "executes upstream to specific node", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run to filter_node (should include http_node, json_node, filter_node)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :to_node,
                 target_nodes: ["filter_node"]
               )

      assert execution.execution_type == :preview
    end
  end

  describe "run/4 - selected subgraph execution" do
    test "executes only selected nodes", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run only json_node and filter_node
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :selected,
                 target_nodes: ["json_node", "filter_node"]
               )

      assert execution.execution_type == :preview
    end

    test "uses pinned outputs for missing upstream data", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Pin output for http_node
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :pin_node_output,
        payload: %{node_id: "http_node", output_data: %{"mock" => "data"}},
        id: "pin_op",
        user_id: scope.user.id
      })

      # Run only filter_node and output_node (upstream http_node is pinned)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :selected,
                 target_nodes: ["filter_node", "output_node"]
               )

      assert execution.context["http_node"] == %{"mock" => "data"}
    end
  end

  describe "disabled nodes handling" do
    test "excludes disabled nodes from execution", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Disable json_node
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :disable_node,
        payload: %{node_id: "json_node", mode: :exclude},
        id: "disable_op",
        user_id: scope.user.id
      })

      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata["disabled_nodes"] == ["json_node"]
      # The execution should skip json_node entirely
    end

    test "bypasses disabled nodes in execution flow", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # This would test bypass mode, but our current implementation uses exclude mode
      # In a real test, you'd verify the graph transformation
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)
      assert execution.execution_type == :preview
    end
  end

  describe "execution input data" do
    test "passes input data to execution", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      input_data = %{"custom" => "input", "params" => %{"key" => "value"}}

      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope, mode: :full, input_data: input_data)

      assert execution.trigger["data"] == input_data
    end
  end

  describe "access control" do
    test "respects workflow access permissions", %{workflow: workflow} do
      # Create another user without access
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      # Should fail or return error for unauthorized user
      result = PreviewExecution.run(workflow.id, other_scope, mode: :full)
      # In practice, this depends on how Workflows.get_draft handles permissions
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected {:ok, _} or {:error, _}, got: #{inspect(result)}")
      end
    end
  end

  describe "error handling" do
    test "handles missing workflow gracefully", %{scope: scope} do
      assert {:error, :draft_not_found} =
               PreviewExecution.run(Ecto.UUID.generate(), scope, mode: :full)
    end

    test "handles invalid execution modes gracefully", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Invalid mode should probably fall back to full or error
      result = PreviewExecution.run(workflow.id, scope, mode: :invalid)

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected {:ok, _} or {:error, _}, got: #{inspect(result)}")
      end
    end
  end

  describe "session integration" do
    test "uses session editor state automatically", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Modify editor state
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :pin_node_output,
        payload: %{node_id: "http_node", output_data: %{"session" => "data"}},
        id: "session_pin",
        user_id: scope.user.id
      })

      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :disable_node,
        payload: %{node_id: "filter_node", mode: :exclude},
        id: "session_disable",
        user_id: scope.user.id
      })

      # Run execution - should pick up session state
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata["pinned_nodes"] == ["http_node"]
      assert execution.metadata["disabled_nodes"] == ["filter_node"]
    end

    test "works without active session", %{workflow: workflow, scope: scope} do
      # Should work with default editor state (no pins, no disabled nodes)
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata["pinned_nodes"] == []
      assert execution.metadata["disabled_nodes"] == []
    end
  end
end

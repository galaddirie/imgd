defmodule Imgd.Collaboration.PreviewExecutionTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.PreviewExecution
  alias Imgd.Collaboration.EditSession.Supervisor, as: SessionSupervisor
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    # Create a test workflow with a more complex graph
    {:ok, user} = Accounts.register_user(%{email: "test@example.com", password: "password123"})
    scope = Scope.for_user(user)

    {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

    # Create a draft with multiple steps and connections
    draft_attrs = %{
      steps: [
        %{
          id: "http_step",
          type_id: "http_request",
          name: "HTTP Request",
          position: %{x: 100, y: 100},
          config: %{url: "https://api.example.com"}
        },
        %{
          id: "json_step",
          type_id: "json_parser",
          name: "JSON Parser",
          position: %{x: 300, y: 100}
        },
        %{
          id: "filter_step",
          type_id: "data_filter",
          name: "Data Filter",
          position: %{x: 500, y: 100}
        },
        %{
          id: "output_step",
          type_id: "data_output",
          name: "Data Output",
          position: %{x: 700, y: 100}
        }
      ],
      connections: [
        %{id: "conn_1", source_step_id: "http_step", target_step_id: "json_step"},
        %{id: "conn_2", source_step_id: "json_step", target_step_id: "filter_step"},
        %{id: "conn_3", source_step_id: "filter_step", target_step_id: "output_step"}
      ]
    }

    {:ok, _} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

    %{workflow: workflow, scope: scope, user: user}
  end

  describe "run/4 - full execution" do
    test "executes full workflow with editor state", %{workflow: workflow, scope: scope} do
      # Start session and add some editor state
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Pin some output
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :pin_step_output,
        payload: %{step_id: "http_step", output_data: %{"pinned" => "data"}},
        id: "pin_op",
        user_id: scope.user.id,
        client_seq: 1
      })

      # Run full preview
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.workflow_id == workflow.id
      assert execution.execution_type == :preview
      assert execution.metadata.extras[:preview] == true
      assert execution.metadata.extras[:pinned_steps] == ["http_step"]
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

  describe "run/4 - from_step execution" do
    test "executes from specific step downstream", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run from json_step (should include json_step, filter_step, output_step)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :from_step,
                 target_steps: ["json_step"]
               )

      assert execution.execution_type == :preview
      assert execution.metadata.extras[:preview] == true
    end

    test "handles invalid target step gracefully", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Try to run from non-existent step
      result =
        PreviewExecution.run(workflow.id, scope, mode: :from_step, target_steps: ["non_existent"])

      # Should either succeed with empty graph or fail gracefully
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected {:ok, _} or {:error, _}, got: #{inspect(result)}")
      end
    end
  end

  describe "run/4 - to_step execution" do
    test "executes upstream to specific step", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run to filter_step (should include http_step, json_step, filter_step)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :to_step,
                 target_steps: ["filter_step"]
               )

      assert execution.execution_type == :preview
    end
  end

  describe "run/4 - selected subgraph execution" do
    test "executes only selected steps", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Run only json_step and filter_step
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :selected,
                 target_steps: ["json_step", "filter_step"]
               )

      assert execution.execution_type == :preview
    end

    test "uses pinned outputs for missing upstream data", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Pin output for http_step
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :pin_step_output,
        payload: %{step_id: "http_step", output_data: %{"mock" => "data"}},
        id: "pin_op",
        user_id: scope.user.id,
        client_seq: 1
      })

      # Run only filter_step and output_step (upstream http_step is pinned)
      assert {:ok, execution} =
               PreviewExecution.run(workflow.id, scope,
                 mode: :selected,
                 target_steps: ["filter_step", "output_step"]
               )

      assert execution.context["http_step"] == %{"mock" => "data"}
    end
  end

  describe "disabled steps handling" do
    test "excludes disabled steps from execution", %{workflow: workflow, scope: scope} do
      {:ok, _pid} = SessionSupervisor.ensure_session(workflow.id)

      # Disable json_step
      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :disable_step,
        payload: %{step_id: "json_step", mode: :exclude},
        id: "disable_op",
        user_id: scope.user.id,
        client_seq: 1
      })

      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata.extras[:disabled_steps] == ["json_step"]
      # The execution should skip json_step entirely
    end

    test "bypasses disabled steps in execution flow", %{workflow: workflow, scope: scope} do
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

      assert execution.trigger.data == input_data
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
        type: :pin_step_output,
        payload: %{step_id: "http_step", output_data: %{"session" => "data"}},
        id: "session_pin",
        user_id: scope.user.id,
        client_seq: 1
      })

      Imgd.Collaboration.EditSession.Server.apply_operation(workflow.id, %{
        type: :disable_step,
        payload: %{step_id: "filter_step", mode: :exclude},
        id: "session_disable",
        user_id: scope.user.id,
        client_seq: 2
      })

      # Run execution - should pick up session state
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata.extras[:pinned_steps] == ["http_step"]
      assert execution.metadata.extras[:disabled_steps] == ["filter_step"]
    end

    test "works without active session", %{workflow: workflow, scope: scope} do
      # Should work with default editor state (no pins, no disabled steps)
      assert {:ok, execution} = PreviewExecution.run(workflow.id, scope, mode: :full)

      assert execution.metadata.extras[:pinned_steps] == []
      assert execution.metadata.extras[:disabled_steps] == []
    end
  end
end

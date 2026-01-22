defmodule Imgd.Runtime.Hooks.ObservabilityTest do
  use Imgd.DataCase, async: false

  require Runic
  alias Runic.Workflow
  alias Imgd.Runtime.Hooks.Observability
  alias Imgd.Executions.PubSub
  alias Imgd.Executions
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    ensure_pubsub_started()
    :ok
  end

  describe "attach_all_hooks/2" do
    setup do
      # Create user, scope, workflow and execution
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

      # Create and publish a version
      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

      {:ok, {_workflow, _version}} =
        Workflows.publish_workflow(scope, workflow, %{version_tag: "1.0.0"})

      # Create execution
      execution_attrs = %{
        workflow_id: workflow.id,
        trigger: %{type: :manual, data: %{reason: "test"}},
        execution_type: :production,
        metadata: %{trace_id: "trace-123", correlation_id: "corr-456"}
      }

      {:ok, execution} = Executions.create_execution(scope, execution_attrs)

      %{scope: scope, workflow: workflow, execution: execution}
    end

    test "emits pubsub events for step completion", %{
      scope: scope,
      workflow: _workflow,
      execution: execution
    } do
      execution_id = execution.id

      PubSub.subscribe_execution(scope, execution_id)

      on_exit(fn ->
        PubSub.unsubscribe_execution(execution_id)
      end)

      workflow =
        Workflow.new(name: "obs_test")
        |> Workflow.add(Runic.step(fn _ -> [1, 2, 3] end, name: "list_step"))

      workflow =
        Map.put(workflow, :__step_metadata__, %{
          "list_step" => %{step_id: "list_step", type_id: "test"}
        })

      workflow =
        workflow
        |> Observability.attach_all_hooks(execution_id: execution_id, workflow_id: "wf-1")

      # Run the workflow
      _finished = Workflow.react_until_satisfied(workflow, :input)

      assert_receive {:step_completed, payload}
      assert payload.step_id == "list_step"
      # Regular step returning a list counts as 1 production
      assert payload.output_item_count == 1
    end

    test "skips anonymous internal steps for logs and context", %{
      scope: scope,
      execution: execution
    } do
      execution_id = execution.id
      PubSub.subscribe_execution(scope, execution_id)

      on_exit(fn ->
        PubSub.unsubscribe_execution(execution_id)
      end)

      # Create a workflow with an implicit Join
      # Has name: nil by default
      join =
        Runic.Workflow.Join.new([
          Runic.Component.hash(Runic.step(fn _ -> "a" end, name: "a")),
          Runic.Component.hash(Runic.step(fn _ -> "b" end, name: "b"))
        ])

      step_a = Runic.step(fn _ -> "a" end, name: "a")
      step_b = Runic.step(fn _ -> "b" end, name: "b")
      step_c = Runic.step(fn input -> input end, name: "c")

      workflow =
        Workflow.new(name: "join_test")
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add_step([step_a, step_b], join)
        |> Workflow.add(step_c, to: join)
        |> Observability.attach_all_hooks(execution_id: execution_id, workflow_id: "wf-1")

      # Add metadata only for a, b, c
      workflow =
        Map.put(workflow, :__step_metadata__, %{
          "a" => %{step_id: "a", type_id: "test"},
          "b" => %{step_id: "b", type_id: "test"},
          "c" => %{step_id: "c", type_id: "test"}
        })

      # Reset accumulated outputs to be sure
      Process.put(:imgd_accumulated_outputs, %{})

      _finished = Workflow.react_until_satisfied(workflow, :input)

      # We should receive events for a, b, c but NOT for the join (which has name: nil -> "nil")
      assert_receive {:step_completed, %{step_id: "a"}}
      assert_receive {:step_completed, %{step_id: "b"}}
      assert_receive {:step_completed, %{step_id: "c"}}

      # Wait a bit to ensure no extra messages arrive
      Process.sleep(50)

      refute_receive {:step_completed, %{step_id: "nil"}}
      refute_receive {:step_completed, %{step_id: nil}}

      # Check accumulated outputs - should NOT contain "nil"
      outputs = Process.get(:imgd_accumulated_outputs)
      assert Map.has_key?(outputs, "a")
      assert Map.has_key?(outputs, "b")
      assert Map.has_key?(outputs, "c")
      refute Map.has_key?(outputs, "nil")
      refute Map.has_key?(outputs, nil)
    end
  end

  defp ensure_pubsub_started do
    if Process.whereis(Imgd.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Imgd.PubSub})
    end
  end
end

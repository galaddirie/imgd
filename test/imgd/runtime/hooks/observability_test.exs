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

  describe "count_output_items/1" do
    test "counts list outputs and handles nil" do
      assert Observability.count_output_items([1, 2, 3]) == 3
      assert Observability.count_output_items([]) == 0
      assert Observability.count_output_items(nil) == 0
      assert Observability.count_output_items("single") == 1
    end
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

    test "emits telemetry and pubsub events for step completion", %{
      scope: scope,
      workflow: _workflow,
      execution: execution
    } do
      execution_id = execution.id
      handler_id = "obs-telemetry-#{System.unique_integer([:positive])}"

      PubSub.subscribe_execution(scope, execution_id)

      :telemetry.attach(
        handler_id,
        [:imgd, :step, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        PubSub.unsubscribe_execution(execution_id)
        :telemetry.detach(handler_id)
      end)

      workflow =
        Workflow.new(name: "obs_test")
        |> Workflow.add(Runic.step(fn _ -> [1, 2, 3] end, name: "list_step"))
        |> Observability.attach_all_hooks(execution_id: execution_id, workflow_id: "wf-1")

      # Run the workflow
      _finished = Workflow.react_until_satisfied(workflow, :input)

      assert_receive {:step_completed, payload}
      assert payload.step_id == "list_step"
      assert payload.output_item_count == 3

      assert_receive {:telemetry_event, [:imgd, :step, :stop], measurements, metadata}
      assert measurements.duration_us >= 0
      assert metadata.output_item_count == 3
    end
  end

  defp ensure_pubsub_started do
    if Process.whereis(Imgd.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Imgd.PubSub})
    end
  end
end

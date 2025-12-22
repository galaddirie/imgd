defmodule Imgd.Runtime.EventsTest do
  use Imgd.DataCase, async: false

  alias Imgd.Runtime.Events
  alias Imgd.Executions
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    ensure_pubsub_started()
    :ok
  end

  test "emit/3 broadcasts and emits telemetry with sanitized data" do
    # Create user, scope, workflow and execution
    {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
    scope = Scope.for_user(user)
    {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

    # Create and publish a version
    draft_attrs = %{
      nodes: [%{id: "node1", type_id: "input", name: "Input Node", config: %{}}],
      connections: [],
      triggers: [%{type: :manual, config: %{}}]
    }

    {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

    {:ok, {_workflow, version}} =
      Workflows.publish_workflow(scope, workflow, %{version_tag: "1.0.0"})

    # Create execution
    execution_attrs = %{
      workflow_id: workflow.id,
      trigger: %{type: :manual, data: %{reason: "test"}},
      execution_type: :production,
      metadata: %{trace_id: "trace-123", correlation_id: "corr-456"}
    }

    {:ok, execution} = Executions.create_execution(scope, execution_attrs)
    execution_id = execution.id

    handler_id = "events-telemetry-#{System.unique_integer([:positive])}"

    Events.subscribe(scope, execution_id)

    :telemetry.attach(
      handler_id,
      [:imgd, :execution, :event],
      fn event, measurements, metadata, _config ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      Events.unsubscribe(execution_id)
      :telemetry.detach(handler_id)
    end)

    assert :ok = Events.emit(:step_completed, execution_id, %{status: :ok})

    assert_receive {:execution_event, event}
    assert event.type == :step_completed
    assert event.data["status"] == "ok"

    assert_receive {:telemetry_event, [:imgd, :execution, :event], _measurements, metadata}
    assert metadata.type == :step_completed
    assert metadata.execution_id == execution_id
  end

  defp ensure_pubsub_started do
    if Process.whereis(Imgd.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Imgd.PubSub})
    end
  end
end

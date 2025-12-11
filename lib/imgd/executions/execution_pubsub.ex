defmodule Imgd.Workflows.ExecutionPubSub do
  @moduledoc """
  PubSub broadcasting for workflow execution and node execution updates.

  Designed around the `Execution` and `NodeExecution` schemas so LiveViews and
  future engine processes can stay in sync as runs progress.
  """

  alias Imgd.Executions.NodeExecution

  @pubsub Imgd.PubSub

  # Topic patterns
  def execution_topic(execution_id), do: "execution:#{execution_id}"
  def workflow_executions_topic(workflow_id), do: "workflow_executions:#{workflow_id}"

  # Subscribe
  def subscribe_execution(execution_id) do
    Phoenix.PubSub.subscribe(@pubsub, execution_topic(execution_id))
  end

  def subscribe_workflow_executions(workflow_id) do
    Phoenix.PubSub.subscribe(@pubsub, workflow_executions_topic(workflow_id))
  end

  # Broadcast execution lifecycle events
  def broadcast_execution_started(execution) do
    broadcast_execution(:execution_started, execution)
  end

  def broadcast_execution_completed(execution) do
    broadcast_execution(:execution_completed, execution)
  end

  def broadcast_execution_failed(execution, error) do
    broadcast_execution(:execution_failed, execution, error)
  end

  def broadcast_execution_updated(execution) do
    broadcast_execution(:execution_updated, execution)
  end

  # Broadcast node execution events
  def broadcast_node_started(execution, %NodeExecution{} = node_execution) do
    broadcast_node(:node_started, execution, node_execution)
  end

  def broadcast_node_completed(execution, %NodeExecution{} = node_execution) do
    broadcast_node(:node_completed, execution, node_execution)
  end

  def broadcast_node_failed(execution, %NodeExecution{} = node_execution, error \\ nil) do
    payload =
      node_payload(node_execution)
      |> Map.put(:error, error || node_execution.error)

    broadcast(execution.id, {:node_failed, payload})
    broadcast_workflow(execution.workflow_id, {:node_failed, payload})
  end

  # Private helpers

  defp broadcast_execution(event, execution, error \\ nil) do
    message =
      case error do
        nil -> {event, execution}
        _ -> {event, execution, error}
      end

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  defp broadcast_node(event, execution, %NodeExecution{} = node_execution) do
    payload = node_payload(node_execution)
    message = {event, payload}

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  defp node_payload(%NodeExecution{} = node_execution) do
    %{
      id: node_execution.id,
      execution_id: node_execution.execution_id,
      node_id: node_execution.node_id,
      node_type_id: node_execution.node_type_id,
      status: node_execution.status,
      attempt: node_execution.attempt,
      input_data: node_execution.input_data,
      output_data: node_execution.output_data,
      error: node_execution.error,
      started_at: node_execution.started_at,
      completed_at: node_execution.completed_at,
      duration_ms: duration_ms(node_execution.started_at, node_execution.completed_at)
    }
  end

  defp duration_ms(nil, _), do: nil
  defp duration_ms(_, nil), do: nil
  defp duration_ms(started, finished), do: DateTime.diff(finished, started, :millisecond)

  defp broadcast(execution_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, execution_topic(execution_id), message)
  end

  defp broadcast_workflow(workflow_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, workflow_executions_topic(workflow_id), message)
  end
end

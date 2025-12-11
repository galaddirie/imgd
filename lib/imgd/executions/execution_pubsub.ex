defmodule Imgd.Workflows.ExecutionPubSub do
  @moduledoc """
  PubSub broadcasting for workflow execution updates.

  Enables real-time updates to LiveViews tracking execution and step progress.
  """

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
    broadcast(execution.id, {:execution_started, execution})
    broadcast_workflow(execution.workflow_id, {:execution_started, execution})
  end

  def broadcast_execution_completed(execution) do
    broadcast(execution.id, {:execution_completed, execution})
    broadcast_workflow(execution.workflow_id, {:execution_completed, execution})
  end

  def broadcast_execution_failed(execution, error) do
    broadcast(execution.id, {:execution_failed, execution, error})
    broadcast_workflow(execution.workflow_id, {:execution_failed, execution, error})
  end


  # Private helpers
  defp broadcast(execution_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, execution_topic(execution_id), message)
  end

  defp broadcast_workflow(workflow_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, workflow_executions_topic(workflow_id), message)
  end
end

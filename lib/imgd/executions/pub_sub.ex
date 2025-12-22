defmodule Imgd.Executions.PubSub do
  @moduledoc """
  PubSub broadcasting for workflow execution and node execution updates.

  All subscriptions require a valid scope with appropriate permissions.
  This ensures users can only receive updates for resources they have access to.

  ## Topics

  - `execution:{id}` - Updates for a specific execution
  - `workflow_executions:{workflow_id}` - All executions for a workflow

  ## Events

  Execution lifecycle:
  - `{:execution_started, execution}`
  - `{:execution_updated, execution}`
  - `{:execution_completed, execution}`
  - `{:execution_failed, execution, error}`

  Node lifecycle:
  - `{:node_started, node_payload}`
  - `{:node_completed, node_payload}`
  - `{:node_failed, node_payload}`
  """

  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Accounts.Scope

  @pubsub Imgd.PubSub

  # Topic builders

  def execution_topic(execution_id), do: "execution:#{execution_id}"
  def workflow_executions_topic(workflow_id), do: "workflow_executions:#{workflow_id}"

  # ============================================================================
  # Subscriptions (Scope Required)
  # ============================================================================

  @doc """
  Subscribe to updates for a specific execution.

  Requires a scope with view access to the execution's workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if execution doesn't exist.
  """
  @spec subscribe_execution(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_execution(scope, execution_id) do
    case authorize_execution(scope, execution_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, execution_topic(execution_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from a specific execution's updates.
  """
  @spec unsubscribe_execution(String.t()) :: :ok
  def unsubscribe_execution(execution_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, execution_topic(execution_id))
  end

  @doc """
  Subscribe to all execution updates for a workflow.

  Requires a scope with view access to the workflow.
  Returns `:ok` on success, `{:error, :unauthorized}` if access denied,
  or `{:error, :not_found}` if workflow doesn't exist.
  """
  @spec subscribe_workflow_executions(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def subscribe_workflow_executions(scope, workflow_id) do
    case authorize_workflow(scope, workflow_id) do
      :ok ->
        Phoenix.PubSub.subscribe(@pubsub, workflow_executions_topic(workflow_id))
        :ok

      error ->
        error
    end
  end

  @doc """
  Unsubscribe from a workflow's execution updates.
  """
  @spec unsubscribe_workflow_executions(String.t()) :: :ok
  def unsubscribe_workflow_executions(workflow_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, workflow_executions_topic(workflow_id))
  end

  # ============================================================================
  # Authorization
  # ============================================================================

  @doc """
  Checks if the scope can subscribe to updates for a specific execution.

  Returns `:ok` if authorized, `{:error, :not_found}` if execution doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize_execution(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_execution(scope, execution_id) do
    case Imgd.Repo.get(Imgd.Executions.Execution, execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution = Imgd.Repo.preload(execution, :workflow)

        if Scope.can_view_execution?(scope, execution) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Checks if the scope can subscribe to execution updates for a workflow.

  Returns `:ok` if authorized, `{:error, :not_found}` if workflow doesn't exist,
  or `{:error, :unauthorized}` if access denied.
  """
  @spec authorize_workflow(Scope.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized | :not_found}
  def authorize_workflow(scope, workflow_id) do
    case Imgd.Repo.get(Imgd.Workflows.Workflow, workflow_id) do
      nil ->
        {:error, :not_found}

      workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Deprecated: Use `authorize_execution/2` instead.
  """
  @deprecated "Use authorize_execution/2 instead"
  @spec can_subscribe_execution?(Scope.t() | nil, String.t()) :: boolean()
  def can_subscribe_execution?(scope, execution_id) do
    authorize_execution(scope, execution_id) == :ok
  end

  @doc """
  Deprecated: Use `authorize_workflow/2` instead.
  """
  @deprecated "Use authorize_workflow/2 instead"
  @spec can_subscribe_workflow_executions?(Scope.t() | nil, String.t()) :: boolean()
  def can_subscribe_workflow_executions?(scope, workflow_id) do
    authorize_workflow(scope, workflow_id) == :ok
  end

  # ============================================================================
  # Execution lifecycle broadcasts
  # ============================================================================

  @doc "Broadcast that an execution has started."
  def broadcast_execution_started(%Execution{} = execution) do
    broadcast_execution(:execution_started, execution)
  end

  @doc "Broadcast that an execution has been updated."
  def broadcast_execution_updated(%Execution{} = execution) do
    broadcast_execution(:execution_updated, execution)
  end

  @doc "Broadcast that an execution completed successfully."
  def broadcast_execution_completed(%Execution{} = execution) do
    broadcast_execution(:execution_completed, execution)
  end

  @doc "Broadcast that an execution failed."
  def broadcast_execution_failed(%Execution{} = execution, error \\ nil) do
    error = error || execution.error
    message = {:execution_failed, execution, error}

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  # ============================================================================
  # Node execution broadcasts
  # ============================================================================

  @doc "Broadcast that a node has started executing."
  def broadcast_node_started(%Execution{} = execution, %NodeExecution{} = node_execution) do
    payload = build_node_payload(node_execution)
    broadcast_node(:node_started, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast that a node completed successfully."
  def broadcast_node_completed(%Execution{} = execution, %NodeExecution{} = node_execution) do
    payload = build_node_payload(node_execution)
    broadcast_node(:node_completed, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast that a node failed."
  def broadcast_node_failed(
        %Execution{} = execution,
        %NodeExecution{} = node_execution,
        error \\ nil
      ) do
    payload =
      node_execution
      |> build_node_payload()
      |> Map.put(:error, error || node_execution.error)

    broadcast_node(:node_failed, execution.id, execution.workflow_id, payload)
  end

  @doc "Broadcast a node event with a raw payload."
  def broadcast_node(event, execution_id, workflow_id, payload) do
    message = {event, payload}
    broadcast(execution_id, message)
    broadcast_workflow(workflow_id, message)
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp broadcast_execution(event, %Execution{} = execution) do
    message = {event, execution}

    broadcast(execution.id, message)
    broadcast_workflow(execution.workflow_id, message)
  end

  defp build_node_payload(%NodeExecution{} = ne) do
    %{
      id: ne.id,
      execution_id: ne.execution_id,
      node_id: ne.node_id,
      node_type_id: ne.node_type_id,
      status: ne.status,
      attempt: ne.attempt,
      input_data: ne.input_data,
      output_data: ne.output_data,
      error: ne.error,
      queued_at: ne.queued_at,
      started_at: ne.started_at,
      completed_at: ne.completed_at,
      duration_us: NodeExecution.duration_us(ne),
      queue_time_us: NodeExecution.queue_time_us(ne)
    }
  end

  defp build_node_payload(node_data) when is_map(node_data), do: node_data

  defp broadcast(execution_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, execution_topic(execution_id), message)
  end

  defp broadcast_workflow(workflow_id, message) do
    if workflow_id do
      Phoenix.PubSub.broadcast(@pubsub, workflow_executions_topic(workflow_id), message)
    end
  end
end

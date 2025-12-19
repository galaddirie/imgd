defmodule Imgd.Runtime.Execution.EctoPersistence do
  @moduledoc """
  Ecto implementation of the Persistence behaviour.
  """

  @behaviour Imgd.Runtime.Execution.Persistence

  require Logger

  alias Imgd.Repo
  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Runtime.Serializer

  @task_supervisor Imgd.Runtime.Execution.PersistenceSupervisor

  @impl true
  def load_execution(id) do
    Execution
    |> Repo.get(id)
    |> Repo.preload([:workflow_version, :workflow])
    |> case do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  @impl true
  def mark_running(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with %Execution{} = execution <- Repo.get(Execution, id) do
      execution
      |> Execution.changeset(%{status: :running, started_at: now})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @impl true
  def mark_completed(id, output, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    sanitized_output = Serializer.wrap_for_db(output)
    sanitized_context = Serializer.sanitize(context, :string)

    with %Execution{} = execution <- Repo.get(Execution, id) do
      duration_ms =
        if execution.started_at,
          do: DateTime.diff(now, execution.started_at, :millisecond),
          else: 0

      execution
      |> Execution.changeset(%{
        status: :completed,
        completed_at: now,
        output: sanitized_output,
        context: sanitized_context,
        duration_ms: duration_ms
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @impl true
  def mark_failed(id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = Execution.format_error(reason)

    with %Execution{} = execution <- Repo.get(Execution, id) do
      duration_ms =
        if execution.started_at,
          do: DateTime.diff(now, execution.started_at, :millisecond),
          else: 0

      execution
      |> Execution.changeset(%{
        status: :failed,
        completed_at: now,
        error: error,
        duration_ms: duration_ms
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @impl true
  def record_node_start(execution_id, node, input) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    input_data = Serializer.wrap_for_db(input)

    node_exec = %NodeExecution{
      id: Ecto.UUID.generate(),
      execution_id: execution_id,
      node_id: node.id,
      node_type_id: node.type_id,
      status: :running,
      input_data: input_data,
      queued_at: now,
      started_at: now,
      attempt: 1,
      inserted_at: now,
      updated_at: now
    }

    persist_node_start_async(node_exec)

    {:ok, node_exec}
  end

  @impl true
  def record_node_finish(%NodeExecution{} = node_exec, status, result, _duration_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    node_exec = apply_finish(node_exec, status, result, now)

    persist_node_finish_async(node_exec)

    {:ok, node_exec}
  end

  defp apply_finish(%NodeExecution{} = node_exec, status, result, now) do
    base =
      node_exec
      |> Map.put(:status, status)
      |> Map.put(:completed_at, now)
      |> Map.put(:updated_at, now)

    case status do
      :completed ->
        %{base | output_data: lazy_serialize(result), error: nil}

      :failed ->
        %{base | output_data: nil, error: Execution.format_error(result)}

      :skipped ->
        metadata = Map.put(base.metadata || %{}, "skip_reason", inspect(result))
        %{base | output_data: nil, error: nil, metadata: metadata}
    end
  end

  defp persist_node_start_async(%NodeExecution{} = node_exec) do
    attrs = node_exec_attrs(node_exec)

    run_async(
      fn ->
        Repo.insert_all(NodeExecution, [attrs],
          on_conflict: :nothing,
          conflict_target: :id
        )
      end,
      node_exec,
      :start
    )
  end

  defp persist_node_finish_async(%NodeExecution{} = node_exec) do
    attrs = node_exec_attrs(node_exec)

    run_async(
      fn ->
        Repo.insert_all(NodeExecution, [attrs],
          on_conflict:
            {:replace, [:status, :output_data, :error, :metadata, :completed_at, :updated_at]},
          conflict_target: :id
        )
      end,
      node_exec,
      :finish
    )
  end

  defp node_exec_attrs(%NodeExecution{} = node_exec) do
    %{
      id: node_exec.id,
      execution_id: node_exec.execution_id,
      node_id: node_exec.node_id,
      node_type_id: node_exec.node_type_id,
      status: node_exec.status,
      input_data: node_exec.input_data,
      output_data: node_exec.output_data,
      error: node_exec.error,
      metadata: node_exec.metadata || %{},
      queued_at: node_exec.queued_at,
      started_at: node_exec.started_at,
      completed_at: node_exec.completed_at,
      attempt: node_exec.attempt,
      retry_of_id: node_exec.retry_of_id,
      inserted_at: node_exec.inserted_at,
      updated_at: node_exec.updated_at
    }
  end

  defp run_async(fun, %NodeExecution{} = node_exec, action) do
    if Process.whereis(@task_supervisor) do
      Task.Supervisor.start_child(@task_supervisor, fn -> safe_run(fun, node_exec, action) end)
    else
      safe_run(fun, node_exec, action)
    end

    :ok
  end

  defp safe_run(fun, %NodeExecution{} = node_exec, action) do
    try do
      fun.()
    rescue
      exception ->
        Logger.error(
          "node execution persistence failed (#{action}): " <>
            Exception.format(:error, exception, __STACKTRACE__),
          execution_id: node_exec.execution_id,
          node_id: node_exec.node_id,
          node_execution_id: node_exec.id
        )
    end
  end

  # Lazy serialization - only serialize complex structures
  defp lazy_serialize(nil), do: nil
  defp lazy_serialize(v) when is_binary(v) or is_number(v) or is_boolean(v), do: %{"value" => v}
  defp lazy_serialize(v), do: Serializer.wrap_for_db(v)
end

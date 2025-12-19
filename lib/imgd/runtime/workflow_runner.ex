defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution with real-time event broadcasting.

  ## Role in Architecture

  This is the **execution orchestrator** that manages workflow lifecycle:

  - Manages execution state transitions (pending → running → completed/failed/timeout)
  - Delegates workflow building to WorkflowBuilder and execution to the configured engine
  - Handles timeout via Task.yield/Task.shutdown
  - Updates execution records in the database
  - Broadcasts PubSub events for real-time UI updates

  ## Runtime State

  All runtime state (node outputs, timing, etc.) is managed by ExecutionState.
  The Execution struct provides static metadata (trigger data, workflow info, etc.).

  ## Execution Flow

  ```
  User clicks "Run" → Executions.start_and_enqueue_execution/3
  ↓
  Oban picks up job → ExecutionWorker.perform/1
  ↓
  WorkflowRunner.run/2 → WorkflowBuilder.build/4 + WorkflowBuilder.execute/4
  ```
  """

  require Logger

  alias Imgd.Repo
  alias Imgd.Executions.Execution
  alias Imgd.Runtime.{ExecutionState, Serializer, WorkflowBuilder}
  alias Imgd.Observability.Instrumentation

  @default_timeout_ms 300_000

  @type run_result :: {:ok, Execution.t()} | {:error, term()}

  @doc """
  Run a workflow execution.

  This is the main entry point for executing a workflow. It:
  1. Marks the execution as running
  2. Builds the workflow using the configured engine
  3. Executes with timeout handling
  4. Updates the execution record with results
  """
  @spec run(Execution.t()) :: run_result()
  def run(%Execution{} = execution) do
    run(execution, ExecutionState, [])
  end

  @spec run(Execution.t(), module()) :: run_result()
  def run(%Execution{} = execution, state_store) do
    run(execution, state_store, [])
  end

  @spec run(Execution.t(), module(), keyword()) :: run_result()
  def run(%Execution{} = execution, state_store, opts) do
    Instrumentation.trace_execution(execution, fn ->
      do_run(execution, state_store, opts)
    end)
  end

  @doc """
  Run an execution using a provided builder function.

  Used for partial executions where only a subset of nodes are built.
  """
  @spec run_with_builder(Execution.t(), (-> {:ok, term()} | {:error, term()})) :: run_result()
  def run_with_builder(%Execution{} = execution, builder_fun) do
    run_with_builder(execution, builder_fun, ExecutionState)
  end

  @spec run_with_builder(Execution.t(), (-> {:ok, term()} | {:error, term()}), module()) ::
          run_result()
  def run_with_builder(%Execution{} = execution, builder_fun, state_store)
      when is_function(builder_fun, 0) do
    Instrumentation.trace_execution(execution, fn ->
      with {:ok, execution} <- mark_running(execution),
           {:ok, executable} <- builder_fun.(),
           result <- execute_with_timeout(execution, executable, state_store) do
        handle_execution_result(execution, result)
      else
        {:error, reason} -> mark_failed(execution, reason)
      end
    end)
  end

  # ===========================================================================
  # Core Execution Flow
  # ===========================================================================

  defp do_run(%Execution{} = execution, state_store, opts) do
    with {:ok, execution} <- mark_running(execution),
         {:ok, executable} <- build_workflow(execution, state_store, opts),
         result <- execute_with_timeout(execution, executable, state_store) do
      handle_execution_result(execution, result)
    else
      {:error, reason} ->
        mark_failed(execution, reason)
    end
  end

  defp build_workflow(execution, state_store, opts) do
    source = execution.workflow_version || execution.workflow

    case WorkflowBuilder.build(source, execution, state_store, opts) do
      {:ok, executable} ->
        {:ok, executable}

      {:error, reason} ->
        Logger.error("Failed to build workflow",
          execution_id: execution.id,
          reason: inspect(reason)
        )

        {:error, {:workflow_build_failed, reason}}
    end
  end

  defp handle_execution_result(execution, {:ok, result}) do
    handle_result(execution, {:ok, result})
  end

  defp handle_execution_result(execution, {:error, reason}) do
    mark_failed(execution, reason)
  end

  defp handle_execution_result(execution, {:timeout, _}) do
    handle_result(execution, {:timeout, nil})
  end

  # ===========================================================================
  # Execution Lifecycle
  # ===========================================================================

  defp mark_running(%Execution{} = execution) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update(Execution.changeset(execution, %{status: :running, started_at: now})) do
      {:ok, execution} ->
        Instrumentation.record_execution_started(execution)
        {:ok, execution}

      {:error, changeset} ->
        {:error, {:update_failed, changeset}}
    end
  end

  defp mark_completed(%Execution{} = execution, output, node_outputs, engine_logs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    duration_ms =
      case execution.started_at do
        nil -> 0
        started_at -> DateTime.diff(now, started_at, :millisecond)
      end

    sanitized_output = Serializer.sanitize(output, :string)
    sanitized_context = Serializer.sanitize(node_outputs, :string)

    update_attrs = %{
      status: :completed,
      completed_at: now,
      output: sanitized_output,
      context: sanitized_context
    }

    # Store engine logs if present
    update_attrs = maybe_add_engine_logs(update_attrs, engine_logs)

    case Repo.update(Execution.changeset(execution, update_attrs)) do
      {:ok, execution} ->
        Instrumentation.record_execution_completed(execution, duration_ms)
        {:ok, execution}

      {:error, changeset} ->
        {:error, {:update_failed, changeset}}
    end
  end

  defp mark_failed(%Execution{} = execution, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    duration_ms =
      case execution.started_at do
        nil -> 0
        started_at -> DateTime.diff(now, started_at, :millisecond)
      end

    error = Execution.format_error(reason)

    case Repo.update(
           Execution.changeset(execution, %{status: :failed, completed_at: now, error: error})
         ) do
      {:ok, execution} ->
        Instrumentation.record_execution_failed(execution, error, duration_ms)
        {:error, reason}

      {:error, changeset} ->
        Logger.error("Failed to mark execution as failed",
          execution_id: execution.id,
          changeset_errors: inspect(changeset.errors)
        )

        {:error, reason}
    end
  end

  defp mark_timeout(%Execution{} = execution) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    duration_ms =
      case execution.started_at do
        nil -> 0
        started_at -> DateTime.diff(now, started_at, :millisecond)
      end

    error = %{
      "type" => "timeout",
      "message" => "Workflow execution timed out",
      "timeout_ms" => get_timeout_ms(execution)
    }

    case Repo.update(
           Execution.changeset(execution, %{status: :timeout, completed_at: now, error: error})
         ) do
      {:ok, execution} ->
        Instrumentation.record_execution_failed(execution, error, duration_ms)
        {:ok, execution}

      {:error, changeset} ->
        Logger.error("Failed to mark execution as timeout",
          execution_id: execution.id,
          changeset_errors: inspect(changeset.errors)
        )

        {:ok, %{execution | status: :timeout}}
    end
  end

  # ===========================================================================
  # Execution with Timeout
  # ===========================================================================

  defp execute_with_timeout(%Execution{} = execution, executable, state_store) do
    timeout_ms = get_timeout_ms(execution)
    trigger_data = Execution.trigger_data(execution)

    state_store.start(execution.id)

    task =
      Task.async(fn ->
        execute_workflow(executable, trigger_data, execution, state_store)
      end)

    result =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, reason}

        nil ->
          Logger.warning("Workflow execution timed out",
            execution_id: execution.id,
            timeout_ms: timeout_ms
          )

          {:timeout, nil}
      end

    state_store.cleanup(execution.id)
    result
  end

  defp get_timeout_ms(%Execution{} = execution) do
    source = execution.workflow_version || execution.workflow

    settings =
      case source do
        %{workflow: %{settings: s}} when is_map(s) -> s
        %{settings: s} when is_map(s) -> s
        _ -> %{}
      end

    Map.get(settings, "timeout_ms") || Map.get(settings, :timeout_ms) || @default_timeout_ms
  end

  # ===========================================================================
  # Workflow Execution (via Engine)
  # ===========================================================================

  defp execute_workflow(executable, initial_input, execution, state_store) do
    Logger.debug("Starting workflow execution",
      execution_id: execution.id,
      trigger_input: inspect(initial_input)
    )

    case WorkflowBuilder.execute(executable, initial_input, execution, state_store) do
      {:ok, result} ->
        Logger.debug("Workflow execution completed",
          execution_id: execution.id
        )

        {:ok, result}

      {:error, reason} ->
        Logger.error("Workflow execution failed",
          execution_id: execution.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ===========================================================================
  # Result Handling
  # ===========================================================================

  defp handle_result(
         execution,
         {:ok, %{output: output, node_outputs: outputs, engine_logs: logs}}
       ) do
    mark_completed(execution, output, outputs, logs)
  end

  defp handle_result(execution, {:timeout, _}) do
    mark_timeout(execution)
  end

  defp maybe_add_engine_logs(attrs, %{build_log: build_log, execution_log: exec_log}) do
    attrs
    |> Map.put(:engine_build_log, build_log)
    |> Map.put(:engine_execution_log, exec_log)
  end

  defp maybe_add_engine_logs(attrs, _), do: attrs
end

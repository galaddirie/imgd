defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution with real-time event broadcasting.

  ## Role in Architecture

  This is the **execution orchestrator** that manages workflow lifecycle:

  - Manages execution state transitions (pending → running → completed/failed/timeout)
  - Delegates workflow building and execution to the configured ExecutionEngine
  - Handles timeout via Task.yield/Task.shutdown
  - Updates execution records in the database
  - Broadcasts PubSub events for real-time UI updates

  ## Engine Abstraction

  The actual workflow execution is delegated to the configured `ExecutionEngine`.
  By default, this is `Imgd.Runtime.Engines.Runic`, but can be swapped by
  configuring `:imgd, :execution_engine` in your application config.

  ## Separation of Concerns

  | Concern | ExecutionWorker | WorkflowRunner | ExecutionEngine |
  |---------|-----------------|----------------|-----------------|
  | Job queuing/retries | ✓ | | |
  | Trace context propagation | ✓ | | |
  | Loading records from DB | ✓ | | |
  | Execution state machine | | ✓ | |
  | Timeout handling | | ✓ | |
  | PubSub broadcasts | | ✓ | |
  | Workflow building | | | ✓ |
  | Node execution | | | ✓ |

  ## Execution Flow

  ```
  User clicks "Run" → Executions.start_and_enqueue_execution/3
  ↓
  Oban picks up job → ExecutionWorker.perform/1
  ↓
  WorkflowRunner.run/1 → ExecutionEngine.build/3 + ExecutionEngine.execute/3
  ```
  """

  require Logger

  alias Imgd.Repo
  alias Imgd.Executions.{Execution, Context}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{ExecutionEngine, ExecutionState, Serializer}
  alias Imgd.Observability.Instrumentation

  @default_timeout_ms 300_000
  @raw_input_key "__imgd_raw_input__"

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
    Instrumentation.trace_execution(execution, fn ->
      do_run(execution)
    end)
  end

  @doc """
  Run an execution using a provided builder function and precomputed context.

  Used for partial executions where only a subset of nodes are built.
  """
  @spec run_with_builder(Execution.t(), Context.t(), (-> {:ok, term()} | {:error, term()})) ::
          run_result()
  def run_with_builder(%Execution{} = execution, %Context{} = context, builder_fun)
      when is_function(builder_fun, 0) do
    Instrumentation.trace_execution(execution, fn ->
      with {:ok, execution} <- mark_running(execution),
           {:ok, executable} <- builder_fun.(),
           result <- execute_with_timeout(execution, executable, context) do
        handle_execution_result(execution, result)
      else
        {:error, reason} -> mark_failed(execution, reason)
      end
    end)
  end

  # ===========================================================================
  # Core Execution Flow
  # ===========================================================================

  defp do_run(%Execution{} = execution) do
    with {:ok, execution} <- mark_running(execution),
         {:ok, context} <- build_context(execution),
         {:ok, executable} <- build_workflow(execution, context),
         result <- execute_with_timeout(execution, executable, context) do
      handle_execution_result(execution, result)
    else
      {:error, reason} ->
        mark_failed(execution, reason)
    end
  end

  defp build_workflow(execution, context) do
    case ExecutionEngine.build(execution.workflow_version, context, execution) do
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

  defp handle_execution_result(execution, {:timeout, context}) do
    handle_result(execution, {:timeout, context})
  end

  # ===========================================================================
  # Execution Lifecycle
  # ===========================================================================

  defp mark_running(%Execution{} = execution) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update(Execution.changeset(execution, %{status: :running, started_at: now})) do
      {:ok, execution} ->
        ExecutionPubSub.broadcast_execution_started(execution)
        {:ok, execution}

      {:error, changeset} ->
        {:error, {:update_failed, changeset}}
    end
  end

  defp mark_completed(%Execution{} = execution, output, node_outputs, engine_logs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
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
        ExecutionPubSub.broadcast_execution_completed(execution)
        {:ok, execution}

      {:error, changeset} ->
        {:error, {:update_failed, changeset}}
    end
  end

  defp mark_failed(%Execution{} = execution, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = format_error(reason)

    case Repo.update(
           Execution.changeset(execution, %{status: :failed, completed_at: now, error: error})
         ) do
      {:ok, execution} ->
        ExecutionPubSub.broadcast_execution_failed(execution, error)
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

    error = %{
      "type" => "timeout",
      "message" => "Workflow execution timed out",
      "timeout_ms" => get_timeout_ms(execution)
    }

    case Repo.update(
           Execution.changeset(execution, %{status: :timeout, completed_at: now, error: error})
         ) do
      {:ok, execution} ->
        ExecutionPubSub.broadcast_execution_failed(execution, error)
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
  # Context Building
  # ===========================================================================

  defp build_context(%Execution{} = execution) do
    trigger_data = Execution.trigger_data(execution)
    initial_input = extract_trigger_input(trigger_data)
    context = Context.new(execution, current_node_id: nil, current_input: initial_input)
    {:ok, context}
  end

  # ===========================================================================
  # Execution with Timeout
  # ===========================================================================

  defp execute_with_timeout(%Execution{} = execution, executable, context) do
    timeout_ms = get_timeout_ms(execution)
    trigger_data = Execution.trigger_data(execution)
    initial_input = extract_trigger_input(trigger_data)

    ExecutionState.start(execution.id)

    task =
      Task.async(fn ->
        execute_workflow(executable, initial_input, context)
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

          {:timeout, context}
      end

    ExecutionState.cleanup(execution.id)
    result
  end

  defp get_timeout_ms(%Execution{} = execution) do
    case execution.workflow_version do
      %{workflow: %{settings: settings}} when is_map(settings) ->
        Map.get(settings, "timeout_ms") || Map.get(settings, :timeout_ms) || @default_timeout_ms

      _ ->
        @default_timeout_ms
    end
  end

  defp extract_trigger_input(%{@raw_input_key => raw}), do: raw
  defp extract_trigger_input(%{_imgd_raw_input__: raw}), do: raw
  defp extract_trigger_input(%{} = data), do: data
  defp extract_trigger_input(other), do: other

  # ===========================================================================
  # Workflow Execution (via Engine)
  # ===========================================================================

  defp execute_workflow(executable, initial_input, context) do
    Logger.debug("Starting workflow execution",
      execution_id: context.execution_id,
      trigger_input: inspect(initial_input)
    )

    case ExecutionEngine.execute(executable, initial_input, context) do
      {:ok, result} ->
        Logger.debug("Workflow execution completed",
          execution_id: context.execution_id
        )

        {:ok, result}

      {:error, reason} ->
        Logger.error("Workflow execution failed",
          execution_id: context.execution_id,
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

  defp handle_result(execution, {:timeout, _context}) do
    mark_timeout(execution)
  end

  defp maybe_add_engine_logs(attrs, %{build_log: build_log, execution_log: exec_log}) do
    attrs
    |> Map.put(:engine_build_log, build_log)
    |> Map.put(:engine_execution_log, exec_log)
  end

  defp maybe_add_engine_logs(attrs, _), do: attrs

  # ===========================================================================
  # Error Formatting
  # ===========================================================================

  defp format_error(reason) do
    case reason do
      {:node_failed, node_id, node_reason} ->
        %{"type" => "node_failure", "node_id" => node_id, "reason" => inspect(node_reason)}

      {:workflow_build_failed, build_reason} ->
        %{"type" => "workflow_build_failed", "reason" => inspect(build_reason)}

      {:build_failed, message} ->
        %{"type" => "build_failure", "message" => message}

      {:cycle_detected, node_ids} ->
        %{"type" => "cycle_detected", "node_ids" => node_ids}

      {:invalid_connections, connections} ->
        %{
          "type" => "invalid_connections",
          "connections" => Enum.map(connections, &Map.from_struct/1)
        }

      {:update_failed, changeset} ->
        %{"type" => "update_failed", "errors" => inspect(changeset.errors)}

      {:unexpected_error, message} ->
        %{"type" => "unexpected_error", "message" => message}

      {:caught_error, kind, caught_reason} ->
        %{"type" => "caught_error", "kind" => inspect(kind), "reason" => inspect(caught_reason)}

      other ->
        %{"type" => "unknown", "reason" => inspect(other)}
    end
  end
end

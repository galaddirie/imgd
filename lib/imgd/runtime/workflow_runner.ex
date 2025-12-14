defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution using Runic with real-time event broadcasting.

  ## Role in Architecture

  This is the **core execution engine** that actually runs workflows:

  - Manages execution lifecycle (pending → running → completed/failed/timeout)
  - Builds a Runic workflow from the WorkflowVersion via WorkflowBuilder
  - Executes with timeout handling using Task.yield/Task.shutdown
  - Updates execution records in the database
  - Broadcasts PubSub events for real-time UI updates
  - Handles error formatting and context accumulation

  ## Separation of Concerns

  Unlike `ExecutionWorker` which handles job queuing, this module focuses on the execution logic itself.
  This separation allows `WorkflowRunner.run/1` to be called directly for synchronous execution
  (like in tests or preview mode) without needing Oban, while `ExecutionWorker` provides the production
  async execution path.

  | Concern | ExecutionWorker | WorkflowRunner |
  |---------|-----------------|----------------|
  | Job queuing/retries | ✓ | |
  | Trace context propagation | ✓ | |
  | Loading records from DB | ✓ | |
  | Execution state machine | | ✓ |
  | Timeout handling | | ✓ |
  | PubSub broadcasts | | ✓ |
  | Runic integration | | ✓ |

  ## Execution Flow

  ```
  User clicks "Run" → Executions.start_and_enqueue_execution/3 → Creates Execution + Oban job
  ↓
  Oban picks up job → ExecutionWorker.perform/1 (loads data, handles Oban lifecycle)
  ↓
  WorkflowRunner.run/1 (actual execution engine) → WorkflowBuilder.build/3 → Runic execution
  ```

  This module:
  - Manages execution lifecycle (pending → running → completed/failed)
  - Delegates node-level tracking to Runic hooks installed by WorkflowBuilder
  - Broadcasts execution-level PubSub events
  """

  require Logger
  alias Runic.Workflow
  alias Imgd.Repo
  alias Imgd.Executions.{Execution, Context}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{ExecutionState, NodeExecutionError, WorkflowBuilder}
  alias Imgd.Observability.Instrumentation

  @default_timeout_ms 300_000
  @raw_input_key "__imgd_raw_input__"

  @type run_result :: {:ok, Execution.t()} | {:error, term()}

  @spec run(Execution.t()) :: run_result()
  def run(%Execution{} = execution) do
    Instrumentation.trace_execution(execution, fn ->
      do_run(execution)
    end)
  end

  defp do_run(%Execution{} = execution) do
    with {:ok, execution} <- mark_running(execution),
         {:ok, context} <- build_context(execution),
         {:ok, runic_workflow} <- build_workflow_safe(execution, context),
         result <- execute_with_timeout(execution, runic_workflow, context) do
      handle_execution_result(execution, result)
    else
      {:error, reason} ->
        mark_failed(execution, reason)
    end
  end

  defp build_workflow_safe(execution, context) do
    case WorkflowBuilder.build(execution.workflow_version, context, execution) do
      {:ok, workflow} ->
        {:ok, workflow}

      {:error, reason} ->
        Logger.error("Failed to build workflow",
          execution_id: execution.id,
          reason: inspect(reason)
        )

        {:error, {:workflow_build_failed, reason}}
    end
  end

  defp handle_execution_result(execution, {:ok, result}),
    do: handle_result(execution, {:ok, result})

  defp handle_execution_result(execution, {:error, reason}), do: mark_failed(execution, reason)

  defp handle_execution_result(execution, {:timeout, context}),
    do: handle_result(execution, {:timeout, context})

  # ============================================================================
  # Execution Lifecycle
  # ============================================================================

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

  defp mark_completed(%Execution{} = execution, output, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sanitized_output = sanitize_for_json(output)
    sanitized_context = sanitize_for_json(context.node_outputs)

    case Repo.update(
           Execution.changeset(execution, %{
             status: :completed,
             completed_at: now,
             output: sanitized_output,
             context: sanitized_context
           })
         ) do
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

  # ============================================================================
  # Context & Workflow Building
  # ============================================================================

  defp build_context(%Execution{} = execution) do
    trigger_data = Execution.trigger_data(execution)
    initial_input = extract_trigger_input(trigger_data)
    context = Context.new(execution, current_node_id: nil, current_input: initial_input)
    {:ok, context}
  end

  # ============================================================================
  # Execution with Timeout
  # ============================================================================

  defp execute_with_timeout(%Execution{} = execution, runic_workflow, context) do
    timeout_ms = get_timeout_ms(execution)
    trigger_data = Execution.trigger_data(execution)
    initial_input = extract_trigger_input(trigger_data)

    ExecutionState.start(execution.id)

    task =
      Task.async(fn ->
        execute_workflow(execution, runic_workflow, initial_input, context)
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

  # ============================================================================
  # Workflow Execution
  #
  # Uses Runic's built-in execution with hooks for node-level tracking.
  # Node events are broadcast via hooks installed in WorkflowBuilder.
  # ============================================================================

  defp execute_workflow(execution, runic_workflow, initial_input, context) do
    try do
      Logger.debug("Starting workflow execution",
        execution_id: execution.id,
        trigger_input: inspect(initial_input)
      )

      # Run the workflow to completion using Runic's react_until_satisfied
      # This will invoke all steps in topological order, firing hooks automatically
      executed_workflow = Workflow.react_until_satisfied(runic_workflow, initial_input)

      # Extract results
      productions = Workflow.raw_productions(executed_workflow)
      build_log = extract_build_log(executed_workflow)
      reaction_log = extract_reaction_log(executed_workflow)
      output = determine_output(productions)

      node_outputs = ExecutionState.outputs(execution.id)
      final_context = %{context | node_outputs: Map.merge(context.node_outputs, node_outputs)}

      Logger.debug("Workflow execution completed",
        execution_id: execution.id,
        productions_count: length(productions)
      )

      store_runic_logs(execution, build_log, reaction_log)

      {:ok, {output, final_context}}
    rescue
      e in NodeExecutionError ->
        Logger.error("Node execution failed",
          execution_id: execution.id,
          node_id: e.node_id,
          node_type_id: e.node_type_id,
          reason: inspect(e.reason)
        )

        {:error, {:node_failed, e.node_id, e.reason}}

      e ->
        Logger.error("Unexpected error during workflow execution",
          execution_id: execution.id,
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, {:unexpected_error, Exception.message(e)}}
    catch
      kind, reason ->
        Logger.error("Caught error during workflow execution",
          execution_id: execution.id,
          kind: kind,
          reason: inspect(reason),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, {:caught_error, kind, reason}}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extract_build_log(workflow) do
    try do
      workflow |> Workflow.build_log() |> Enum.map(&serialize_event/1)
    rescue
      _ -> []
    end
  end

  defp extract_reaction_log(workflow) do
    try do
      workflow |> Workflow.log() |> Enum.map(&serialize_event/1)
    rescue
      _ -> []
    end
  end

  defp serialize_event(event) do
    event
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(value) when is_atom(value), do: to_string(value)

  defp serialize_value(value) when is_struct(value),
    do: value |> Map.from_struct() |> serialize_value()

  defp serialize_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> serialize_value()

  defp serialize_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {serialize_key(k), serialize_value(v)} end)

  defp serialize_value(value) when is_list(value), do: Enum.map(value, &serialize_value/1)

  defp serialize_value(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: inspect(value)

  defp serialize_value(value) when is_function(value), do: inspect(value)
  defp serialize_value(value), do: value

  defp serialize_key(key) when is_atom(key), do: to_string(key)
  defp serialize_key(key) when is_binary(key), do: key
  defp serialize_key(key), do: inspect(key)

  defp sanitize_for_json(value), do: serialize_value(value)

  defp determine_output(productions) when is_list(productions) do
    case productions do
      [] -> %{}
      [single] -> %{"result" => single}
      multiple -> %{"results" => multiple}
    end
  end

  defp store_runic_logs(execution, build_log, reaction_log) do
    Repo.update(
      Execution.changeset(execution, %{
        runic_build_log: build_log,
        runic_reaction_log: reaction_log
      })
    )
  end

  defp handle_result(execution, {:ok, {output, context}}),
    do: mark_completed(execution, output, context)

  defp handle_result(execution, {:timeout, _context}), do: mark_timeout(execution)

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

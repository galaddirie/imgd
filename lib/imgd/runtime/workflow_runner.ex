defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution using Runic with real-time event broadcasting.
  """

  require Logger
  alias Runic.Workflow
  alias Imgd.Repo
  alias Imgd.Executions.{Execution, NodeExecution, Context}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{WorkflowBuilder, NodeExecutionError}
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
    case WorkflowBuilder.build(execution.workflow_version, context) do
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

    task =
      Task.async(fn ->
        execute_workflow_with_events(execution, runic_workflow, initial_input, context)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning("Workflow execution timed out",
          execution_id: execution.id,
          timeout_ms: timeout_ms
        )

        {:timeout, context}
    end
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
  # Workflow Execution with Per-Node Events
  # ============================================================================

  defp execute_workflow_with_events(execution, runic_workflow, initial_input, context) do
    try do
      nodes = execution.workflow_version.nodes || []
      node_map = Map.new(nodes, &{&1.id, &1})

      Logger.debug("Starting workflow execution",
        execution_id: execution.id,
        node_count: map_size(node_map),
        trigger_input: inspect(initial_input)
      )

      {executed_workflow, final_context} =
        execute_with_node_tracking(execution, runic_workflow, initial_input, context, node_map)

      productions = Workflow.raw_productions(executed_workflow)
      build_log = extract_build_log(executed_workflow)
      reaction_log = extract_reaction_log(executed_workflow)
      output = determine_output(productions)

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

        handle_node_failure(execution, e, context)
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

  # Execute workflow with proper node tracking and PubSub broadcasting
  defp execute_with_node_tracking(execution, runic_workflow, initial_input, context, node_map) do
    max_iterations = map_size(node_map) * 2 + 10

    # Track which nodes we've started/completed
    node_tracker = %{started: MapSet.new(), completed: MapSet.new()}

    # First, react to the input
    workflow = Workflow.react(runic_workflow, initial_input)

    # Execute with tracking
    {final_workflow, final_context, _tracker} =
      do_tracked_execution(
        workflow,
        execution,
        context,
        node_map,
        node_tracker,
        max_iterations,
        0
      )

    {final_workflow, final_context}
  end

  defp do_tracked_execution(workflow, _execution, context, _node_map, tracker, max_iters, current)
       when current >= max_iters do
    Logger.warning("Workflow execution reached maximum iterations", max_iterations: max_iters)
    {workflow, context, tracker}
  end

  defp do_tracked_execution(workflow, execution, context, node_map, tracker, max_iters, current) do
    if Workflow.is_runnable?(workflow) do
      runnables = Workflow.next_runnables(workflow)

      if Enum.empty?(runnables) do
        {workflow, context, tracker}
      else
        # Process each runnable with tracking
        {new_workflow, new_context, new_tracker} =
          Enum.reduce(runnables, {workflow, context, tracker}, fn {step, fact}, {wf, ctx, trk} ->
            # Extract node_id from step name
            node_id = Atom.to_string(step.name)
            node = Map.get(node_map, node_id)

            # Broadcast node started (if not already started)
            trk =
              if node && not MapSet.member?(trk.started, node_id) do
                broadcast_node_started(execution, node, fact.value)
                %{trk | started: MapSet.put(trk.started, node_id)}
              else
                trk
              end

            # Invoke the step
            start_time = System.monotonic_time(:millisecond)
            new_wf = Workflow.invoke(wf, step, fact)
            duration_ms = System.monotonic_time(:millisecond) - start_time

            # Get the result from the workflow's facts
            result = get_step_result(new_wf, step)

            # Update context and broadcast completion
            {new_ctx, new_trk} =
              if node && not MapSet.member?(trk.completed, node_id) do
                case result do
                  {:ok, output} ->
                    updated_ctx = Context.put_output(ctx, node_id, output)
                    broadcast_node_completed(execution, node, fact.value, output, duration_ms)
                    {updated_ctx, %{trk | completed: MapSet.put(trk.completed, node_id)}}

                  {:error, error} ->
                    broadcast_node_failed_event(execution, node, fact.value, error, duration_ms)
                    {ctx, %{trk | completed: MapSet.put(trk.completed, node_id)}}

                  _ ->
                    # Node might have produced output directly
                    updated_ctx = Context.put_output(ctx, node_id, result)
                    broadcast_node_completed(execution, node, fact.value, result, duration_ms)
                    {updated_ctx, %{trk | completed: MapSet.put(trk.completed, node_id)}}
                end
              else
                {ctx, trk}
              end

            {new_wf, new_ctx, new_trk}
          end)

        do_tracked_execution(
          new_workflow,
          execution,
          new_context,
          node_map,
          new_tracker,
          max_iters,
          current + 1
        )
      end
    else
      {workflow, context, tracker}
    end
  end

  # Get the result produced by a step
  defp get_step_result(workflow, step) do
    facts = Workflow.facts(workflow)

    # Find the most recent fact produced by this step
    step_hash = :erlang.phash2(step)

    facts
    |> Enum.filter(fn fact ->
      case fact.ancestry do
        {hash, _} -> hash == step_hash
        _ -> false
      end
    end)
    |> Enum.sort_by(& &1, :desc)
    |> List.first()
    |> case do
      nil -> nil
      fact -> fact.value
    end
  end

  # ============================================================================
  # Node Event Broadcasting
  # ============================================================================

  defp broadcast_node_started(execution, node, input_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Create NodeExecution record
    attrs = %{
      execution_id: execution.id,
      node_id: node.id,
      node_type_id: node.type_id,
      status: :running,
      input_data: normalize_node_data(input_data),
      started_at: now,
      queued_at: now,
      attempt: 1
    }

    case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
      {:ok, node_exec} ->
        ExecutionPubSub.broadcast_node_started(execution, node_exec)

      {:error, changeset} ->
        Logger.warning("Failed to persist node execution start",
          execution_id: execution.id,
          node_id: node.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp broadcast_node_completed(execution, node, input_data, output_data, duration_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started_at = DateTime.add(now, -duration_ms, :millisecond)

    # Try to find existing NodeExecution or create new one
    case find_running_node_execution(execution.id, node.id) do
      %NodeExecution{} = node_exec ->
        # Update existing record
        case Repo.update(
               NodeExecution.changeset(node_exec, %{
                 status: :completed,
                 output_data: normalize_node_data(output_data),
                 completed_at: now
               })
             ) do
          {:ok, updated} -> ExecutionPubSub.broadcast_node_completed(execution, updated)
          {:error, _} -> :ok
        end

      nil ->
        # Create completed record
        attrs = %{
          execution_id: execution.id,
          node_id: node.id,
          node_type_id: node.type_id,
          status: :completed,
          input_data: normalize_node_data(input_data),
          output_data: normalize_node_data(output_data),
          started_at: started_at,
          completed_at: now,
          queued_at: started_at,
          attempt: 1
        }

        case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
          {:ok, node_exec} -> ExecutionPubSub.broadcast_node_completed(execution, node_exec)
          {:error, _} -> :ok
        end
    end
  end

  defp broadcast_node_failed_event(execution, node, input_data, error, duration_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started_at = DateTime.add(now, -duration_ms, :millisecond)

    case find_running_node_execution(execution.id, node.id) do
      %NodeExecution{} = node_exec ->
        case Repo.update(
               NodeExecution.changeset(node_exec, %{
                 status: :failed,
                 error: %{"reason" => inspect(error)},
                 completed_at: now
               })
             ) do
          {:ok, updated} -> ExecutionPubSub.broadcast_node_failed(execution, updated, error)
          {:error, _} -> :ok
        end

      nil ->
        attrs = %{
          execution_id: execution.id,
          node_id: node.id,
          node_type_id: node.type_id,
          status: :failed,
          input_data: normalize_node_data(input_data),
          error: %{"reason" => inspect(error)},
          started_at: started_at,
          completed_at: now,
          queued_at: started_at,
          attempt: 1
        }

        case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
          {:ok, node_exec} -> ExecutionPubSub.broadcast_node_failed(execution, node_exec, error)
          {:error, _} -> :ok
        end
    end
  end

  defp find_running_node_execution(execution_id, node_id) do
    import Ecto.Query

    NodeExecution
    |> where(
      [n],
      n.execution_id == ^execution_id and n.node_id == ^node_id and n.status == :running
    )
    |> order_by([n], desc: n.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp handle_node_failure(execution, %NodeExecutionError{} = error, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      execution_id: execution.id,
      node_id: error.node_id,
      node_type_id: error.node_type_id,
      status: :failed,
      input_data: normalize_node_data(context.current_input),
      error: %{"reason" => inspect(error.reason)},
      started_at: now,
      completed_at: now,
      attempt: 1
    }

    case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
      {:ok, node_exec} ->
        ExecutionPubSub.broadcast_node_failed(execution, node_exec, error.reason)

      {:error, changeset} ->
        Logger.warning("Failed to persist failed node execution",
          execution_id: execution.id,
          node_id: error.node_id,
          errors: inspect(changeset.errors)
        )
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

  defp normalize_node_data(nil), do: nil
  defp normalize_node_data(%{} = map), do: sanitize_for_json(map)

  defp normalize_node_data(value) do
    value
    |> sanitize_for_json()
    |> case do
      %{} = map -> map
      other -> %{"value" => other}
    end
  end

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

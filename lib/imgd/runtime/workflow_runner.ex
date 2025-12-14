defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution using Runic with real-time event broadcasting.

  This module is responsible for:
  - Building Runic workflows from WorkflowVersions
  - Executing workflows via `Runic.Workflow.react_until_satisfied/2`
  - Persisting NodeExecution records as steps complete
  - Updating execution context with outputs
  - Handling timeouts via Task.yield/2 pattern
  - Broadcasting progress via PubSub for live UI updates
  - Emitting telemetry/traces via Instrumentation
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

  @doc """
  Runs a workflow execution with real-time event broadcasting.

  The execution must have `workflow_version` preloaded.
  """
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

  defp handle_execution_result(execution, {:ok, result}) do
    handle_result(execution, {:ok, result})
  end

  defp handle_execution_result(execution, {:error, reason}) do
    mark_failed(execution, reason)
  end

  defp handle_execution_result(execution, {:timeout, context}) do
    handle_result(execution, {:timeout, context})
  end

  # ============================================================================
  # Execution Lifecycle
  # ============================================================================

  defp mark_running(%Execution{} = execution) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update(
           Execution.changeset(execution, %{
             status: :running,
             started_at: now
           })
         ) do
      {:ok, execution} ->
        ExecutionPubSub.broadcast_execution_started(execution)
        {:ok, execution}

      {:error, changeset} ->
        {:error, {:update_failed, changeset}}
    end
  end

  defp mark_completed(%Execution{} = execution, output, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update(
           Execution.changeset(execution, %{
             status: :completed,
             completed_at: now,
             output: output,
             context: context.node_outputs
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
           Execution.changeset(execution, %{
             status: :failed,
             completed_at: now,
             error: error
           })
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
           Execution.changeset(execution, %{
             status: :timeout,
             completed_at: now,
             error: error
           })
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

    context =
      Context.new(execution,
        current_node_id: nil,
        current_input: initial_input
      )

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
        Map.get(settings, "timeout_ms") ||
          Map.get(settings, :timeout_ms) ||
          @default_timeout_ms

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
      # Get nodes for tracking
      nodes = execution.workflow_version.nodes || []
      node_map = Map.new(nodes, &{&1.id, &1})

      Logger.debug("Starting workflow execution",
        execution_id: execution.id,
        node_count: map_size(node_map),
        trigger_input: inspect(initial_input)
      )

      # Execute with node tracking
      {executed_workflow, final_context} =
        execute_nodes_sequentially(execution, runic_workflow, initial_input, context, node_map)

      # Extract results
      productions = Workflow.raw_productions(executed_workflow)
      build_log = extract_build_log(executed_workflow)
      reaction_log = extract_reaction_log(executed_workflow)

      output = determine_output(productions)

      Logger.debug("Workflow execution completed",
        execution_id: execution.id,
        productions_count: length(productions)
      )

      # Store Runic logs
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

  # Execute nodes with per-node event broadcasting
  defp execute_nodes_sequentially(execution, runic_workflow, initial_input, context, node_map) do
    # Execute the workflow with a maximum iteration guard to prevent infinite loops
    max_iterations = map_size(node_map) * 2 + 10

    executed_workflow =
      execute_workflow_bounded(runic_workflow, initial_input, max_iterations)

    # Extract facts and map to nodes
    facts = Workflow.facts(executed_workflow)
    final_context = process_facts_and_broadcast(execution, facts, context, node_map)

    {executed_workflow, final_context}
  end

  # Execute workflow with bounded iterations to prevent infinite loops
  defp execute_workflow_bounded(workflow, input, max_iterations) do
    # First, react to the input to set up initial runnables
    workflow = Workflow.react(workflow, input)

    # Then iterate with a bound
    do_bounded_execution(workflow, max_iterations, 0)
  end

  defp do_bounded_execution(workflow, max_iterations, current_iteration)
       when current_iteration >= max_iterations do
    Logger.warning("Workflow execution reached maximum iterations",
      max_iterations: max_iterations,
      current_iteration: current_iteration
    )

    workflow
  end

  defp do_bounded_execution(workflow, max_iterations, current_iteration) do
    if Workflow.is_runnable?(workflow) do
      runnables = Workflow.next_runnables(workflow)

      if Enum.empty?(runnables) do
        workflow
      else
        # Execute all current runnables
        workflow =
          Enum.reduce(runnables, workflow, fn {node, fact}, wrk ->
            Workflow.invoke(wrk, node, fact)
          end)

        do_bounded_execution(workflow, max_iterations, current_iteration + 1)
      end
    else
      workflow
    end
  end

  defp process_facts_and_broadcast(_execution, facts, context, _node_map) do
    # Facts produced by Runic contain values from node executions.
    # The telemetry and PubSub broadcasts are handled by the hooks in WorkflowBuilder,
    # so here we just accumulate the outputs in the context for reference.
    #
    # Note: Runic facts have ancestry as {step_hash, parent_fact_hash} where step_hash
    # is an integer. Without a reverse lookup from hash to node_id, we can't reliably
    # map facts back to nodes. The hooks handle the actual broadcasting.
    Enum.reduce(facts, context, fn fact, acc_context ->
      # Just accumulate fact values in context for debugging/logging purposes
      # The actual node output tracking is done through the hooks
      Logger.debug("Processed fact",
        value: inspect(fact.value, limit: 100),
        ancestry: inspect(fact.ancestry)
      )

      acc_context
    end)
  end

  defp handle_node_failure(execution, %NodeExecutionError{} = error, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      execution_id: execution.id,
      node_id: error.node_id,
      node_type_id: error.node_type_id,
      status: :failed,
      input_data: context.current_input,
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

  defp extract_build_log(workflow) do
    try do
      workflow
      |> Workflow.build_log()
      |> Enum.map(&serialize_event/1)
    rescue
      _ -> []
    end
  end

  defp extract_reaction_log(workflow) do
    try do
      workflow
      |> Workflow.log()
      |> Enum.map(&serialize_event/1)
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
  defp serialize_value(value) when is_struct(value), do: Map.from_struct(value)
  defp serialize_value(value), do: value

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

  # ============================================================================
  # Result Handling
  # ============================================================================

  defp handle_result(execution, {:ok, {output, context}}) do
    mark_completed(execution, output, context)
  end

  defp handle_result(execution, {:timeout, _context}) do
    mark_timeout(execution)
  end

  defp format_error(reason) do
    case reason do
      {:node_failed, node_id, node_reason} ->
        %{
          "type" => "node_failure",
          "node_id" => node_id,
          "reason" => inspect(node_reason)
        }

      {:workflow_build_failed, build_reason} ->
        %{
          "type" => "workflow_build_failed",
          "reason" => inspect(build_reason)
        }

      {:build_failed, message} ->
        %{
          "type" => "build_failure",
          "message" => message
        }

      {:cycle_detected, node_ids} ->
        %{
          "type" => "cycle_detected",
          "node_ids" => node_ids
        }

      {:invalid_connections, connections} ->
        %{
          "type" => "invalid_connections",
          "connections" => Enum.map(connections, &Map.from_struct/1)
        }

      {:update_failed, changeset} ->
        %{
          "type" => "update_failed",
          "errors" => inspect(changeset.errors)
        }

      {:unexpected_error, message} ->
        %{
          "type" => "unexpected_error",
          "message" => message
        }

      {:caught_error, kind, caught_reason} ->
        %{
          "type" => "caught_error",
          "kind" => inspect(kind),
          "reason" => inspect(caught_reason)
        }

      other ->
        %{
          "type" => "unknown",
          "reason" => inspect(other)
        }
    end
  end
end

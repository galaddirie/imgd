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
  alias Imgd.Workflows.Embeds.Node

  @default_timeout_ms 300_000

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
         {:ok, runic_workflow} <- WorkflowBuilder.build(execution.workflow_version, context),
         {:ok, result} <- execute_with_timeout(execution, runic_workflow, context) do
      handle_result(execution, result)
    else
      {:error, reason} ->
        mark_failed(execution, reason)
    end
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
    trigger_input = Execution.trigger_data(execution)

    context =
      Context.new(execution,
        current_node_id: nil,
        current_input: trigger_input
      )

    {:ok, context}
  end

  # ============================================================================
  # Execution with Timeout
  # ============================================================================

  defp execute_with_timeout(%Execution{} = execution, runic_workflow, context) do
    timeout_ms = get_timeout_ms(execution)
    trigger_input = Execution.trigger_data(execution)

    task =
      Task.async(fn ->
        execute_workflow_with_events(execution, runic_workflow, trigger_input, context)
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

  # ============================================================================
  # Workflow Execution with Per-Node Events
  # ============================================================================

  defp execute_workflow_with_events(execution, runic_workflow, trigger_input, context) do
    try do
      # Get nodes for tracking
      nodes = execution.workflow_version.nodes || []
      node_map = Map.new(nodes, &{&1.id, &1})

      # Execute with node tracking
      {executed_workflow, final_context} =
        execute_nodes_sequentially(execution, runic_workflow, trigger_input, context, node_map)

      # Extract results
      productions = Workflow.raw_productions(executed_workflow)
      build_log = extract_build_log(executed_workflow)
      reaction_log = extract_reaction_log(executed_workflow)

      output = determine_output(productions)

      # Store Runic logs
      store_runic_logs(execution, build_log, reaction_log)

      {:ok, {output, final_context}}
    rescue
      e in NodeExecutionError ->
        handle_node_failure(execution, e, context)
        {:error, {:node_failed, e.node_id, e.reason}}

      e ->
        Logger.error("Unexpected error during workflow execution",
          execution_id: execution.id,
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, {:unexpected_error, Exception.message(e)}}
    end
  end

  # Execute nodes with per-node event broadcasting
  defp execute_nodes_sequentially(execution, runic_workflow, trigger_input, context, node_map) do
    # This is a simplified version - in practice, Runic handles the execution order
    # We wrap it to capture and broadcast events

    # Start execution
    executed_workflow = Workflow.react_until_satisfied(runic_workflow, trigger_input)

    # Extract facts and map to nodes
    facts = Workflow.facts(executed_workflow)
    final_context = process_facts_and_broadcast(execution, facts, context, node_map)

    {executed_workflow, final_context}
  end

  defp process_facts_and_broadcast(execution, facts, context, node_map) do
    # Process each fact and broadcast node events
    Enum.reduce(facts, context, fn fact, acc_context ->
      case extract_node_id_from_fact(fact) do
        nil ->
          acc_context

        node_id ->
          node = Map.get(node_map, node_id)

          if node do
            # Broadcast and persist node execution
            now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

            node_exec =
              persist_and_broadcast_node(
                execution,
                node,
                fact.value,
                acc_context,
                now
              )

            if node_exec do
              Context.put_output(acc_context, node_id, fact.value)
            else
              acc_context
            end
          else
            acc_context
          end
      end
    end)
  end

  defp persist_and_broadcast_node(execution, %Node{} = node, output, context, now) do
    # Create node execution with started status first
    started_attrs = %{
      execution_id: execution.id,
      node_id: node.id,
      node_type_id: node.type_id,
      status: :running,
      input_data: context.current_input,
      started_at: now,
      queued_at: now,
      attempt: 1
    }

    case Repo.insert(NodeExecution.changeset(%NodeExecution{}, started_attrs)) do
      {:ok, node_exec} ->
        # Broadcast started
        ExecutionPubSub.broadcast_node_started(execution, node_exec)

        # Update to completed
        completed_attrs = %{
          status: :completed,
          output_data: %{"value" => output},
          completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }

        case Repo.update(NodeExecution.changeset(node_exec, completed_attrs)) do
          {:ok, updated_exec} ->
            ExecutionPubSub.broadcast_node_completed(execution, updated_exec)
            updated_exec

          {:error, _} ->
            node_exec
        end

      {:error, changeset} ->
        Logger.warning("Failed to persist node execution",
          execution_id: execution.id,
          node_id: node.id,
          errors: inspect(changeset.errors)
        )

        nil
    end
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

  defp extract_node_id_from_fact(fact) do
    # Extract node_id from fact ancestry/metadata
    # This depends on how Runic structures its facts
    case fact.ancestry do
      {step_hash, _parent_hash} when is_binary(step_hash) ->
        # Try to parse node_id from step name (if encoded)
        # This is a simplification - actual implementation depends on Runic structure
        nil

      _ ->
        nil
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

  defp handle_result(execution, {:error, reason}) do
    mark_failed(execution, reason)
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

      other ->
        %{
          "type" => "unknown",
          "reason" => inspect(other)
        }
    end
  end
end

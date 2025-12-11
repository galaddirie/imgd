defmodule Imgd.Runtime.WorkflowRunner do
  @moduledoc """
  Orchestrates workflow execution using Runic.

  This module is responsible for:
  - Building Runic workflows from WorkflowVersions
  - Executing workflows via `Runic.Workflow.react_until_satisfied/2`
  - Persisting NodeExecution records as steps complete
  - Updating execution context with outputs
  - Handling timeouts via Task.yield/2 pattern
  - Broadcasting progress via PubSub
  - Emitting telemetry/traces via Instrumentation

  ## Usage

      {:ok, execution} = WorkflowRunner.run(execution)

  The execution must have `workflow_version` preloaded.
  """

  require Logger
  alias Runic.Workflow
  alias Imgd.Repo
  alias Imgd.Executions.{Execution, NodeExecution, Context}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{WorkflowBuilder, NodeExecutionError}
  alias Imgd.Observability.Instrumentation

  @default_timeout_ms 300_000

  @type run_result :: {:ok, Execution.t()} | {:error, term()}

  @doc """
  Runs a workflow execution.

  The execution must have `workflow_version` preloaded. This function:

  1. Marks the execution as running
  2. Builds a Runic workflow from the version
  3. Executes the workflow with timeout protection
  4. Persists node execution records
  5. Updates the execution with results

  ## Returns

  - `{:ok, execution}` - Execution completed (check status for success/failure)
  - `{:error, reason}` - Failed to run execution
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
        # Still return original error
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

    # Run in a Task for timeout control
    task =
      Task.async(fn ->
        execute_runic_workflow(execution, runic_workflow, trigger_input, context)
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
  # Runic Workflow Execution
  # ============================================================================

  defp execute_runic_workflow(execution, runic_workflow, trigger_input, context) do
    try do
      # Execute the Runic workflow
      executed_workflow = Workflow.react_until_satisfied(runic_workflow, trigger_input)

      # Extract results and update context
      productions = Workflow.raw_productions(executed_workflow)
      build_log = extract_build_log(executed_workflow)
      reaction_log = extract_reaction_log(executed_workflow)

      # Get the final output (last production or all productions)
      output = determine_output(productions)

      # Update context with all node outputs
      updated_context = update_context_from_workflow(context, executed_workflow)

      # Persist node execution records
      persist_node_executions(execution, executed_workflow, updated_context)

      # Store Runic logs on execution
      store_runic_logs(execution, build_log, reaction_log)

      {:ok, {output, updated_context}}
    rescue
      e in NodeExecutionError ->
        # Handle node-specific failures
        persist_failed_node_execution(execution, e, context)
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

  defp update_context_from_workflow(context, workflow) do
    # Extract facts from the workflow and map them to node outputs
    facts = Workflow.facts(workflow)

    Enum.reduce(facts, context, fn fact, ctx ->
      case fact.ancestry do
        {step_hash, _parent_hash} ->
          # Try to find the step name from the hash
          node_id = find_node_id_from_hash(workflow, step_hash)

          if node_id do
            Context.put_output(ctx, node_id, fact.value)
          else
            ctx
          end

        nil ->
          # Input fact, skip
          ctx
      end
    end)
  end

  defp find_node_id_from_hash(_workflow, _step_hash) do
    # This is a simplification - in practice we'd need to track this mapping
    # during workflow building
    nil
  end

  # ============================================================================
  # Node Execution Persistence
  # ============================================================================

  defp persist_node_executions(execution, _workflow, context) do
    # Get all completed nodes from context
    completed_nodes = Context.completed_nodes(context)

    Enum.each(completed_nodes, fn node_id ->
      output = Context.get_output(context, node_id)

      attrs = %{
        execution_id: execution.id,
        node_id: node_id,
        node_type_id: "unknown",
        status: :completed,
        output_data: %{"value" => output},
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        attempt: 1
      }

      case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
        {:ok, node_exec} ->
          ExecutionPubSub.broadcast_node_completed(execution, node_exec)

        {:error, changeset} ->
          Logger.warning("Failed to persist node execution",
            execution_id: execution.id,
            node_id: node_id,
            errors: inspect(changeset.errors)
          )
      end
    end)
  end

  defp persist_failed_node_execution(execution, %NodeExecutionError{} = error, _context) do
    attrs = %{
      execution_id: execution.id,
      node_id: error.node_id,
      node_type_id: error.node_type_id,
      status: :failed,
      error: %{"reason" => inspect(error.reason)},
      started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      attempt: 1
    }

    case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
      {:ok, node_exec} ->
        ExecutionPubSub.broadcast_node_failed(execution, node_exec)

      {:error, changeset} ->
        Logger.warning("Failed to persist failed node execution",
          execution_id: execution.id,
          node_id: error.node_id,
          errors: inspect(changeset.errors)
        )
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

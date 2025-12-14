defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Converts a WorkflowVersion into a Runic.Workflow.

  This module handles:
  - Parsing nodes and connections into a DAG structure
  - Topologically sorting nodes to determine execution order
  - Creating Runic steps that wrap NodeExecutor.execute/3 calls
  - Wiring up data flow via Runic's parent/child dependencies
  - Handling fan-out/fan-in for parallel branches
  - Installing observability hooks for real-time node tracking

  ## Hooks and Real-Time Events

  Following the Runic hook pattern, we install before/after hooks on each step
  to track node execution lifecycle. These hooks:

  1. Create/update NodeExecution records in the database
  2. Broadcast PubSub events for real-time UI updates
  3. Emit telemetry events for metrics/monitoring
  4. Store timing information for duration calculations

  The execution context is captured in a closure at build time so hooks
  have access to the execution record for database/PubSub operations.
  """

  require Runic
  require Logger

  alias Runic.Workflow
  alias Runic.Workflow.{Components, Step}
  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Executions.{Context, Execution, NodeExecution}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{ExecutionState, NodeExecutor}
  alias Imgd.Runtime.Expression.Evaluator
  alias Imgd.Repo

  @type build_result :: {:ok, Workflow.t()} | {:error, term()}

  @doc """
  Builds a Runic workflow from a WorkflowVersion.

  ## Parameters

  - `version` - The WorkflowVersion containing nodes and connections
  - `context` - The execution context for resolving expressions and variables
  - `execution` - The Execution record (for hooks to broadcast events)

  ## Returns

  - `{:ok, workflow}` - Successfully built Runic workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(WorkflowVersion.t(), Context.t(), Execution.t()) :: build_result()
  def build(%WorkflowVersion{} = version, %Context{} = context, %Execution{} = execution) do
    with {:ok, graph} <- build_dag(version.nodes, version.connections),
         {:ok, sorted_nodes} <- topological_sort(graph, version.nodes),
         {:ok, workflow} <- build_runic_workflow(sorted_nodes, graph, context, version, execution) do
      {:ok, workflow}
    end
  end

  # Legacy 2-arity version for backwards compatibility (no hooks)
  @spec build(WorkflowVersion.t(), Context.t()) :: build_result()
  def build(%WorkflowVersion{} = version, %Context{} = context) do
    with {:ok, graph} <- build_dag(version.nodes, version.connections),
         {:ok, sorted_nodes} <- topological_sort(graph, version.nodes),
         {:ok, workflow} <- build_runic_workflow_simple(sorted_nodes, graph, context, version) do
      {:ok, workflow}
    end
  end

  @doc """
  Builds a Runic workflow or raises on error.
  """
  @spec build!(WorkflowVersion.t(), Context.t()) :: Workflow.t()
  def build!(%WorkflowVersion{} = version, %Context{} = context) do
    case build(version, context) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise "Failed to build workflow: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # DAG Construction
  # ============================================================================

  @doc false
  def build_dag(nodes, connections) do
    node_ids = MapSet.new(nodes, & &1.id)

    invalid_connections =
      Enum.filter(connections, fn conn ->
        not MapSet.member?(node_ids, conn.source_node_id) or
          not MapSet.member?(node_ids, conn.target_node_id)
      end)

    if invalid_connections != [] do
      {:error, {:invalid_connections, invalid_connections}}
    else
      adjacency =
        Enum.reduce(connections, %{}, fn conn, acc ->
          Map.update(acc, conn.source_node_id, [conn.target_node_id], &[conn.target_node_id | &1])
        end)

      reverse_adjacency =
        Enum.reduce(connections, %{}, fn conn, acc ->
          Map.update(acc, conn.target_node_id, [conn.source_node_id], &[conn.source_node_id | &1])
        end)

      connections_by_source = Enum.group_by(connections, & &1.source_node_id)

      {:ok,
       %{
         adjacency: adjacency,
         reverse_adjacency: reverse_adjacency,
         connections: connections,
         connections_by_source: connections_by_source,
         node_ids: node_ids
       }}
    end
  end

  @doc false
  def topological_sort(graph, nodes) do
    node_map = Map.new(nodes, &{&1.id, &1})

    in_degrees =
      Enum.reduce(nodes, %{}, fn node, acc ->
        parents = Map.get(graph.reverse_adjacency, node.id, [])
        Map.put(acc, node.id, length(parents))
      end)

    queue =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    do_topological_sort(queue, in_degrees, graph.adjacency, node_map, [])
  end

  defp do_topological_sort([], in_degrees, _adjacency, _node_map, sorted) do
    remaining = Enum.filter(in_degrees, fn {_id, degree} -> degree > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, {:cycle_detected, Enum.map(remaining, fn {id, _} -> id end)}}
    end
  end

  defp do_topological_sort([node_id | rest], in_degrees, adjacency, node_map, sorted) do
    node = Map.fetch!(node_map, node_id)
    children = Map.get(adjacency, node_id, [])

    {new_in_degrees, new_queue_additions} =
      Enum.reduce(children, {in_degrees, []}, fn child_id, {degrees, additions} ->
        new_degree = Map.get(degrees, child_id, 0) - 1
        new_degrees = Map.put(degrees, child_id, new_degree)

        if new_degree == 0 do
          {new_degrees, [child_id | additions]}
        else
          {new_degrees, additions}
        end
      end)

    new_in_degrees = Map.delete(new_in_degrees, node_id)

    do_topological_sort(
      rest ++ new_queue_additions,
      new_in_degrees,
      adjacency,
      node_map,
      [node | sorted]
    )
  end

  # ============================================================================
  # Runic Workflow Construction (with hooks)
  # ============================================================================

  defp build_runic_workflow(sorted_nodes, graph, context, version, execution) do
    base_workflow =
      Runic.workflow(name: "workflow_#{version.workflow_id}_v#{version.version_tag}")

    node_info_map = Map.new(sorted_nodes, &{&1.id, %{type_id: &1.type_id, name: &1.name}})

    {workflow, step_map} =
      Enum.reduce(sorted_nodes, {base_workflow, %{}}, fn node, {wf, steps} ->
        step = create_runic_step(node, context)
        parents = Map.get(graph.reverse_adjacency, node.id, [])

        wf =
          case parents do
            [] ->
              Workflow.add_step(wf, step)

            [single_parent] ->
              parent_step = Map.fetch!(steps, single_parent)
              Workflow.add_step(wf, parent_step, step)

            multiple_parents ->
              parent_steps = Enum.map(multiple_parents, &Map.fetch!(steps, &1))
              add_with_join(wf, parent_steps, step)
          end

        {wf, Map.put(steps, node.id, step)}
      end)

    # Install hooks that handle all node-level observability
    workflow = install_tracking_hooks(workflow, step_map, node_info_map, execution)

    {:ok, workflow}
  rescue
    e ->
      {:error, {:build_failed, Exception.message(e)}}
  end

  # Simple version without hooks (for testing/preview)
  defp build_runic_workflow_simple(sorted_nodes, graph, context, version) do
    base_workflow =
      Runic.workflow(name: "workflow_#{version.workflow_id}_v#{version.version_tag}")

    {workflow, _step_map} =
      Enum.reduce(sorted_nodes, {base_workflow, %{}}, fn node, {wf, steps} ->
        step = create_runic_step(node, context)
        parents = Map.get(graph.reverse_adjacency, node.id, [])

        wf =
          case parents do
            [] ->
              Workflow.add_step(wf, step)

            [single_parent] ->
              parent_step = Map.fetch!(steps, single_parent)
              Workflow.add_step(wf, parent_step, step)

            multiple_parents ->
              parent_steps = Enum.map(multiple_parents, &Map.fetch!(steps, &1))
              add_with_join(wf, parent_steps, step)
          end

        {wf, Map.put(steps, node.id, step)}
      end)

    {:ok, workflow}
  rescue
    e ->
      {:error, {:build_failed, Exception.message(e)}}
  end

  defp create_runic_step(%Node{} = node, %Context{} = context) do
    work = fn input -> execute_node(node, input, context) end

    Step.new(
      name: String.to_atom(node.id),
      work: work,
      hash: Components.fact_hash({node.id, node.type_id})
    )
  end

  defp execute_node(%Node{} = node, input, %Context{} = context) do
    ctx =
      context
      |> merge_runtime_outputs()
      |> Context.set_current_node(node.id, input)

    case Evaluator.resolve_config(node.config, ctx) do
      {:ok, resolved_config} ->
        execute_with_config(node, resolved_config, input, ctx)

      {:error, reason} ->
        raise Imgd.Runtime.NodeExecutionError,
          node_id: node.id,
          node_type_id: node.type_id,
          reason: {:expression_error, reason}
    end
  end

  defp execute_with_config(%Node{} = node, config, input, ctx) do
    try do
      case NodeExecutor.execute(node.type_id, config, input, ctx) do
        {:ok, output} ->
          ExecutionState.record_output(ctx.execution_id, node.id, output)
          output

        {:error, reason} ->
          raise Imgd.Runtime.NodeExecutionError,
            node_id: node.id,
            node_type_id: node.type_id,
            reason: reason

        {:skip, reason} ->
          {:__skipped__, node.id, reason}
      end
    rescue
      e in Imgd.Runtime.NodeExecutionError ->
        reraise e, __STACKTRACE__

      e ->
        raise Imgd.Runtime.NodeExecutionError,
          node_id: node.id,
          node_type_id: node.type_id,
          reason: {:execution_exception, Exception.message(e)}
    end
  end

  defp merge_runtime_outputs(%Context{} = context) do
    outputs = ExecutionState.outputs(context.execution_id)
    %{context | node_outputs: Map.merge(context.node_outputs, outputs)}
  end

  defp add_with_join(workflow, parent_steps, child_step) do
    Enum.reduce(parent_steps, workflow, fn parent, wf ->
      Workflow.add_step(wf, parent, child_step)
    end)
  end

  # ============================================================================
  # Real-Time Tracking Hooks
  #
  # Following the Runic guide, we install before/after hooks for each step.
  # The execution is captured in the closure so hooks can access it.
  # ============================================================================

  defp install_tracking_hooks(workflow, step_map, node_info_map, execution) do
    Enum.reduce(step_map, workflow, fn {node_id, _step}, wf ->
      step_name = String.to_atom(node_id)
      node_info = Map.get(node_info_map, node_id, %{type_id: "unknown", name: node_id})

      wf
      |> Workflow.attach_before_hook(step_name, create_before_hook(execution, node_id, node_info))
      |> Workflow.attach_after_hook(step_name, create_after_hook(execution, node_id, node_info))
    end)
  end

  # Create a before hook closure that captures the execution
  defp create_before_hook(execution, node_id, node_info) do
    fn _step, workflow, fact ->
      handle_node_started(execution, node_id, node_info, fact)
      workflow
    end
  end

  # Create an after hook closure that captures the execution
  defp create_after_hook(execution, node_id, node_info) do
    fn _step, workflow, fact ->
      handle_node_completed(execution, node_id, node_info, fact)
      workflow
    end
  end

  defp handle_node_started(execution, node_id, node_info, fact) do
    node_type_id = node_info.type_id
    node_name = node_info.name

    ExecutionState.record_start_time(execution.id, node_id, System.monotonic_time(:millisecond))

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    input_data = wrap_for_db(fact.value)

    # Create NodeExecution record in database
    attrs = %{
      execution_id: execution.id,
      node_id: node_id,
      node_type_id: node_type_id,
      status: :running,
      input_data: input_data,
      started_at: now,
      queued_at: now,
      attempt: 1
    }

    case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
      {:ok, node_exec} ->
        ExecutionState.put_node_execution(execution.id, node_id, node_exec)

        # Broadcast PubSub event for real-time UI updates
        ExecutionPubSub.broadcast_node_started(execution, node_exec)

        Logger.info("Node started: #{node_name}",
          node_type: node_type_id,
          node_id: node_id
        )

      {:error, changeset} ->
        Logger.warning("Failed to persist node execution start",
          execution_id: execution.id,
          node_id: node_id,
          errors: inspect(changeset.errors)
        )
    end

    # Emit telemetry for metrics
    :telemetry.execute(
      [:imgd, :engine, :node, :start],
      %{system_time: System.system_time(), queue_time_ms: nil},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        node_id: node_id,
        node_type_id: node_type_id,
        attempt: 1
      }
    )
  end

  defp handle_node_completed(execution, node_id, node_info, fact) do
    node_type_id = node_info.type_id
    node_name = node_info.name

    duration_ms =
      case ExecutionState.fetch_start_time(execution.id, node_id) do
        {:ok, start_time} -> System.monotonic_time(:millisecond) - start_time
        :error -> 0
      end

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    output_data = wrap_for_db(fact.value)

    node_exec =
      case ExecutionState.fetch_node_execution(execution.id, node_id) do
        {:ok, node_exec} -> node_exec
        :error -> find_running_node_execution(execution.id, node_id)
      end

    case node_exec do
      %NodeExecution{} = node_exec ->
        node_exec
        |> NodeExecution.changeset(%{
          status: :completed,
          output_data: output_data,
          completed_at: now
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            ExecutionState.put_node_execution(execution.id, node_id, updated)
            ExecutionPubSub.broadcast_node_completed(execution, updated)

            Logger.info("Node completed: #{node_name}",
              duration_ms: duration_ms,
              node_id: node_id
            )

          {:error, changeset} ->
            Logger.warning("Failed to update node execution",
              execution_id: execution.id,
              node_id: node_id,
              errors: inspect(changeset.errors)
            )
        end

      nil ->
        # Node execution wasn't created in before hook (shouldn't happen, but handle gracefully)
        started_at = DateTime.add(now, -duration_ms, :millisecond)

        attrs = %{
          execution_id: execution.id,
          node_id: node_id,
          node_type_id: node_type_id,
          status: :completed,
          output_data: output_data,
          started_at: started_at,
          completed_at: now,
          queued_at: started_at,
          attempt: 1
        }

        case Repo.insert(NodeExecution.changeset(%NodeExecution{}, attrs)) do
          {:ok, node_exec} ->
            ExecutionState.put_node_execution(execution.id, node_id, node_exec)
            ExecutionPubSub.broadcast_node_completed(execution, node_exec)

            Logger.info("Node completed: #{node_name}",
              duration_ms: duration_ms,
              node_id: node_id
            )

          {:error, _} ->
            :ok
        end
    end

    # Emit telemetry for metrics
    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: duration_ms},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        node_id: node_id,
        node_type_id: node_type_id,
        attempt: 1,
        status: :completed
      }
    )
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

  # ============================================================================
  # Data Serialization Helpers
  # ============================================================================

  # Wraps node data in a map structure for database storage.
  # NodeExecution schema requires input_data and output_data to be maps.
  # If the value is already a map, use it directly; otherwise wrap in %{"value" => ...}
  defp wrap_for_db(value) when is_map(value) and not is_struct(value) do
    sanitize_map_for_json(value)
  end

  defp wrap_for_db(value) when is_struct(value) do
    value |> Map.from_struct() |> wrap_for_db()
  end

  defp wrap_for_db(nil), do: nil

  defp wrap_for_db(value) do
    %{"value" => sanitize_value_for_json(value)}
  end

  # Recursively sanitize a map for JSON storage
  defp sanitize_map_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_value_for_json(v)} end)
  end

  # Sanitize a value for JSON storage (handles nested structures)
  defp sanitize_value_for_json(value) when is_struct(value),
    do: value |> Map.from_struct() |> sanitize_map_for_json()

  defp sanitize_value_for_json(value) when is_map(value),
    do: sanitize_map_for_json(value)

  defp sanitize_value_for_json(value) when is_list(value),
    do: Enum.map(value, &sanitize_value_for_json/1)

  defp sanitize_value_for_json(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_value_for_json()

  defp sanitize_value_for_json(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: inspect(value)

  defp sanitize_value_for_json(value) when is_function(value), do: inspect(value)

  defp sanitize_value_for_json(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: to_string(value)

  defp sanitize_value_for_json(value), do: value

  defp sanitize_key(key) when is_atom(key), do: to_string(key)
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)
end

defmodule Imgd.Runtime.NodeExecutionError do
  @moduledoc """
  Exception raised when a node execution fails.
  """
  defexception [:node_id, :node_type_id, :reason]

  @impl true
  def message(%{node_id: node_id, node_type_id: type_id, reason: reason}) do
    "Node #{node_id} (#{type_id}) failed: #{inspect(reason)}"
  end
end

defmodule Imgd.Runtime.Engines.Runic do
  @moduledoc """
  Runic-based workflow execution engine.

  This module implements the `ExecutionEngine` behavior using the Runic library
  for DAG-based workflow execution.

  ## Architecture

  The engine converts a WorkflowVersion into a Runic.Workflow:
  1. Parse nodes and connections into a DAG structure
  2. Topologically sort nodes to determine execution order
  3. Create Runic steps that wrap NodeExecutor.execute/3 calls
  4. Wire up data flow via Runic's parent/child dependencies
  5. Install observability hooks for real-time node tracking

  ## Hooks and Real-Time Events

  When an Execution record is provided to `build/3`, the engine installs
  before/after hooks on each step to:
  - Create/update NodeExecution records via the buffer
  - Broadcast PubSub events for real-time UI updates
  - Emit telemetry events for metrics/monitoring
  - Store timing information for duration calculations
  """

  @behaviour Imgd.Runtime.ExecutionEngine

  require Runic
  require Logger

  alias Runic.Workflow
  alias Runic.Workflow.{Components, Step}
  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Workflows.DagUtils
  alias Ecto.Changeset
  alias Imgd.Executions.{Context, Execution, NodeExecution, NodeExecutionBuffer}
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.{ExecutionState, NodeExecutor}
  alias Imgd.Runtime.Expression.Evaluator

  # ===========================================================================
  # ExecutionEngine Callbacks
  # ===========================================================================

  @impl true
  def build(%WorkflowVersion{} = version, %Context{} = context, execution) do
    with {:ok, graph} <- build_dag(version.nodes, version.connections),
         {:ok, sorted_nodes} <- topological_sort(graph, version.nodes) do
      if execution do
        build_with_hooks(sorted_nodes, graph, context, version, execution)
      else
        build_simple(sorted_nodes, graph, context, version)
      end
    end
  end

  @impl true
  def execute(workflow, input, %Context{} = context) do
    try do
      executed = Workflow.react_until_satisfied(workflow, input)

      productions = Workflow.raw_productions(executed)
      build_log = extract_build_log(executed)
      execution_log = extract_execution_log(executed)
      output = determine_output(productions)

      node_outputs = ExecutionState.outputs(context.execution_id)
      merged_outputs = Map.merge(context.node_outputs, node_outputs)

      {:ok,
       %{
         output: output,
         node_outputs: merged_outputs,
         engine_logs: %{
           build_log: build_log,
           execution_log: execution_log
         }
       }}
    rescue
      e in Imgd.Runtime.NodeExecutionError ->
        {:error, {:node_failed, e.node_id, e.reason}}

      e ->
        {:error, {:unexpected_error, Exception.message(e)}}
    catch
      kind, reason ->
        {:error, {:caught_error, kind, reason}}
    end
  end

  @impl true
  def build_partial(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts
      ) do
    target_node_ids = Keyword.get(opts, :target_nodes, [])
    pinned_outputs = Keyword.get(opts, :pinned_outputs, %{})
    include_targets = Keyword.get(opts, :include_targets, true)

    pinned_ids = Map.keys(pinned_outputs)

    nodes_to_run =
      DagUtils.compute_execution_set(
        target_node_ids,
        version.nodes,
        version.connections,
        pinned_ids
      )

    nodes_to_run =
      if include_targets do
        Enum.uniq(nodes_to_run ++ target_node_ids) -- pinned_ids
      else
        nodes_to_run -- target_node_ids
      end

    if nodes_to_run == [] do
      {:ok, build_empty_workflow(version)}
    else
      filtered_nodes = Enum.filter(version.nodes, &(&1.id in nodes_to_run))

      filtered_connections =
        Enum.filter(version.connections, fn c ->
          source_in_set = c.source_node_id in nodes_to_run
          target_in_set = c.target_node_id in nodes_to_run
          source_is_pinned = c.source_node_id in pinned_ids

          (source_in_set or source_is_pinned) and target_in_set
        end)

      partial_version = %{version | nodes: filtered_nodes, connections: filtered_connections}

      context_with_pins = %{
        context
        | node_outputs: Map.merge(context.node_outputs, pinned_outputs)
      }

      for {node_id, output} <- pinned_outputs do
        ExecutionState.record_output(context.execution_id, node_id, output)
      end

      build(partial_version, context_with_pins, execution)
    end
  end

  @impl true
  def build_downstream(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        opts
      ) do
    from_node_id = Keyword.fetch!(opts, :from_node)
    pinned_outputs = Keyword.get(opts, :pinned_outputs, %{})

    downstream_ids =
      DagUtils.downstream_closure(from_node_id, version.nodes, version.connections)

    build_partial(version, context, execution,
      target_nodes: downstream_ids,
      pinned_outputs: pinned_outputs,
      include_targets: true
    )
  end

  @impl true
  def build_single_node(
        %WorkflowVersion{} = version,
        %Context{} = context,
        %Execution{} = execution,
        node_id,
        input_data
      ) do
    case Enum.find(version.nodes, &(&1.id == node_id)) do
      nil ->
        {:error, {:node_not_found, node_id}}

      node ->
        single_node_version = %{version | nodes: [node], connections: []}

        context_with_input = %{
          context
          | node_outputs: Map.put(context.node_outputs, "__trigger__", input_data)
        }

        build(single_node_version, context_with_input, execution)
    end
  end

  # ===========================================================================
  # DAG Construction
  # ===========================================================================

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

  # ===========================================================================
  # Workflow Building
  # ===========================================================================

  defp build_with_hooks(sorted_nodes, graph, context, version, execution) do
    base_workflow =
      Runic.workflow(name: "workflow_#{version.workflow_id}_v#{version.version_tag}")

    node_info_map = Map.new(sorted_nodes, &{&1.id, %{type_id: &1.type_id, name: &1.name}})

    {workflow, step_map} =
      Enum.reduce(sorted_nodes, {base_workflow, %{}}, fn node, {wf, steps} ->
        step = create_step(node, context)
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

    workflow = install_tracking_hooks(workflow, step_map, node_info_map, execution)

    {:ok, workflow}
  rescue
    e ->
      {:error, {:build_failed, Exception.message(e)}}
  end

  defp build_simple(sorted_nodes, graph, context, version) do
    base_workflow =
      Runic.workflow(name: "workflow_#{version.workflow_id}_v#{version.version_tag}")

    {workflow, _step_map} =
      Enum.reduce(sorted_nodes, {base_workflow, %{}}, fn node, {wf, steps} ->
        step = create_step(node, context)
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

  defp build_empty_workflow(version) do
    Runic.workflow(name: "empty_partial_#{version.workflow_id}")
  end

  defp create_step(%Node{} = node, %Context{} = context) do
    work = fn input -> execute_node(node, input, context) end

    Step.new(
      name: String.to_atom(node.id),
      work: work,
      hash: Components.fact_hash({node.id, node.type_id})
    )
  end

  defp add_with_join(workflow, parent_steps, child_step) do
    Enum.reduce(parent_steps, workflow, fn parent, wf ->
      Workflow.add_step(wf, parent, child_step)
    end)
  end

  # ===========================================================================
  # Node Execution
  # ===========================================================================

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

  # ===========================================================================
  # Tracking Hooks
  # ===========================================================================

  defp install_tracking_hooks(workflow, step_map, node_info_map, execution) do
    Enum.reduce(step_map, workflow, fn {node_id, _step}, wf ->
      step_name = String.to_atom(node_id)
      node_info = Map.get(node_info_map, node_id, %{type_id: "unknown", name: node_id})

      wf
      |> Workflow.attach_before_hook(step_name, create_before_hook(execution, node_id, node_info))
      |> Workflow.attach_after_hook(step_name, create_after_hook(execution, node_id, node_info))
    end)
  end

  defp create_before_hook(execution, node_id, node_info) do
    fn _step, workflow, fact ->
      handle_node_started(execution, node_id, node_info, fact)
      workflow
    end
  end

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

    attrs = Map.put_new(attrs, :id, Ecto.UUID.generate())

    case Changeset.apply_action(NodeExecution.changeset(%NodeExecution{}, attrs), :insert) do
      {:ok, node_exec} ->
        ExecutionState.put_node_execution(execution.id, node_id, node_exec)
        NodeExecutionBuffer.record(node_exec)
        ExecutionPubSub.broadcast_node_started(execution, node_exec)

        Logger.info("Node started: #{node_name}",
          node_type: node_type_id,
          node_id: node_id
        )

      {:error, changeset} ->
        Logger.warning("Failed to validate node execution start",
          execution_id: execution.id,
          node_id: node_id,
          errors: inspect(changeset.errors)
        )
    end

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
        case Changeset.apply_action(
               NodeExecution.changeset(node_exec, %{
                 status: :completed,
                 output_data: output_data,
                 completed_at: now
               }),
               :update
             ) do
          {:ok, updated} ->
            ExecutionState.put_node_execution(execution.id, node_id, updated)
            NodeExecutionBuffer.record(updated)
            ExecutionPubSub.broadcast_node_completed(execution, updated)

            Logger.info("Node completed: #{node_name}",
              duration_ms: duration_ms,
              node_id: node_id
            )

          {:error, changeset} ->
            Logger.warning("Failed to validate node execution completion",
              execution_id: execution.id,
              node_id: node_id,
              errors: inspect(changeset.errors)
            )
        end

      nil ->
        started_at = DateTime.add(now, -duration_ms, :millisecond)

        attrs = %{
          id: Ecto.UUID.generate(),
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

        case Changeset.apply_action(NodeExecution.changeset(%NodeExecution{}, attrs), :insert) do
          {:ok, node_exec} ->
            ExecutionState.put_node_execution(execution.id, node_id, node_exec)
            NodeExecutionBuffer.record(node_exec)
            ExecutionPubSub.broadcast_node_completed(execution, node_exec)

            Logger.info("Node completed: #{node_name}",
              duration_ms: duration_ms,
              node_id: node_id
            )

          {:error, _changeset} ->
            :ok
        end
    end

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

    alias Imgd.Repo

    NodeExecution
    |> where(
      [n],
      n.execution_id == ^execution_id and n.node_id == ^node_id and n.status == :running
    )
    |> order_by([n], desc: n.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # ===========================================================================
  # Log Extraction
  # ===========================================================================

  defp extract_build_log(workflow) do
    try do
      workflow |> Workflow.build_log() |> Enum.map(&serialize_event/1)
    rescue
      _ -> []
    end
  end

  defp extract_execution_log(workflow) do
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

  # ===========================================================================
  # Output Helpers
  # ===========================================================================

  defp determine_output(productions) when is_list(productions) do
    case productions do
      [] -> %{}
      [single] -> %{"result" => single}
      multiple -> %{"results" => multiple}
    end
  end

  # ===========================================================================
  # Data Serialization
  # ===========================================================================

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

  defp sanitize_map_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_value_for_json(v)} end)
  end

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

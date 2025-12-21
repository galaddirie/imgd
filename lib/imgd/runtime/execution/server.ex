defmodule Imgd.Runtime.Execution.Server do
  @moduledoc """
  OTP process responsible for a single workflow execution.
  Manages lifecycle, node orchestration, control flow, and state persistence.

  ## Control Flow Support

  This server supports:
  - **Conditional branching**: Branch/Switch nodes route to specific outputs
  - **Skip propagation**: Inactive branches receive skip signals
  - **Join semantics**: Merge nodes with wait_any/wait_all modes
  - **Items processing**: Map mode for parallel item execution (Phase 2)

  ## Execution Model

  Nodes are categorized by their connection routing needs:
  - Standard nodes: Single "main" output, all children receive data
  - Routing nodes (Branch, Switch): Multiple named outputs, children filtered by route
  - Join nodes (Merge): Multiple parents, special input gathering

  ## State Management

  - `node_states`: Track status per node (:pending, :running, :completed, :failed, :skipped)
  - `node_results`: Store output tokens per node
  - `active_routes`: Map of node_id => active output routes
  """

  @behaviour :gen_statem

  require Logger
  alias Imgd.Graph
  alias Imgd.Runtime.Core.NodeRunner
  alias Imgd.Runtime.Token
  alias Imgd.Executions.{Execution, NodeExecution}

  # Timing diagnostics for performance monitoring
  defp timed(label, fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    t1 = System.monotonic_time(:microsecond)
    Logger.debug("#{label}: #{t1 - t0}μs")
    result
  end

  # Data structure for the server state
  defstruct [
    :execution_id,
    :execution,
    :workflow_version,
    :graph,
    :node_map,
    :connection_map,
    :node_states,
    :node_results,
    :active_routes,
    :running_tasks,
    :persistence,
    :notifier,
    :start_time
  ]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  # ============================================================================
  # API
  # ============================================================================

  def child_spec(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)

    %{
      id: {__MODULE__, execution_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)

    :gen_statem.start_link(
      {:via, Registry, {Imgd.Runtime.Execution.Registry, execution_id}},
      __MODULE__,
      opts,
      []
    )
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)
    persistence = Keyword.get(opts, :persistence, Imgd.Runtime.Execution.EctoPersistence)
    notifier = Keyword.get(opts, :notifier, Imgd.Runtime.Execution.Notifier)

    data = %__MODULE__{
      execution_id: execution_id,
      persistence: persistence,
      notifier: notifier,
      node_states: %{},
      node_results: %{},
      active_routes: %{},
      running_tasks: %{},
      connection_map: %{}
    }

    actions = [{:next_event, :internal, :load_execution}]
    {:ok, :initializing, data, actions}
  end

  @impl true
  def handle_event(:enter, _old_state, :initializing, _data), do: :keep_state_and_data
  def handle_event(:enter, _old_state, :running, _data), do: :keep_state_and_data
  def handle_event(:enter, _old_state, :terminating, _data), do: :keep_state_and_data

  @impl true
  def handle_event(:internal, :load_execution, :initializing, data) do
    case data.persistence.load_execution(data.execution_id) do
      {:ok, execution} ->
        {nodes, connections} = load_immutable_source(execution)
        node_map = Map.new(nodes, &{&1.id, &1})
        connection_map = build_connection_map(connections)

        case Graph.from_workflow(nodes, connections) do
          {:ok, graph} ->
            {graph, node_results} = prepare_graph_and_state(graph, execution)
            node_states = Map.new(Map.keys(node_results), &{&1, :completed})
            # Initialize active routes for pinned nodes
            active_routes = Map.new(Map.keys(node_results), &{&1, ["main"]})

            data = %{
              data
              | execution: execution,
                workflow_version: execution.workflow_version,
                graph: graph,
                node_map: node_map,
                connection_map: connection_map,
                node_results: node_results,
                node_states: node_states,
                active_routes: active_routes
            }

            case data.persistence.mark_running(data.execution_id) do
              {:ok, updated_execution} ->
                data = %{data | execution: updated_execution}
                data.notifier.broadcast_execution_event(:started, updated_execution)
                {:next_state, :running, data, [{:next_event, :internal, :check_runnable}]}

              {:error, reason} ->
                stop_with_error(data, reason)
            end

          {:error, reason} ->
            stop_with_error(data, reason)
        end

      {:error, reason} ->
        {:stop, reason, data}
    end
  end

  # ============================================================================
  # RUNNING State
  # ============================================================================

  def handle_event(:internal, :check_runnable, :running, data) do
    # First, propagate skips to nodes that can be determined as skipped
    data = propagate_skips(data)

    # Find nodes that are ready to run
    runnable = get_runnable_nodes(data)

    if Enum.empty?(runnable) and Enum.empty?(data.running_tasks) do
      if execution_complete?(data) do
        finish_execution(data)
      else
        # Might be stuck - log and complete with partial results
        Logger.warning("Execution stuck with nodes pending",
          execution_id: data.execution_id,
          pending: pending_nodes(data)
        )

        finish_execution(data)
      end
    else
      data = Enum.reduce(runnable, data, &spawn_node_task/2)
      {:keep_state, data}
    end
  end

  def handle_event(:info, {ref, result}, :running, data) do
    case Map.pop(data.running_tasks, ref) do
      {nil, _} ->
        {:keep_state, data}

      {{_node_id, start_time, node_exec}, remaining_tasks} ->
        Process.demonitor(ref, [:flush])
        data = %{data | running_tasks: remaining_tasks}
        duration_us = System.monotonic_time(:microsecond) - start_time
        duration_ms = div(duration_us, 1000)
        handle_node_result(node_exec, result, duration_ms, data)
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :running, data) do
    case Map.pop(data.running_tasks, ref) do
      {nil, _} ->
        {:keep_state, data}

      {{_node_id, _start_time, node_exec}, remaining_tasks} ->
        data = %{data | running_tasks: remaining_tasks}
        handle_node_result(node_exec, {:error, {:process_crash, reason}}, 0, data)
    end
  end

  # ============================================================================
  # Control Flow Logic
  # ============================================================================

  # Builds a map of connections indexed by source node for route-aware traversal.
  defp build_connection_map(connections) do
    Enum.group_by(connections, & &1.source_node_id)
  end

  # Determines which nodes can be skipped because they're on inactive branches.
  defp propagate_skips(data) do
    # Find nodes that have all parents either completed or skipped,
    # but are not reachable through any active route
    pending = pending_nodes(data)

    skippable =
      Enum.filter(pending, fn node_id ->
        should_skip_node?(node_id, data)
      end)

    Enum.reduce(skippable, data, fn node_id, acc ->
      mark_node_skipped(node_id, acc, "inactive_branch")
    end)
  end

  # Checks if a node should be skipped because it's on an inactive branch.
  defp should_skip_node?(node_id, data) do
    parents = Graph.parents(data.graph, node_id)

    if Enum.empty?(parents) do
      false
    else
      # All parents must have a terminal state
      all_parents_done =
        Enum.all?(parents, fn pid ->
          Map.get(data.node_states, pid) in [:completed, :failed, :skipped]
        end)

      if not all_parents_done do
        false
      else
        # Check if ANY parent has an active route to this node
        has_active_route =
          Enum.any?(parents, fn parent_id ->
            parent_routes_to_node?(parent_id, node_id, data)
          end)

        not has_active_route
      end
    end
  end

  # Checks if parent's active routes include a connection to target node.
  defp parent_routes_to_node?(parent_id, target_id, data) do
    case Map.get(data.node_states, parent_id) do
      :skipped ->
        false

      :completed ->
        active_routes = Map.get(data.active_routes, parent_id, ["main"])
        connections = Map.get(data.connection_map, parent_id, [])

        Enum.any?(connections, fn conn ->
          conn.target_node_id == target_id and
            conn.source_output in active_routes
        end)

      _ ->
        # Parent not done yet
        true
    end
  end

  defp mark_node_skipped(node_id, data, reason) do
    token = Token.skip(reason, source_node_id: node_id)

    data
    |> put_node_state(node_id, :skipped)
    |> put_node_result(node_id, token)
  end

  # ============================================================================
  # Node Execution
  # ============================================================================

  defp get_runnable_nodes(data) do
    Graph.vertex_ids(data.graph)
    |> Enum.filter(fn id ->
      status = Map.get(data.node_states, id)
      is_nil(status) and parents_ready?(id, data) and has_active_path?(id, data)
    end)
  end

  defp parents_ready?(node_id, data) do
    node = Map.get(data.node_map, node_id)
    parents = Graph.parents(data.graph, node_id)

    if is_merge_node?(node) do
      # Merge nodes with wait_any only need one active parent
      join_mode = get_join_mode(node)
      check_parents_for_join(parents, join_mode, data)
    else
      # Standard nodes need all parents done
      Enum.all?(parents, fn pid ->
        Map.get(data.node_states, pid) in [:completed, :skipped]
      end)
    end
  end

  defp check_parents_for_join(parents, "wait_any", data) do
    # At least one parent completed (not skipped)
    # Or all parents are terminal (even if all skipped)
    Enum.any?(parents, fn pid ->
      Map.get(data.node_states, pid) == :completed
    end) or
      Enum.all?(parents, fn pid ->
        Map.get(data.node_states, pid) in [:completed, :skipped, :failed]
      end)
  end

  defp check_parents_for_join(parents, _mode, data) do
    # wait_all: all parents must be terminal
    Enum.all?(parents, fn pid ->
      Map.get(data.node_states, pid) in [:completed, :skipped, :failed]
    end)
  end

  defp has_active_path?(node_id, data) do
    parents = Graph.parents(data.graph, node_id)

    # Root nodes always have active path
    if Enum.empty?(parents) do
      true
    else
      # At least one parent routes to us
      Enum.any?(parents, fn pid ->
        parent_routes_to_node?(pid, node_id, data)
      end)
    end
  end

  defp is_merge_node?(%{type_id: "merge"}), do: true
  defp is_merge_node?(_), do: false

  defp get_join_mode(node) do
    Map.get(node.config, "mode", "wait_any")
  end

  defp spawn_node_task(node_id, data) do
    node = Map.fetch!(data.node_map, node_id)
    t0 = System.monotonic_time(:microsecond)

    input = timed("gather_inputs", fn -> gather_inputs(node_id, data) end)

    context_fun = fn ->
      timed("build_context", fn -> build_context(data, input) end)
    end

    execution = data.execution
    start_time = System.monotonic_time(:microsecond)

    {:ok, node_exec} =
      timed("record_node_start", fn ->
        data.persistence.record_node_start(data.execution_id, node, input)
      end)

    data.notifier.broadcast_node_event(:started, execution, node_exec)

    task =
      Task.async(fn ->
        timed("node_runner", fn ->
          NodeRunner.run(node, input, context_fun, execution)
        end)
      end)

    total_time = System.monotonic_time(:microsecond) - t0
    Logger.debug("spawn_node_task total: #{total_time}μs for node #{node_id}")

    data
    |> put_node_state(node_id, :running)
    |> Map.update!(:running_tasks, &Map.put(&1, task.ref, {node_id, start_time, node_exec}))
  end

  defp gather_inputs(node_id, data) do
    node = Map.get(data.node_map, node_id)
    parents = Graph.parents(data.graph, node_id)

    cond do
      # Root node - use trigger data
      Enum.empty?(parents) ->
        Execution.trigger_data(data.execution)

      # Merge node - gather from all parents with IDs
      is_merge_node?(node) ->
        gather_merge_inputs(parents, data)

      # Single parent - pass through
      length(parents) == 1 ->
        [parent_id] = parents
        unwrap_result(Map.get(data.node_results, parent_id))

      # Multiple parents (non-merge) - create keyed map
      true ->
        Map.new(parents, fn pid ->
          {pid, unwrap_result(Map.get(data.node_results, pid))}
        end)
    end
  end

  defp gather_merge_inputs(parents, data) do
    Map.new(parents, fn pid ->
      result = Map.get(data.node_results, pid)
      # Keep tokens for merge to inspect skip status
      {pid, result}
    end)
  end

  defp unwrap_result(%Token{} = token), do: Token.unwrap(token)
  defp unwrap_result(other), do: other

  defp handle_node_result(%NodeExecution{} = node_exec, result, duration_ms, data) do
    node_id = node_exec.node_id

    {status, output, routes} =
      case result do
        {:ok, %Token{} = token} ->
          {:completed, token, [token.route]}

        {:ok, out} ->
          {:completed, Token.wrap(out), ["main"]}

        {:skip, reason} ->
          {:skipped, Token.skip(to_string(reason)), []}

        {:error, reason} ->
          {:failed, reason, []}
      end

    # Record finish
    {:ok, node_exec} =
      timed("record_node_finish", fn ->
        result_for_db = if status == :failed, do: output, else: Token.unwrap(output)
        data.persistence.record_node_finish(node_exec, status, result_for_db, duration_ms)
      end)

    # Notify
    event_type = if status == :failed, do: :failed, else: :completed
    data.notifier.broadcast_node_event(event_type, data.execution, node_exec)

    # Update state with route information
    data =
      data
      |> put_node_state(node_id, status)
      |> put_node_result(node_id, output)
      |> put_active_routes(node_id, routes)

    if status == :failed do
      fail_execution(data, output)
    else
      {:next_state, :running, data, [{:next_event, :internal, :check_runnable}]}
    end
  end

  # ============================================================================
  # Completion Logic
  # ============================================================================

  defp execution_complete?(data) do
    Graph.vertex_ids(data.graph)
    |> Enum.all?(fn id ->
      Map.get(data.node_states, id) in [:completed, :skipped, :failed]
    end)
  end

  defp pending_nodes(data) do
    Graph.vertex_ids(data.graph)
    |> Enum.filter(fn id ->
      Map.get(data.node_states, id) not in [:completed, :skipped, :failed]
    end)
  end

  defp finish_execution(data) do
    leaves = Graph.leaves(data.graph)

    # Filter to active leaves only
    active_leaves =
      Enum.filter(leaves, fn id ->
        Map.get(data.node_states, id) == :completed
      end)

    output =
      case active_leaves do
        [] -> %{}
        [one] -> unwrap_result(Map.get(data.node_results, one))
        many -> Map.new(many, &{&1, unwrap_result(Map.get(data.node_results, &1))})
      end

    # Convert node_results to plain values for context storage
    context =
      Map.new(data.node_results, fn {k, v} ->
        {k, unwrap_result(v)}
      end)

    case data.persistence.mark_completed(data.execution_id, output, context) do
      {:ok, updated_execution} ->
        data.notifier.broadcast_execution_event(:completed, updated_execution)
        {:stop, :normal, %{data | execution: updated_execution}}

      {:error, reason} ->
        stop_with_error(data, reason)
    end
  end

  defp fail_execution(data, error) do
    case data.persistence.mark_failed(data.execution_id, error) do
      {:ok, updated_execution} ->
        data.notifier.broadcast_execution_event(:failed, updated_execution)
        {:stop, :normal, %{data | execution: updated_execution}}

      {:error, reason} ->
        stop_with_error(data, reason)
    end
  end

  defp stop_with_error(data, reason) do
    data.persistence.mark_failed(data.execution_id, reason)
    {:stop, reason, data}
  end

  # ============================================================================
  # State Helpers
  # ============================================================================

  defp put_node_state(data, id, status), do: put_in(data.node_states[id], status)
  defp put_node_result(data, id, result), do: put_in(data.node_results[id], result)

  defp put_active_routes(data, id, routes) do
    %{data | active_routes: Map.put(data.active_routes, id, routes)}
  end

  defp build_context(data, input) do
    Imgd.Runtime.Expression.Context.build(
      data.execution,
      Map.new(data.node_results, fn {k, v} -> {k, unwrap_result(v)} end),
      input
    )
  end

  defp load_immutable_source(%Execution{} = execution) do
    cond do
      not is_nil(execution.workflow_version_id) ->
        version = execution.workflow_version
        {version.nodes, version.connections}

      not is_nil(execution.workflow_snapshot_id) ->
        snapshot = execution.workflow_snapshot
        {snapshot.nodes, snapshot.connections}

      true ->
        raise "Execution #{execution.id} has no immutable source (version or snapshot)"
    end
  end

  defp prepare_graph_and_state(graph, execution) do
    metadata = execution.metadata || %{}
    extras = Map.get(metadata, "extras") || Map.get(metadata, :extras) || %{}
    pinned_data = execution.pinned_data || %{}

    is_partial =
      Map.get(extras, "partial") == true or Map.get(extras, :partial) == true

    if is_partial do
      target_nodes =
        case Map.get(extras, "target_nodes") || Map.get(extras, :target_nodes) do
          nil ->
            case Map.get(extras, "target_node") || Map.get(extras, :target_node) do
              nil -> []
              target_node -> [target_node]
            end

          target_nodes when is_list(target_nodes) ->
            target_nodes

          target_node ->
            [target_node]
        end

      pinned_ids =
        case Map.get(extras, "pinned_nodes") || Map.get(extras, :pinned_nodes) do
          nil -> []
          pinned_ids when is_list(pinned_ids) -> pinned_ids
          pinned_id -> [pinned_id]
        end

      pinned_outputs = Map.take(pinned_data, pinned_ids)

      subgraph =
        Graph.execution_subgraph(graph, target_nodes, pinned: pinned_ids, include_targets: true)

      {subgraph, pinned_outputs}
    else
      {graph, pinned_data}
    end
  end
end

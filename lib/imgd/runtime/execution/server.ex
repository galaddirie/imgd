defmodule Imgd.Runtime.Execution.Server do
  @moduledoc """
  OTP process responsible for a single workflow execution.
  Manages lifecycle, node orchestration, and state persistence.
  """

  @behaviour :gen_statem

  require Logger
  alias Imgd.Graph
  alias Imgd.Runtime.Core.NodeRunner
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
    # Loaded Execution struct
    :execution,
    # Associated WorkflowVersion
    :workflow_version,
    # Digraph of dependencies
    :graph,
    # Map of node_id -> node_def
    :node_map,
    # Map of node_id -> status (:pending, :running, :completed, :failed, :skipped)
    :node_states,
    # Map of node_id -> output/error
    :node_results,
    # Map of ref -> {node_id, start_time, node_exec}
    :running_tasks,
    # Persistence adapter module
    :persistence,
    # Notifier adapter module
    :notifier,
    # Monotonic time
    :start_time
  ]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  # API

  @doc """
  Child specification for supervision tree.
  Required because gen_statem doesn't auto-define this like GenServer.
  """
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

  # Callbacks

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
      running_tasks: %{}
    }

    # Use internal event to trigger loading so init is fast
    actions = [{:next_event, :internal, :load_execution}]
    {:ok, :initializing, data, actions}
  end

  # State enter handlers (required for :state_enter callback mode)
  @impl true
  def handle_event(:enter, _old_state, :initializing, _data) do
    :keep_state_and_data
  end

  def handle_event(:enter, _old_state, :running, _data) do
    :keep_state_and_data
  end

  @impl true
  def handle_event(:internal, :load_execution, :initializing, data) do
    case data.persistence.load_execution(data.execution_id) do
      {:ok, execution} ->
        # Load nodes and connections from exactly one immutable source
        {nodes, connections} = load_immutable_source(execution)
        node_map = Map.new(nodes, &{&1.id, &1})

        case Graph.from_workflow(nodes, connections) do
          {:ok, graph} ->
            # Handle Partial execution using snapshotted pins
            {graph, node_results} = prepare_graph_and_state(graph, execution)

            # Initialize states for completed/pinned nodes
            node_states = Map.new(Map.keys(node_results), &{&1, :completed})

            data = %{
              data
              | execution: execution,
                workflow_version: execution.workflow_version,
                graph: graph,
                node_map: node_map,
                node_results: node_results,
                node_states: node_states
            }

            # Mark running
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

  # RUNNING State

  def handle_event(:internal, :check_runnable, :running, data) do
    # Determine nodes that can run
    runnable = get_runnable_nodes(data)

    if Enum.empty?(runnable) and Enum.empty?(data.running_tasks) do
      # No more work, check if we are done
      if all_nodes_completed?(data) do
        finish_execution(data)
      else
        # Graph might be stuck (should verify cyclic check on build), or just waiting
        # In this simplified version, if nothing is running and nothing is runnable, we are done
        # but maybe incomplete.
        finish_execution(data)
      end
    else
      # Spawn tasks
      data =
        Enum.reduce(runnable, data, fn node_id, acc ->
          spawn_node_task(node_id, acc)
        end)

      {:keep_state, data}
    end
  end

  def handle_event(:info, {ref, result}, :running, data) do
    # Task returned
    case Map.pop(data.running_tasks, ref) do
      {nil, _} ->
        # Unknown task
        {:keep_state, data}

      {{_node_id, start_time, node_exec}, remaining_tasks} ->
        Process.demonitor(ref, [:flush])
        data = %{data | running_tasks: remaining_tasks}

        # Calculate duration from stored start_time
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
        # Treat crash as failure (no duration available for crashes)
        handle_node_result(node_exec, {:error, {:process_crash, reason}}, 0, data)
    end
  end

  # TERMINATING

  def handle_event(:enter, _old_state, :terminating, _data) do
    {:keep_state_and_data}
  end

  # Private Helpers

  defp prepare_graph_and_state(graph, execution) do
    metadata = execution.metadata || %{}
    extras = Map.get(metadata, "extras") || Map.get(metadata, :extras) || %{}

    # Extract pinned_data once for both partial and full executions
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

      # Use snapshotted pinned_data from the execution record
      pinned_outputs = Map.take(pinned_data, pinned_ids)

      subgraph =
        Graph.execution_subgraph(graph, target_nodes, pinned: pinned_ids, include_targets: true)

      {subgraph, pinned_outputs}
    else
      # For full preview/production executions, ALSO use pinned data
      {graph, pinned_data}
    end
  end

  defp get_runnable_nodes(data) do
    # Find nodes that correspond to:
    # 1. Not started yet (status nil)
    # 2. All parents completed successfully (or pinned)

    Graph.vertex_ids(data.graph)
    |> Enum.filter(fn id ->
      status = Map.get(data.node_states, id)
      is_nil(status) and parents_completed?(id, data)
    end)
  end

  defp parents_completed?(id, data) do
    parents = Graph.parents(data.graph, id)

    Enum.all?(parents, fn p_id ->
      Map.get(data.node_states, p_id) == :completed
    end)
  end

  defp all_nodes_completed?(data) do
    Graph.vertex_ids(data.graph)
    # failed stops execution?
    |> Enum.all?(fn id -> Map.get(data.node_states, id) in [:completed, :skipped] end)
  end

  defp spawn_node_task(node_id, data) do
    node = Map.fetch!(data.node_map, node_id)

    # TIMING: Track key operations
    t0 = System.monotonic_time(:microsecond)

    # 1. Gather inputs from parents
    input = timed("gather_inputs", fn -> gather_inputs(node_id, data) end)

    # 2. Build context lazily (only when needed)
    context_fun = fn ->
      timed("build_context", fn -> build_context(data, input) end)
    end

    execution = data.execution
    start_time = System.monotonic_time(:microsecond)

    # Record start (async persistence, but returns node_exec for broadcasting)
    {:ok, node_exec} =
      timed("record_node_start", fn ->
        data.persistence.record_node_start(data.execution_id, node, input)
      end)

    # Notify synchronously (fast operation)
    data.notifier.broadcast_node_event(:started, execution, node_exec)

    # Single task for node execution
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

  defp handle_node_result(%NodeExecution{} = node_exec, result, duration_ms, data) do
    node_id = node_exec.node_id

    {status, output} =
      case result do
        {:ok, out} -> {:completed, out}
        {:skip, _reason} -> {:skipped, nil}
        {:error, reason} -> {:failed, reason}
      end

    # Record finish (async persistence, but returns updated node_exec)
    {:ok, node_exec} =
      timed("record_node_finish", fn ->
        data.persistence.record_node_finish(
          node_exec,
          status,
          if(status == :failed, do: output, else: output),
          duration_ms
        )
      end)

    # Notify synchronously
    event_type = if status == :failed, do: :failed, else: :completed
    data.notifier.broadcast_node_event(event_type, data.execution, node_exec)

    # Update internal state
    data =
      data
      |> put_node_state(node_id, status)
      |> put_node_result(node_id, output)

    if status == :failed do
      fail_execution(data, output)
    else
      {:next_state, :running, data, [{:next_event, :internal, :check_runnable}]}
    end
  end

  defp gather_inputs(node_id, data) do
    parents = Graph.parents(data.graph, node_id)

    case parents do
      [] ->
        Execution.trigger_data(data.execution)

      [single] ->
        Map.get(data.node_results, single)

      multiple ->
        Map.new(multiple, fn pid -> {pid, Map.get(data.node_results, pid)} end)
    end
  end

  defp build_context(data, input) do
    # Use the pure Context builder with current input
    Imgd.Runtime.Expression.Context.build(data.execution, data.node_results, input)
  end

  defp stop_with_error(data, reason) do
    # Try to mark failed if we can
    data.persistence.mark_failed(data.execution_id, reason)
    {:stop, reason, data}
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

  defp finish_execution(data) do
    # Determine final output (leaves)
    leaves = Graph.leaves(data.graph)

    output =
      case leaves do
        [] -> %{}
        [one] -> Map.get(data.node_results, one)
        many -> Map.new(many, &{&1, Map.get(data.node_results, &1)})
      end

    case data.persistence.mark_completed(data.execution_id, output, data.node_results) do
      {:ok, updated_execution} ->
        data.notifier.broadcast_execution_event(:completed, updated_execution)
        {:stop, :normal, %{data | execution: updated_execution}}

      {:error, reason} ->
        stop_with_error(data, reason)
    end
  end

  defp put_node_state(data, id, status), do: put_in(data.node_states[id], status)
  defp put_node_result(data, id, result), do: put_in(data.node_results[id], result)

  defp load_immutable_source(%Execution{} = execution) do
    cond do
      not is_nil(execution.workflow_version_id) ->
        version = execution.workflow_version
        {version.nodes, version.connections}

      not is_nil(execution.workflow_snapshot_id) ->
        snapshot = execution.workflow_snapshot
        {snapshot.nodes, snapshot.connections}

      true ->
        # This should be impossible due to database constraints
        raise "Execution #{execution.id} has no immutable source (version or snapshot)"
    end
  end
end

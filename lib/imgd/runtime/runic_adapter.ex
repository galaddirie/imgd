defmodule Imgd.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Imgd workflow definitions (Steps/Connections) with the Runic execution engine.
  """

  require Runic
  alias Runic.Component
  alias Runic.Workflow
  alias Runic.Workflow.FanOut
  alias Imgd.Runtime.Steps.StepRunner

  @type source :: Imgd.Workflows.WorkflowDraft.t() | map()
  @type build_opts :: [
          execution_id: String.t(),
          variables: map(),
          metadata: map(),
          step_outputs: map(),
          trigger_data: map(),
          trigger_type: atom(),
          default_compute: term()
        ]

  @spec to_runic_workflow(source(), build_opts()) :: Workflow.t()
  def to_runic_workflow(source, opts \\ []) do
    step_outputs = Keyword.get(opts, :step_outputs, Keyword.get(opts, :pinned_outputs, %{}))

    graph = Imgd.Graph.from_workflow!(source.steps, source.connections, validate: false)
    upstream_lookup = build_upstream_lookup(graph)

    step_opts = [
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: extract_source_id(source),
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      step_outputs: step_outputs,
      upstream_lookup: upstream_lookup,
      trigger_data: Keyword.get(opts, :trigger_data, %{}),
      trigger_type: Keyword.get(opts, :trigger_type),
      default_compute: Keyword.get(opts, :default_compute)
    ]

    wrk = Workflow.new(name: "execution_#{extract_source_id(source)}")
    parent_lookup = build_parent_lookup(source.connections)
    sorted_steps = topological_sort_steps(source.steps, source.connections)

    # Build splitter lookup to detect fan-out paths
    splitter_ids =
      source.steps
      |> Enum.filter(&(&1.type_id == "splitter"))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    step_opts = Keyword.put(step_opts, :splitter_ids, splitter_ids)

    wrk =
      Enum.reduce(sorted_steps, wrk, fn step, acc ->
        add_step_to_workflow(step, acc, parent_lookup, step_opts)
      end)

    wrk
    |> put_step_metadata(source.steps)
    |> track_all_fan_out_paths()  # Track ALL fan-out paths for observability
  end

  @spec create_component(Imgd.Workflows.Embeds.Step.t(), String.t(), build_opts()) :: term()
  def create_component(step, component_name, opts \\ []) do
    case step.type_id do
      "splitter" ->
        create_splitter(step, component_name, opts)

      "aggregator" ->
        # Default to join-style aggregator; fan-out aggregator created in add_step_to_workflow
        create_join_aggregator(step, component_name)

      "condition" ->
        create_condition(step, component_name, opts)

      "switch" ->
        create_switch(step, component_name, opts)

      _ ->
        StepRunner.create(step, opts)
    end
  end

  # ===========================================================================
  # Public helpers for aggregation (called from closures via __MODULE__)
  # ===========================================================================

  @doc false
  def normalize_aggregator_input(nil), do: []

  def normalize_aggregator_input(input) when is_list(input) do
    input
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  def normalize_aggregator_input(input), do: [input]

  @doc false
  def apply_aggregation("sum", items) do
    items
    |> Enum.map(&to_number/1)
    |> Enum.sum()
  end

  def apply_aggregation("count", items), do: length(items)

  def apply_aggregation("concat", items) do
    Enum.map_join(items, "", &to_string/1)
  end

  def apply_aggregation("first", []), do: nil
  def apply_aggregation("first", items), do: List.first(items)

  def apply_aggregation("last", []), do: nil
  def apply_aggregation("last", items), do: List.last(items)

  def apply_aggregation("min", []), do: nil
  def apply_aggregation("min", items), do: Enum.min(items)

  def apply_aggregation("max", []), do: nil
  def apply_aggregation("max", items), do: Enum.max(items)

  # Default "collect" - return flattened list
  def apply_aggregation(_, items), do: items

  @doc false
  def to_number(n) when is_number(n), do: n

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  def to_number(_), do: 0

  # Normalize an item that might be a single value or a list (from a Join)
  @doc false
  def normalize_item(nil), do: []

  def normalize_item(item) when is_list(item) do
    item |> List.flatten() |> Enum.reject(&is_nil/1)
  end

  def normalize_item(item), do: [item]

  # ===========================================================================
  # Private: Workflow Building
  # ===========================================================================

  defp add_step_to_workflow(step, workflow, parent_lookup, step_opts) do
    component_name = step.id

    parent_ids =
      parent_lookup
      |> Map.get(step.id, [])
      |> Enum.uniq()

    # Determine if this aggregator should use fan-out or join semantics
    component =
      if step.type_id == "aggregator" do
        splitter_ids = Keyword.get(step_opts, :splitter_ids, MapSet.new())
        upstream_lookup = Keyword.get(step_opts, :upstream_lookup, %{})
        upstream_ids = Map.get(upstream_lookup, step.id, [])

        # Check if there's a splitter anywhere upstream
        has_upstream_splitter = Enum.any?(upstream_ids, &MapSet.member?(splitter_ids, &1))

        if has_upstream_splitter do
          # Fan-out context: use Runic.reduce to accumulate ALL items
          create_fanout_aggregator(step, component_name)
        else
          # No fan-out upstream: use regular step that handles list input from join
          create_join_aggregator(step, component_name)
        end
      else
        create_component(step, component_name, step_opts)
      end

    workflow = connect_component(workflow, component, parent_ids)
    maybe_connect_fan_in(workflow, component)
  end

  defp connect_component(workflow, component, []) do
    Workflow.add(workflow, component)
  end

  defp connect_component(workflow, component, [parent_id]) do
    Workflow.add(workflow, component, to: parent_id)
  end

  defp connect_component(workflow, component, parent_ids) do
    {workflow, join} = ensure_join(workflow, parent_ids)
    Workflow.add(workflow, component, to: join)
  end

  defp maybe_connect_fan_in(workflow, %Runic.Workflow.Reduce{fan_in: fan_in}) do
    case find_upstream_fan_out(workflow, fan_in) do
      nil ->
        workflow

      fan_out ->
        # Draw the :fan_in edge AND track the path (original behavior)
        # Both steps are critical for Runic to work correctly
        workflow
        |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
        |> track_mapped_path(fan_out, fan_in)
    end
  end

  defp maybe_connect_fan_in(workflow, _component), do: workflow

  # Original path tracking - finds shortest path from FanOut to FanIn
  # This is called per-aggregator during workflow construction
  defp track_mapped_path(workflow, fan_out, fan_in) do
    path = workflow.graph |> Graph.get_shortest_path(fan_out, fan_in)

    path_hashes =
      Enum.reduce(path || [], MapSet.new(), fn node, mapset ->
        case node do
          %{hash: hash} -> MapSet.put(mapset, hash)
          _ -> mapset
        end
      end)

    %Workflow{
      workflow
      | mapped:
          Map.put(
            workflow.mapped,
            :mapped_paths,
            MapSet.union(workflow.mapped[:mapped_paths] || MapSet.new(), path_hashes)
          )
    }
  end

  defp find_upstream_fan_out(workflow, fan_in) do
    do_find_upstream_fan_out(workflow.graph, [fan_in], MapSet.new())
  end

  defp do_find_upstream_fan_out(_graph, [], _visited), do: nil

  defp do_find_upstream_fan_out(graph, [current | rest], visited) do
    if MapSet.member?(visited, current) do
      do_find_upstream_fan_out(graph, rest, visited)
    else
      visited = MapSet.put(visited, current)

      case current do
        %FanOut{} ->
          current

        _ ->
          predecessors =
            graph
            |> Graph.in_edges(current)
            |> Enum.filter(&(&1.label == :flow))
            |> Enum.map(& &1.v1)

          do_find_upstream_fan_out(graph, predecessors ++ rest, visited)
      end
    end
  end

  # ===========================================================================
  # Fan-out Path Tracking (for observability - item_index/items_total)
  # ===========================================================================

  @doc """
  Traverses the workflow graph to find ALL steps downstream of each FanOut node.
  This ensures item_index/items_total are tracked for ALL branches, not just
  the shortest path to an aggregator.

  This is called AFTER the workflow is fully built, so all edges exist.
  """
  defp track_all_fan_out_paths(workflow) do
    # Find all FanOut nodes in the graph
    fan_outs =
      workflow.graph
      |> Graph.vertices()
      |> Enum.filter(&match?(%FanOut{}, &1))

    # For each FanOut, find all downstream nodes and add their hashes to mapped_paths
    Enum.reduce(fan_outs, workflow, fn fan_out, wf ->
      downstream_hashes = find_all_downstream_hashes(wf.graph, fan_out)

      existing_paths = wf.mapped[:mapped_paths] || MapSet.new()
      new_paths = MapSet.union(existing_paths, downstream_hashes)

      %Workflow{wf | mapped: Map.put(wf.mapped, :mapped_paths, new_paths)}
    end)
  end

  @doc """
  Finds all node hashes that are downstream of a given node.
  Stops traversal at FanIn/Reduce nodes (aggregators) but includes all branches.
  Includes ALL node types with hashes (Steps, Joins, etc.) to match original behavior.
  """
  defp find_all_downstream_hashes(graph, start_node) do
    do_find_downstream_hashes(graph, [start_node], MapSet.new(), MapSet.new())
  end

  defp do_find_downstream_hashes(_graph, [], _visited, acc), do: acc

  defp do_find_downstream_hashes(graph, [current | rest], visited, acc) do
    if MapSet.member?(visited, current) do
      do_find_downstream_hashes(graph, rest, visited, acc)
    else
      visited = MapSet.put(visited, current)

      # Add hash for ANY node with a hash field (matches original track_mapped_path behavior)
      acc =
        case current do
          %{hash: hash} when not is_nil(hash) ->
            MapSet.put(acc, hash)

          _ ->
            acc
        end

      # Get successors - stop at FanIn/Reduce (aggregators don't propagate fan-out context)
      successors =
        case current do
          %Runic.Workflow.FanIn{} ->
            # Stop here - aggregator boundary
            []

          %Runic.Workflow.Reduce{} ->
            # Stop here - aggregator boundary
            []

          _ ->
            # Continue traversal through all outgoing flow edges
            graph
            |> Graph.out_edges(current)
            |> Enum.filter(&(&1.label == :flow))
            |> Enum.map(& &1.v2)
        end

      do_find_downstream_hashes(graph, successors ++ rest, visited, acc)
    end
  end

  # ===========================================================================
  # Rest of the module (unchanged from original)
  # ===========================================================================

  defp ensure_join(%Workflow{} = workflow, parent_ids) when is_list(parent_ids) do
    parent_steps = Enum.map(parent_ids, &Workflow.get_component!(workflow, &1))
    parent_hashes = Enum.map(parent_steps, &Component.hash/1)
    join = Workflow.Join.new(parent_hashes)

    case Map.get(workflow.graph.vertices, join.hash) do
      %Workflow.Join{} = existing_join -> {workflow, existing_join}
      nil -> {Workflow.add_step(workflow, parent_steps, join), join}
    end
  end

  defp extract_source_id(source) do
    Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"
  end

  defp build_parent_lookup(connections) do
    Enum.group_by(connections, & &1.target_step_id, & &1.source_step_id)
  end

  defp build_upstream_lookup(graph) do
    Enum.reduce(Imgd.Graph.vertex_ids(graph), %{}, fn step_id, acc ->
      Map.put(acc, step_id, Imgd.Graph.upstream(graph, step_id))
    end)
  end

  defp topological_sort_steps(steps, connections) do
    step_ids = Enum.map(steps, & &1.id)
    step_map = Map.new(steps, &{&1.id, &1})

    in_degrees = Map.new(step_ids, &{&1, 0})

    in_degrees =
      Enum.reduce(connections, in_degrees, fn conn, acc ->
        Map.update(acc, conn.target_step_id, 0, &(&1 + 1))
      end)

    adjacency =
      Enum.reduce(connections, %{}, fn conn, acc ->
        Map.update(acc, conn.source_step_id, [conn.target_step_id], &[conn.target_step_id | &1])
      end)

    roots = Enum.filter(step_ids, &(Map.get(in_degrees, &1) == 0))
    sorted_ids = do_kahn_sort(roots, in_degrees, adjacency, [])
    Enum.map(sorted_ids, &Map.get(step_map, &1))
  end

  defp do_kahn_sort([], _in_degrees, _adjacency, sorted), do: Enum.reverse(sorted)

  defp do_kahn_sort([id | rest], in_degrees, adjacency, sorted) do
    children = Map.get(adjacency, id, [])

    {new_rest, new_in_degrees} =
      Enum.reduce(children, {rest, in_degrees}, fn child, {r, degs} ->
        new_deg = Map.get(degs, child) - 1
        degs = Map.put(degs, child, new_deg)
        if new_deg == 0, do: {r ++ [child], degs}, else: {r, degs}
      end)

    do_kahn_sort(new_rest, new_in_degrees, adjacency, [id | sorted])
  end

  defp put_step_metadata(workflow, steps) when is_list(steps) do
    step_metadata =
      Enum.reduce(steps, %{}, fn step, acc ->
        Map.put(acc, step.id, %{
          type_id: step.type_id,
          step_id: step.id,
          name: step.name
        })
      end)

    Map.put(workflow, :__step_metadata__, step_metadata)
  end

  defp put_step_metadata(workflow, _steps), do: workflow

  # ===========================================================================
  # Private: Component Creation
  # ===========================================================================

  defp create_splitter(step, component_name, opts) do
    work_fn = fn input ->
      result = StepRunner.execute_with_context(step, input, opts)

      if is_list(result) do
        items_total = length(result)
        Process.put(:imgd_fan_out_items_total, items_total)
        Process.put(:imgd_step_item_counters, %{})
      end

      result
    end

    %FanOut{
      name: component_name,
      work: work_fn,
      hash: :erlang.phash2({:fan_out, step.id}, 4_294_967_296)
    }
  end

  # Fan-out aggregator: uses Runic.reduce for proper FanIn/FanOut semantics
  defp create_fanout_aggregator(step, component_name) do
    operation = Map.get(step.config, "operation", "collect")
    name = component_name
    step_id = step.id

    reduce =
      case operation do
        "sum" ->
          Runic.reduce(
            0,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              Enum.reduce(items, acc, fn i, a -> a + (__MODULE__.to_number(i) || 0) end)
            end,
            name: name
          )

        "count" ->
          Runic.reduce(
            0,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc + length(items)
            end,
            name: name
          )

        "concat" ->
          Runic.reduce(
            "",
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc <> Enum.map_join(items, "", &to_string/1)
            end,
            name: name
          )

        "first" ->
          Runic.reduce(
            nil,
            fn
              item, nil ->
                items = __MODULE__.normalize_item(item)
                List.first(items)

              _item, acc ->
                acc
            end,
            name: name
          )

        "last" ->
          Runic.reduce(
            nil,
            fn item, _acc ->
              items = __MODULE__.normalize_item(item)
              List.last(items) || List.first(items)
            end,
            name: name
          )

        "min" ->
          Runic.reduce(
            nil,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              item_min = Enum.min(items, fn -> nil end)

              case {acc, item_min} do
                {nil, val} -> val
                {val, nil} -> val
                {a, b} -> min(a, b)
              end
            end,
            name: name
          )

        "max" ->
          Runic.reduce(
            nil,
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              item_max = Enum.max(items, fn -> nil end)

              case {acc, item_max} do
                {nil, val} -> val
                {val, nil} -> val
                {a, b} -> max(a, b)
              end
            end,
            name: name
          )

        # Default "collect" - accumulate all items into a flat list
        _ ->
          Runic.reduce(
            [],
            fn item, acc ->
              items = __MODULE__.normalize_item(item)
              acc ++ items
            end,
            name: name
          )
      end

    # Make hash unique by incorporating step_id to avoid graph vertex collisions
    unique_hash = :erlang.phash2({reduce.hash, step_id}, 4_294_967_296)
    unique_fan_in = %{reduce.fan_in | hash: unique_hash}
    %{reduce | hash: unique_hash, fan_in: unique_fan_in}
  end

  # Join aggregator: handles pre-combined list input from Join nodes (no fan-out upstream)
  defp create_join_aggregator(step, component_name) do
    operation = Map.get(step.config, "operation", "collect")
    step_id = step.id

    runic_step =
      Runic.step(
        fn input ->
          items = __MODULE__.normalize_aggregator_input(input)
          __MODULE__.apply_aggregation(operation, items)
        end,
        name: component_name
      )

    unique_hash = :erlang.phash2({runic_step.hash, step_id}, 4_294_967_296)
    %{runic_step | hash: unique_hash}
  end

  defp create_condition(step, component_name, opts) do
    condition_expr = Map.get(step.config, "condition", "true")

    Runic.rule(
      name: component_name,
      if: fn input -> evaluate_condition(condition_expr, input, opts) end,
      do: fn input -> input end
    )
  end

  defp create_switch(step, _component_name, opts) do
    StepRunner.create(step, opts)
  end

  defp evaluate_condition(expr, input, opts) when is_binary(expr) do
    vars = %{
      "json" => input,
      "variables" => Keyword.get(opts, :variables, %{})
    }

    case Imgd.Runtime.Expression.evaluate_with_vars(expr, vars) do
      {:ok, "true"} -> true
      {:ok, "false"} -> false
      {:ok, result} when is_binary(result) -> result != "" and result != "0"
      {:ok, result} -> !!result
      {:error, _} -> false
    end
  end

  defp evaluate_condition(_, _, _), do: true
end

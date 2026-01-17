defmodule Imgd.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Imgd workflow definitions (Steps/Connections) with the Runic execution engine.

  This adapter handles the conversion of a design-time workflow into a
  run-time Runic `%Workflow{}` struct, which acts as the single source
  of truth for execution state.

  ## Design Philosophy

  Runic is NOT just a wrapper - it's the execution substrate. This adapter:
  - Converts Imgd steps to appropriate Runic components (Steps, Rules, Map, Reduce)
  - Uses Runic's native graph-building API (`Workflow.add/3`)
  - Respects Runic's dataflow semantics (joins, fan-out)

  ## Step Type Mapping

  | Imgd Step Kind    | Runic Component        |
  |-------------------|------------------------|
  | :action, :trigger | `Runic.step`           |
  | :transform        | `Runic.step`           |
  | :control_flow     | `Runic.rule` or custom |
  | splitter          | `Runic.map`            |
  | aggregator        | `Runic.reduce`         |
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

  @doc """
  Converts an Imgd workflow source (draft or snapshot) into a Runic Workflow.

  ## Options

  - `:execution_id` - The execution ID for context
  - `:variables` - Workflow-level variables for expressions
  - `:variables` - Workflow-level variables for experiments
  - `:metadata` - Execution metadata
  - `:step_outputs` - Precomputed step outputs (e.g., pinned outputs)
  - `:default_compute` - Default compute target for all steps

  ## Returns

  A `%Runic.Workflow{}` struct ready for execution via `Workflow.react_until_satisfied/2`.
  """
  @spec to_runic_workflow(source(), build_opts()) :: Workflow.t()
  def to_runic_workflow(source, opts \\ []) do
    # Build options for StepRunner creation
    step_outputs =
      Keyword.get(opts, :step_outputs, Keyword.get(opts, :pinned_outputs, %{}))

    # Build graph to compute upstream dependencies
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

    # Initialize Runic workflow
    wrk = Workflow.new(name: "execution_#{extract_source_id(source)}")

    # Build lookup for parent relationships
    parent_lookup = build_parent_lookup(source.connections)

    # Sort steps topologically to ensure parents are added before children
    sorted_steps = topological_sort_steps(source.steps, source.connections)

    # Add each step as a Runic component
    wrk =
      Enum.reduce(sorted_steps, wrk, fn step, acc ->
        add_step_to_workflow(step, acc, parent_lookup, step_opts)
      end)

    put_step_metadata(wrk, source.steps)
  end

  @doc """
  Creates a Runic component from an Imgd step.

  Dispatches to the appropriate Runic primitive based on step type.
  """
  @spec create_component(Imgd.Workflows.Embeds.Step.t(), String.t(), build_opts()) :: term()
  def create_component(step, component_name, opts \\ []) do
    case step.type_id do
      "splitter" ->
        create_splitter(step, component_name, opts)

      "aggregator" ->
        create_aggregator(step, component_name)

      "condition" ->
        create_condition(step, component_name, opts)

      "switch" ->
        create_switch(step, component_name, opts)

      _ ->
        # Default: create a Runic step via StepRunner
        StepRunner.create(step, opts)
    end
  end

  # ===========================================================================
  # Private: Workflow Building
  # ===========================================================================

  defp add_step_to_workflow(step, workflow, parent_lookup, step_opts) do
    component_name = step.id
    component = create_component(step, component_name, step_opts)

    parent_ids =
      parent_lookup
      |> Map.get(step.id, [])
      |> Enum.uniq()

    workflow = connect_component(workflow, component, parent_ids)

    # For Reduce (aggregator) components, connect to upstream FanOut (splitter) if exists
    maybe_connect_fan_in(workflow, component)
  end

  defp connect_component(workflow, component, []) do
    # Root step - add to workflow root
    Workflow.add(workflow, component)
  end

  defp connect_component(workflow, component, [parent_id]) do
    Workflow.add(workflow, component, to: parent_id)
  end

  defp connect_component(workflow, component, parent_ids) do
    {workflow, join} = ensure_join(workflow, parent_ids)
    Workflow.add(workflow, component, to: join)
  end

  # Connect a Reduce (aggregator) to its upstream FanOut (splitter) via :fan_in edge
  defp maybe_connect_fan_in(workflow, %Runic.Workflow.Reduce{fan_in: fan_in}) do
    # Find any upstream FanOut in the graph
    case find_upstream_fan_out(workflow, fan_in) do
      nil ->
        workflow

      fan_out ->
        # Draw the :fan_in edge so FanIn knows which FanOut to collect from
        workflow
        |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
        |> track_mapped_path(fan_out, fan_in)
    end
  end

  defp maybe_connect_fan_in(workflow, _component), do: workflow

  # Find any FanOut upstream of the given FanIn by traversing the graph backwards
  defp find_upstream_fan_out(workflow, fan_in) do
    # Get the fan_in's predecessors and traverse backwards to find FanOut
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
          # Get all predecessors (nodes that flow into current)
          predecessors =
            graph
            |> Graph.in_edges(current)
            |> Enum.filter(&(&1.label == :flow))
            |> Enum.map(& &1.v1)

          do_find_upstream_fan_out(graph, predecessors ++ rest, visited)
      end
    end
  end

  # Track the path from FanOut to FanIn in the workflow's mapped paths
  defp track_mapped_path(workflow, fan_out, fan_in) do
    path =
      workflow.graph
      |> Graph.get_shortest_path(fan_out, fan_in)

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

  defp ensure_join(%Workflow{} = workflow, parent_ids) when is_list(parent_ids) do
    parent_steps = Enum.map(parent_ids, &Workflow.get_component!(workflow, &1))
    parent_hashes = Enum.map(parent_steps, &Component.hash/1)
    join = Workflow.Join.new(parent_hashes)

    case Map.get(workflow.graph.vertices, join.hash) do
      %Workflow.Join{} = existing_join ->
        {workflow, existing_join}

      nil ->
        {Workflow.add_step(workflow, parent_steps, join), join}
    end
  end

  defp extract_source_id(source) do
    # todo: why?
    Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"
  end

  defp build_parent_lookup(connections) do
    # Group connections by target_step_id to find parents
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

    # 1. Initialize in-degrees
    in_degrees = Map.new(step_ids, &{&1, 0})

    in_degrees =
      Enum.reduce(connections, in_degrees, fn conn, acc ->
        Map.update(acc, conn.target_step_id, 0, &(&1 + 1))
      end)

    # 2. Build adjacency list (parent -> [children])
    adjacency =
      Enum.reduce(connections, %{}, fn conn, acc ->
        Map.update(acc, conn.source_step_id, [conn.target_step_id], &[conn.target_step_id | &1])
      end)

    # 3. Find initial roots (in-degree 0)
    # We preserve the original relative order of steps when picking roots
    roots = Enum.filter(step_ids, &(Map.get(in_degrees, &1) == 0))

    # 4. Kahn's algorithm
    sorted_ids = do_kahn_sort(roots, in_degrees, adjacency, [])

    # Map back to step structs
    Enum.map(sorted_ids, &Map.get(step_map, &1))
  end

  defp do_kahn_sort([], _in_degrees, _adjacency, sorted), do: Enum.reverse(sorted)

  defp do_kahn_sort([id | rest], in_degrees, adjacency, sorted) do
    children = Map.get(adjacency, id, [])

    {new_rest, new_in_degrees} =
      Enum.reduce(children, {rest, in_degrees}, fn child, {r, degs} ->
        new_deg = Map.get(degs, child) - 1
        degs = Map.put(degs, child, new_deg)

        if new_deg == 0 do
          # Add to queue if all dependencies met
          {r ++ [child], degs}
        else
          {r, degs}
        end
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
    # Create a FanOut step that runs the Splitter executor logic
    # This replaces the previous two-step (extract + map) approach with a single
    # atomic fan-out component that supports its own work function.
    work_fn = fn input ->
      result = StepRunner.execute_with_context(step, input, opts)

      # Store fan-out context for downstream step tracking
      # This enables per-item observability in downstream steps
      if is_list(result) do
        items_total = length(result)
        Process.put(:imgd_fan_out_items_total, items_total)
        # Reset the per-step item counters for this new fan-out batch
        Process.put(:imgd_step_item_counters, %{})
      end

      result
    end

    %FanOut{
      name: component_name,
      work: work_fn,
      # Ensure unique hash for graph vertex collisions
      hash: :erlang.phash2({:fan_out, step.id}, 4_294_967_296)
    }
  end

  defp create_aggregator(step, component_name) do
    # Aggregator creates a Runic.reduce
    # Note: Runic.reduce is a macro that requires inline anonymous functions
    operation = Map.get(step.config, "operation", "collect")
    name = component_name

    case operation do
      "sum" ->
        Runic.reduce(0, fn item, acc -> acc + (item || 0) end, name: name)

      "count" ->
        Runic.reduce(0, fn _item, acc -> acc + 1 end, name: name)

      "concat" ->
        Runic.reduce("", fn item, acc -> acc <> to_string(item) end, name: name)

      "first" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            _item, acc -> acc
          end,
          name: name
        )

      "last" ->
        Runic.reduce(nil, fn item, _acc -> item end, name: name)

      "min" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            item, acc -> min(item, acc)
          end,
          name: name
        )

      "max" ->
        Runic.reduce(
          nil,
          fn
            item, nil -> item
            item, acc -> max(item, acc)
          end,
          name: name
        )

      _ ->
        Runic.reduce([], fn item, acc -> [item | acc] end, name: name)
    end
  end

  defp create_condition(step, component_name, opts) do
    # Condition creates a Runic.rule
    condition_expr = Map.get(step.config, "condition", "true")

    Runic.rule(
      name: component_name,
      if: fn input -> evaluate_condition(condition_expr, input, opts) end,
      do: fn input -> input end
    )
  end

  defp create_switch(step, _component_name, opts) do
    # Switch creates multiple rules, but for now we create a step that
    # outputs a tagged tuple for routing
    StepRunner.create(step, opts)
  end

  # Condition evaluation helper
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

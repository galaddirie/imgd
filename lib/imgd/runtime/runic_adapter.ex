defmodule Imgd.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Imgd workflow definitions (Nodes/Connections) with the Runic execution engine.

  This adapter handles the conversion of a design-time workflow into a
  run-time Runic `%Workflow{}` struct, which acts as the single source
  of truth for execution state.

  ## Design Philosophy

  Runic is NOT just a wrapper - it's the execution substrate. This adapter:
  - Converts Imgd nodes to appropriate Runic components (Steps, Rules, Map, Reduce)
  - Uses Runic's native graph-building API (`Workflow.add/3`)
  - Respects Runic's dataflow semantics (joins, fan-out)

  ## Node Type Mapping

  | Imgd Node Kind    | Runic Component        |
  |-------------------|------------------------|
  | :action, :trigger | `Runic.step`           |
  | :transform        | `Runic.step`           |
  | :control_flow     | `Runic.rule` or custom |
  | splitter          | `Runic.map`            |
  | aggregator        | `Runic.reduce`         |
  """

  require Runic
  alias Runic.Workflow
  alias Imgd.Runtime.Nodes.NodeStep

  @type source :: Imgd.Workflows.WorkflowDraft.t() | map()
  @type build_opts :: [
          execution_id: String.t(),
          variables: map(),
          metadata: map()
        ]

  @doc """
  Converts an Imgd workflow source (draft or snapshot) into a Runic Workflow.

  ## Options

  - `:execution_id` - The execution ID for context
  - `:variables` - Workflow-level variables for expressions
  - `:metadata` - Execution metadata

  ## Returns

  A `%Runic.Workflow{}` struct ready for execution via `Workflow.react_until_satisfied/2`.
  """
  @spec to_runic_workflow(source(), build_opts()) :: Workflow.t()
  def to_runic_workflow(source, opts \\ []) do
    nodes = source.nodes
    connections = source.connections
    source_id = extract_source_id(source)

    # Build options for NodeStep creation
    step_opts = [
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: source_id,
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    ]

    # Initialize Runic workflow
    wrk = Workflow.new(name: "execution_#{source_id}")

    # Build lookup for parent relationships
    parent_lookup = build_parent_lookup(connections)

    # Sort nodes topologically to ensure parents are added before children
    sorted_nodes = topological_sort_nodes(nodes, connections)

    # Add each node as a Runic component
    Enum.reduce(sorted_nodes, wrk, fn node, acc ->
      add_node_to_workflow(node, acc, parent_lookup, step_opts)
    end)
  end

  @doc """
  Creates a Runic component from an Imgd node.

  Dispatches to the appropriate Runic primitive based on node type.
  """
  @spec create_component(Imgd.Workflows.Embeds.Node.t(), build_opts()) :: term()
  def create_component(node, opts \\ []) do
    case node.type_id do
      "splitter" ->
        create_splitter(node, opts)

      "aggregator" ->
        create_aggregator(node, opts)

      "condition" ->
        create_condition(node, opts)

      "switch" ->
        create_switch(node, opts)

      _ ->
        # Default: create a Runic step via NodeStep
        NodeStep.create(node, opts)
    end
  end

  # ===========================================================================
  # Private: Workflow Building
  # ===========================================================================

  defp add_node_to_workflow(node, workflow, parent_lookup, step_opts) do
    component = create_component(node, step_opts)
    parent_ids = Map.get(parent_lookup, node.id, [])

    if parent_ids == [] do
      # Root node - add to workflow root
      Workflow.add(workflow, component)
    else
      # Connect to first parent
      # Note: For proper join patterns (multiple parents), Runic requires
      # using the declarative workflow syntax with tuples. For now, we
      # connect to the first parent only.
      first_parent = List.first(parent_ids)
      Workflow.add(workflow, component, to: first_parent)
    end
  end

  defp extract_source_id(source) do
    Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"
  end

  defp build_parent_lookup(connections) do
    # Group connections by target_node_id to find parents
    Enum.group_by(connections, & &1.target_node_id, & &1.source_node_id)
  end

  defp topological_sort_nodes(nodes, connections) do
    # Build a simple dependency graph and sort
    node_map = Map.new(nodes, &{&1.id, &1})
    node_ids = Enum.map(nodes, & &1.id)

    # Build adjacency list (parent -> children)
    adjacency =
      Enum.reduce(connections, %{}, fn conn, acc ->
        Map.update(acc, conn.source_node_id, [conn.target_node_id], &[conn.target_node_id | &1])
      end)

    # Find roots (nodes with no incoming edges)
    children_set = connections |> Enum.map(& &1.target_node_id) |> MapSet.new()
    roots = Enum.filter(node_ids, &(not MapSet.member?(children_set, &1)))

    # Simple BFS topological sort
    sorted_ids = topo_sort_bfs(roots, adjacency, MapSet.new(), [])

    # Map back to nodes, preserving order
    Enum.map(sorted_ids, &Map.get(node_map, &1))
  end

  defp topo_sort_bfs([], _adjacency, _visited, result), do: Enum.reverse(result)

  defp topo_sort_bfs([id | rest], adjacency, visited, result) do
    if MapSet.member?(visited, id) do
      topo_sort_bfs(rest, adjacency, visited, result)
    else
      visited = MapSet.put(visited, id)
      result = [id | result]
      children = Map.get(adjacency, id, [])
      topo_sort_bfs(rest ++ children, adjacency, visited, result)
    end
  end

  # ===========================================================================
  # Private: Component Creation
  # ===========================================================================

  defp create_splitter(node, _opts) do
    # Splitter creates a Runic.map that iterates over the input collection
    # The inner step passes each item through unchanged (for downstream processing)
    Runic.map(
      fn item -> item end,
      name: node.id
    )
  end

  defp create_aggregator(node, _opts) do
    # Aggregator creates a Runic.reduce
    # Note: Runic.reduce is a macro that requires inline anonymous functions
    operation = Map.get(node.config, "operation", "collect")
    name = node.id

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

      # "collect" and default
      _ ->
        Runic.reduce([], fn item, acc -> acc ++ [item] end, name: name)
    end
  end

  defp create_condition(node, opts) do
    # Condition creates a Runic.rule
    condition_expr = Map.get(node.config, "condition", "true")

    Runic.rule(
      name: node.id,
      if: fn input -> evaluate_condition(condition_expr, input, opts) end,
      do: fn input -> input end
    )
  end

  defp create_switch(node, opts) do
    # Switch creates multiple rules, but for now we create a step that
    # outputs a tagged tuple for routing
    NodeStep.create(node, opts)
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

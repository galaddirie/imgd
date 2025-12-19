defmodule Imgd.Workflows.DagLayout do
  @moduledoc """
  Computes visual layout positions for workflow DAG nodes.

  Uses a layered (Sugiyama-style) approach:
  1. Assign nodes to layers via topological sort
  2. Order nodes within layers to minimize edge crossings
  3. Assign x,y coordinates based on layer and position

  ## Usage

      nodes = [%{id: "a", ...}, %{id: "b", ...}]
      connections = [%{source_node_id: "a", target_node_id: "b"}]

      layout = DagLayout.compute(nodes, connections)
      # => %{
      #   "a" => %{x: 200, y: 100, layer: 0, index: 0},
      #   "b" => %{x: 200, y: 250, layer: 1, index: 0}
      # }
  """

  # TODO: delete this once we move ui to react
  alias Imgd.Graph

  @type node_id :: String.t()
  @type position :: %{
          x: number(),
          y: number(),
          layer: non_neg_integer(),
          index: non_neg_integer()
        }
  @type layout :: %{node_id() => position()}

  @default_opts [
    layer_height: 150,
    node_width: 200,
    node_height: 80,
    horizontal_gap: 60,
    vertical_gap: 40,
    padding_x: 100,
    padding_y: 80
  ]

  @doc """
  Computes layout positions for all nodes in the workflow.

  ## Options

  - `:layer_height` - Vertical distance between layers (default: 150)
  - `:node_width` - Width of each node (default: 200)
  - `:node_height` - Height of each node (default: 80)
  - `:horizontal_gap` - Horizontal gap between nodes in same layer (default: 60)
  - `:padding_x` - Left padding (default: 100)
  - `:padding_y` - Top padding (default: 80)
  """
  @spec compute(list(), list(), keyword()) :: layout()
  def compute(nodes, connections, opts \\ [])

  def compute([], _connections, _opts), do: %{}

  def compute(nodes, connections, opts) do
    opts = Keyword.merge(@default_opts, opts)

    # Build graph using the unified Graph module
    graph = Graph.from_workflow!(nodes, connections, validate: false)

    # Assign layers via longest-path layering
    layers = assign_layers(graph)

    # Group nodes by layer
    nodes_by_layer = group_by_layer(layers)

    # Order nodes within layers (simple: by number of connections)
    ordered_layers = order_within_layers(nodes_by_layer, graph)

    # Compute final positions
    compute_positions(ordered_layers, opts)
  end

  @doc """
  Returns layout metadata including dimensions and layer info.
  """
  @spec compute_with_metadata(list(), list(), keyword()) ::
          {layout(), %{width: number(), height: number(), layer_count: non_neg_integer()}}
  def compute_with_metadata(nodes, connections, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    layout = compute(nodes, connections, opts)

    if map_size(layout) == 0 do
      {layout, %{width: 400, height: 300, layer_count: 0}}
    else
      max_layer =
        layout
        |> Map.values()
        |> Enum.map(& &1.layer)
        |> Enum.max(fn -> 0 end)

      max_x =
        layout
        |> Map.values()
        |> Enum.map(&(&1.x + opts[:node_width]))
        |> Enum.max(fn -> 400 end)

      width = max_x + opts[:padding_x]
      height = (max_layer + 1) * opts[:layer_height] + opts[:padding_y] * 2

      {layout, %{width: width, height: height, layer_count: max_layer + 1}}
    end
  end

  @doc """
  Computes edge paths for SVG rendering.
  Returns a list of edge definitions with path data.
  """
  @spec compute_edges(list(), layout(), keyword()) :: list()
  def compute_edges(connections, layout, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    node_width = opts[:node_width]
    node_height = opts[:node_height]

    Enum.map(connections, fn conn ->
      source_pos = Map.get(layout, conn.source_node_id)
      target_pos = Map.get(layout, conn.target_node_id)

      if source_pos && target_pos do
        # Start from bottom center of source
        x1 = source_pos.x + node_width / 2
        y1 = source_pos.y + node_height

        # End at top center of target
        x2 = target_pos.x + node_width / 2
        y2 = target_pos.y

        # Create smooth bezier curve
        mid_y = (y1 + y2) / 2
        path = "M #{x1} #{y1} C #{x1} #{mid_y}, #{x2} #{mid_y}, #{x2} #{y2}"

        %{
          id: conn.id,
          source_node_id: conn.source_node_id,
          target_node_id: conn.target_node_id,
          path: path,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ============================================================================
  # Private: Layer Assignment (Longest Path)
  # ============================================================================

  defp assign_layers(%Graph{} = graph) do
    # Find root nodes (no incoming edges)
    roots = Graph.roots(graph)

    # If no roots found (cycle or empty), use first vertex
    roots = if roots == [], do: Enum.take(Graph.vertex_ids(graph), 1), else: roots

    # BFS to assign layers
    initial_layers = Map.new(roots, &{&1, 0})
    queue = :queue.from_list(roots)

    assign_layers_bfs(queue, graph, initial_layers)
  end

  defp assign_layers_bfs(queue, graph, layers) do
    case :queue.out(queue) do
      {:empty, _} ->
        layers

      {{:value, node_id}, rest_queue} ->
        current_layer = Map.get(layers, node_id, 0)
        children = Graph.children(graph, node_id)

        {new_layers, new_queue} =
          Enum.reduce(children, {layers, rest_queue}, fn child_id, {l_acc, q_acc} ->
            child_layer = current_layer + 1
            existing_layer = Map.get(l_acc, child_id)

            if is_nil(existing_layer) or child_layer > existing_layer do
              {Map.put(l_acc, child_id, child_layer), :queue.in(child_id, q_acc)}
            else
              {l_acc, q_acc}
            end
          end)

        assign_layers_bfs(new_queue, graph, new_layers)
    end
  end

  # ============================================================================
  # Private: Layer Grouping and Ordering
  # ============================================================================

  defp group_by_layer(layers) do
    layers
    |> Enum.group_by(fn {_id, layer} -> layer end, fn {id, _layer} -> id end)
    |> Enum.sort_by(fn {layer, _nodes} -> layer end)
    |> Enum.map(fn {layer, nodes} -> {layer, nodes} end)
  end

  defp order_within_layers(nodes_by_layer, graph) do
    # Simple ordering: sort by number of connections (more connected = center)
    Enum.map(nodes_by_layer, fn {layer, node_ids} ->
      sorted =
        Enum.sort_by(node_ids, fn id ->
          out_degree = Graph.out_degree(graph, id)
          in_degree = Graph.in_degree(graph, id)
          -(out_degree + in_degree)
        end)

      {layer, sorted}
    end)
  end

  # ============================================================================
  # Private: Position Computation
  # ============================================================================

  defp compute_positions(ordered_layers, opts) do
    layer_height = opts[:layer_height]
    node_width = opts[:node_width]
    horizontal_gap = opts[:horizontal_gap]
    padding_x = opts[:padding_x]
    padding_y = opts[:padding_y]

    # Find max width needed (for centering)
    max_layer_width =
      ordered_layers
      |> Enum.map(fn {_layer, nodes} ->
        length(nodes) * node_width + (length(nodes) - 1) * horizontal_gap
      end)
      |> Enum.max(fn -> node_width end)

    Enum.reduce(ordered_layers, %{}, fn {layer, node_ids}, acc ->
      layer_width = length(node_ids) * node_width + (length(node_ids) - 1) * horizontal_gap
      start_x = padding_x + (max_layer_width - layer_width) / 2

      node_ids
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {node_id, index}, inner_acc ->
        x = start_x + index * (node_width + horizontal_gap)
        y = padding_y + layer * layer_height

        Map.put(inner_acc, node_id, %{
          x: x,
          y: y,
          layer: layer,
          index: index
        })
      end)
    end)
  end
end

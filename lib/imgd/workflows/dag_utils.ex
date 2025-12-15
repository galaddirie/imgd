defmodule Imgd.Workflows.DagUtils do
  @moduledoc """
  DAG traversal utilities for partial execution.

  Provides functions to compute node dependencies, enabling features like:
  - "Execute to here" (run target + all upstream dependencies)
  - "Execute from here" (run from pinned node through all downstream)
  - Determining which nodes can be skipped due to pinned outputs

  ## Example

      # Get all nodes that must run before "transform_1"
      upstream = DagUtils.upstream_closure("transform_1", nodes, connections)

      # Compute minimal execution set, excluding pinned nodes
      to_run = DagUtils.compute_execution_set(["output"], nodes, connections, ["http_request"])
  """

  alias Imgd.Workflows.Embeds.{Node, Connection}

  @type node_id :: String.t()
  @type node_list :: [Node.t() | %{id: String.t()}]
  @type connection_list :: [
          Connection.t() | %{source_node_id: String.t(), target_node_id: String.t()}
        ]

  @doc """
  Returns all node IDs that must execute before `node_id` (transitive upstream).

  Does not include `node_id` itself in the result.

  ## Example

      iex> nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      iex> connections = [
      ...>   %{source_node_id: "a", target_node_id: "b"},
      ...>   %{source_node_id: "b", target_node_id: "c"}
      ...> ]
      iex> DagUtils.upstream_closure("c", nodes, connections)
      ["a", "b"]  # order may vary
  """
  @spec upstream_closure(node_id(), node_list(), connection_list()) :: [node_id()]
  def upstream_closure(node_id, _nodes, connections) do
    reverse_adj = build_reverse_adjacency(connections)

    traverse_closure(node_id, reverse_adj, MapSet.new())
    |> MapSet.delete(node_id)
    |> MapSet.to_list()
  end

  @doc """
  Returns all node IDs that execute after `node_id` (transitive downstream).

  Does not include `node_id` itself in the result.

  ## Example

      iex> nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      iex> connections = [
      ...>   %{source_node_id: "a", target_node_id: "b"},
      ...>   %{source_node_id: "b", target_node_id: "c"}
      ...> ]
      iex> DagUtils.downstream_closure("a", nodes, connections)
      ["b", "c"]  # order may vary
  """
  @spec downstream_closure(node_id(), node_list(), connection_list()) :: [node_id()]
  def downstream_closure(node_id, _nodes, connections) do
    forward_adj = build_forward_adjacency(connections)

    traverse_closure(node_id, forward_adj, MapSet.new())
    |> MapSet.delete(node_id)
    |> MapSet.to_list()
  end

  @doc """
  Given target nodes and pinned node IDs, compute the minimal execution set.

  This determines which nodes actually need to run when executing to a target,
  taking into account that pinned nodes can be skipped (their output is pre-computed).

  ## Parameters

  - `target_node_ids` - The nodes we want to execute (endpoints)
  - `nodes` - All nodes in the workflow
  - `connections` - All connections in the workflow
  - `pinned_node_ids` - Node IDs that have pinned outputs (will be skipped)

  ## Returns

  List of node IDs that need to execute (excludes pinned nodes).

  ## Example

      # Workflow: a -> b -> c -> d
      # We want to execute "d", but "b" is pinned
      # Result: ["c", "d"] (a and b are skipped because b is pinned)

      iex> compute_execution_set(["d"], nodes, connections, ["b"])
      ["c", "d"]
  """
  @spec compute_execution_set([node_id()], node_list(), connection_list(), [node_id()]) ::
          [node_id()]
  def compute_execution_set(target_node_ids, nodes, connections, pinned_node_ids) do
    pinned_set = MapSet.new(pinned_node_ids)

    # Get all nodes needed for targets (targets + their upstream)
    all_needed =
      target_node_ids
      |> Enum.flat_map(fn id -> [id | upstream_closure(id, nodes, connections)] end)
      |> MapSet.new()

    # Remove pinned nodes - they don't need to execute
    nodes_to_run = MapSet.difference(all_needed, pinned_set)

    # But we also need to remove nodes that are ONLY needed to feed pinned nodes
    # (i.e., if all downstream paths go through a pinned node)
    prune_unnecessary_upstream(nodes_to_run, pinned_set, nodes, connections)
  end

  @doc """
  Topologically sort a subset of nodes.

  Filters the workflow to only include the specified nodes and their
  interconnections, then returns them in execution order.

  ## Parameters

  - `node_ids` - The subset of node IDs to sort
  - `nodes` - All nodes in the workflow
  - `connections` - All connections in the workflow

  ## Returns

  `{:ok, sorted_nodes}` or `{:error, reason}`
  """
  @spec sort_subset([node_id()], node_list(), connection_list()) ::
          {:ok, [Node.t()]} | {:error, term()}
  def sort_subset(node_ids, nodes, connections) do
    node_set = MapSet.new(node_ids)

    # Filter to only relevant nodes and connections
    filtered_nodes = Enum.filter(nodes, &MapSet.member?(node_set, &1.id))

    filtered_connections =
      Enum.filter(connections, fn c ->
        MapSet.member?(node_set, c.source_node_id) and
          MapSet.member?(node_set, c.target_node_id)
      end)

    # Use the existing WorkflowBuilder logic
    with {:ok, graph} <-
           Imgd.Runtime.WorkflowBuilder.build_dag(filtered_nodes, filtered_connections),
         {:ok, sorted} <- Imgd.Runtime.WorkflowBuilder.topological_sort(graph, filtered_nodes) do
      {:ok, sorted}
    end
  end

  @doc """
  Returns the direct parents (immediate upstream) of a node.
  """
  @spec direct_parents(node_id(), connection_list()) :: [node_id()]
  def direct_parents(node_id, connections) do
    connections
    |> Enum.filter(&(&1.target_node_id == node_id))
    |> Enum.map(& &1.source_node_id)
  end

  @doc """
  Returns the direct children (immediate downstream) of a node.
  """
  @spec direct_children(node_id(), connection_list()) :: [node_id()]
  def direct_children(node_id, connections) do
    connections
    |> Enum.filter(&(&1.source_node_id == node_id))
    |> Enum.map(& &1.target_node_id)
  end

  @doc """
  Checks if executing `target_node_id` requires `dependency_node_id` to run first.

  Returns true if dependency is in the upstream closure of target.
  """
  @spec depends_on?(node_id(), node_id(), node_list(), connection_list()) :: boolean()
  def depends_on?(target_node_id, dependency_node_id, nodes, connections) do
    upstream = upstream_closure(target_node_id, nodes, connections)
    dependency_node_id in upstream
  end

  @doc """
  Returns all root nodes (nodes with no incoming connections).
  """
  @spec root_nodes(node_list(), connection_list()) :: [node_id()]
  def root_nodes(nodes, connections) do
    targets = MapSet.new(connections, & &1.target_node_id)

    nodes
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(targets, &1))
  end

  @doc """
  Returns all leaf nodes (nodes with no outgoing connections).
  """
  @spec leaf_nodes(node_list(), connection_list()) :: [node_id()]
  def leaf_nodes(nodes, connections) do
    sources = MapSet.new(connections, & &1.source_node_id)

    nodes
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(sources, &1))
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_reverse_adjacency(connections) do
    Enum.reduce(connections, %{}, fn c, acc ->
      Map.update(acc, c.target_node_id, [c.source_node_id], &[c.source_node_id | &1])
    end)
  end

  defp build_forward_adjacency(connections) do
    Enum.reduce(connections, %{}, fn c, acc ->
      Map.update(acc, c.source_node_id, [c.target_node_id], &[c.target_node_id | &1])
    end)
  end

  defp traverse_closure(node_id, adjacency, visited) do
    if MapSet.member?(visited, node_id) do
      visited
    else
      visited = MapSet.put(visited, node_id)
      neighbors = Map.get(adjacency, node_id, [])
      Enum.reduce(neighbors, visited, &traverse_closure(&1, adjacency, &2))
    end
  end

  # Remove upstream nodes that are only needed to feed pinned nodes
  # (optimization: if a node's only purpose is to feed a pinned node, skip it)
  defp prune_unnecessary_upstream(nodes_to_run, pinned_set, _nodes, connections) do
    forward_adj = build_forward_adjacency(connections)

    # A node is unnecessary if ALL its downstream paths eventually hit only pinned nodes
    # before reaching any node in nodes_to_run
    Enum.filter(nodes_to_run, fn node_id ->
      # Check if this node has at least one downstream path to a non-pinned node
      # that we actually want to execute
      has_path_to_execution?(node_id, nodes_to_run, pinned_set, forward_adj, MapSet.new())
    end)
    |> MapSet.new()
    |> MapSet.to_list()
  end

  defp has_path_to_execution?(node_id, nodes_to_run, pinned_set, forward_adj, visited) do
    cond do
      # If we've already visited this node, avoid cycles
      MapSet.member?(visited, node_id) ->
        false

      # If this node is pinned, this path is blocked
      MapSet.member?(pinned_set, node_id) ->
        false

      # If this node is in nodes_to_run and not the starting point, we found a valid path
      # (The node itself counts as reaching execution)
      true ->
        children = Map.get(forward_adj, node_id, [])

        # If no children, this is a leaf - it's needed if it's in nodes_to_run
        if children == [] do
          MapSet.member?(nodes_to_run, node_id)
        else
          # Check if any child leads to execution
          visited = MapSet.put(visited, node_id)

          Enum.any?(children, fn child ->
            MapSet.member?(nodes_to_run, child) or
              has_path_to_execution?(child, nodes_to_run, pinned_set, forward_adj, visited)
          end)
        end
    end
  end
end

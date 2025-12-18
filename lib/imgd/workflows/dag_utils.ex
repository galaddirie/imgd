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

  alias Imgd.Graph
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
  def upstream_closure(node_id, nodes, connections) do
    graph = build_graph!(nodes, connections)
    Graph.upstream(graph, node_id)
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
  def downstream_closure(node_id, nodes, connections) do
    graph = build_graph!(nodes, connections)
    Graph.downstream(graph, node_id)
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
    graph = build_graph!(nodes, connections)

    subgraph =
      Graph.execution_subgraph(graph, target_node_ids,
        exclude: pinned_node_ids,
        include_targets: true
      )

    Graph.vertex_ids(subgraph)
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
    graph = build_graph!(nodes, connections)
    subgraph = Graph.subgraph(graph, node_ids)

    case Graph.topological_sort(subgraph) do
      {:ok, sorted_ids} ->
        node_map = Map.new(nodes, &{&1.id, &1})
        sorted_nodes = Enum.map(sorted_ids, &Map.fetch!(node_map, &1))
        {:ok, sorted_nodes}

      {:error, reason} ->
        {:error, reason}
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
    graph = build_graph!(nodes, connections)
    Graph.depends_on?(graph, target_node_id, dependency_node_id)
  end

  @doc """
  Returns all root nodes (nodes with no incoming connections).
  """
  @spec root_nodes(node_list(), connection_list()) :: [node_id()]
  def root_nodes(nodes, connections) do
    graph = build_graph!(nodes, connections)
    Graph.roots(graph)
  end

  @doc """
  Returns all leaf nodes (nodes with no outgoing connections).
  """
  @spec leaf_nodes(node_list(), connection_list()) :: [node_id()]
  def leaf_nodes(nodes, connections) do
    graph = build_graph!(nodes, connections)
    Graph.leaves(graph)
  end

  # ============================================================================
  # Graph-based API (for callers that already have a graph)
  # ============================================================================

  @doc """
  Builds a Graph from nodes and connections.

  Useful when you need to perform multiple graph operations
  without rebuilding the graph each time.
  """
  @spec build_graph(node_list(), connection_list()) :: {:ok, Graph.t()} | {:error, term()}
  def build_graph(nodes, connections) do
    Graph.from_workflow(nodes, connections)
  end

  @doc """
  Builds a Graph from nodes and connections, raising on error.
  """
  @spec build_graph!(node_list(), connection_list()) :: Graph.t()
  def build_graph!(nodes, connections) do
    Graph.from_workflow!(nodes, connections)
  end
end

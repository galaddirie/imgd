defmodule Imgd.GraphTest do
  use ExUnit.Case, async: true

  alias Imgd.Graph

  test "from_workflow builds valid graph" do
    nodes = [
      %{id: "a"},
      %{id: "b"},
      %{id: "c"}
    ]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    assert {:ok, graph} = Graph.from_workflow(nodes, connections)
    assert graph.adjacency["a"] == ["b"]
    assert graph.adjacency["b"] == ["c"]
    assert graph.reverse_adjacency["b"] == ["a"]
    assert graph.reverse_adjacency["c"] == ["b"]
  end

  test "from_workflow rejects invalid connections" do
    nodes = [%{id: "a"}]
    connections = [%{source_node_id: "a", target_node_id: "nonexistent"}]

    assert {:error, {:invalid_edges, _}} = Graph.from_workflow(nodes, connections)
  end

  test "upstream returns transitive parents" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    graph = Graph.from_workflow!(nodes, connections)

    assert Graph.upstream(graph, "c") |> Enum.sort() == ["a", "b"]
    assert Graph.upstream(graph, "a") == []
  end

  test "downstream returns transitive children" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    graph = Graph.from_workflow!(nodes, connections)

    assert Graph.downstream(graph, "a") |> Enum.sort() == ["b", "c"]
    assert Graph.downstream(graph, "c") == []
  end

  test "topological_sort sorts nodes in execution order" do
    nodes = [
      %{id: "c"},
      %{id: "a"},
      %{id: "b"}
    ]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    graph = Graph.from_workflow!(nodes, connections)
    {:ok, sorted} = Graph.topological_sort(graph)

    assert Enum.find_index(sorted, &(&1 == "a")) < Enum.find_index(sorted, &(&1 == "b"))
    assert Enum.find_index(sorted, &(&1 == "b")) < Enum.find_index(sorted, &(&1 == "c"))
  end

  test "topological_sort detects cycles" do
    nodes = [%{id: "a"}, %{id: "b"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "a"}
    ]

    graph = Graph.from_workflow!(nodes, connections)

    assert {:error, {:cycle_detected, _}} = Graph.topological_sort(graph)
  end

  test "execution_subgraph excludes nodes" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    graph = Graph.from_workflow!(nodes, connections)

    subgraph = Graph.execution_subgraph(graph, ["c"], exclude: ["b"], include_targets: true)

    # b is excluded, so c has no parents in subgraph, and a is not reached
    assert Graph.vertex_ids(subgraph) |> Enum.sort() == ["c"]
  end

end

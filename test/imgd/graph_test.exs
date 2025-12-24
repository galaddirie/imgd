defmodule Imgd.GraphTest do
  use ExUnit.Case, async: true

  alias Imgd.Graph

  test "from_workflow builds valid graph" do
    steps = [
      %{id: "a"},
      %{id: "b"},
      %{id: "c"}
    ]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "c"}
    ]

    assert {:ok, graph} = Graph.from_workflow(steps, connections)
    assert graph.adjacency["a"] == ["b"]
    assert graph.adjacency["b"] == ["c"]
    assert graph.reverse_adjacency["b"] == ["a"]
    assert graph.reverse_adjacency["c"] == ["b"]
  end

  test "from_workflow rejects invalid connections" do
    steps = [%{id: "a"}]
    connections = [%{source_step_id: "a", target_step_id: "nonexistent"}]

    assert {:error, {:invalid_edges, _}} = Graph.from_workflow(steps, connections)
  end

  test "upstream returns transitive parents" do
    steps = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "c"}
    ]

    graph = Graph.from_workflow!(steps, connections)

    assert Graph.upstream(graph, "c") |> Enum.sort() == ["a", "b"]
    assert Graph.upstream(graph, "a") == []
  end

  test "downstream returns transitive children" do
    steps = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "c"}
    ]

    graph = Graph.from_workflow!(steps, connections)

    assert Graph.downstream(graph, "a") |> Enum.sort() == ["b", "c"]
    assert Graph.downstream(graph, "c") == []
  end

  test "topological_sort sorts steps in execution order" do
    steps = [
      %{id: "c"},
      %{id: "a"},
      %{id: "b"}
    ]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "c"}
    ]

    graph = Graph.from_workflow!(steps, connections)
    {:ok, sorted} = Graph.topological_sort(graph)

    assert Enum.find_index(sorted, &(&1 == "a")) < Enum.find_index(sorted, &(&1 == "b"))
    assert Enum.find_index(sorted, &(&1 == "b")) < Enum.find_index(sorted, &(&1 == "c"))
  end

  test "topological_sort detects cycles" do
    steps = [%{id: "a"}, %{id: "b"}]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "a"}
    ]

    graph = Graph.from_workflow!(steps, connections)

    assert {:error, {:cycle_detected, _}} = Graph.topological_sort(graph)
  end

  test "execution_subgraph excludes steps" do
    steps = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_step_id: "a", target_step_id: "b"},
      %{source_step_id: "b", target_step_id: "c"}
    ]

    graph = Graph.from_workflow!(steps, connections)

    subgraph = Graph.execution_subgraph(graph, ["c"], exclude: ["b"], include_targets: true)

    # b is excluded, so c has no parents in subgraph, and a is not reached
    assert Graph.vertex_ids(subgraph) |> Enum.sort() == ["c"]
  end
end

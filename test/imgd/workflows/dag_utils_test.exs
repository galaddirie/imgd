defmodule Imgd.Workflows.DagUtilsTest do
  use ExUnit.Case, async: true

  alias Imgd.Workflows.DagUtils

  test "upstream_closure returns transitive parents" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    assert DagUtils.upstream_closure("c", nodes, connections) |> Enum.sort() == ["a", "b"]
    assert DagUtils.upstream_closure("a", nodes, connections) == []
  end

  test "downstream_closure returns transitive children" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    assert DagUtils.downstream_closure("a", nodes, connections) |> Enum.sort() == ["b", "c"]
    assert DagUtils.downstream_closure("c", nodes, connections) == []
  end

  test "compute_execution_set removes pinned nodes" do
    nodes = [%{id: "a"}, %{id: "b"}, %{id: "c"}]

    connections = [
      %{source_node_id: "a", target_node_id: "b"},
      %{source_node_id: "b", target_node_id: "c"}
    ]

    assert DagUtils.compute_execution_set(["c"], nodes, connections, ["a"]) |> Enum.sort() ==
             ["b", "c"]
  end
end

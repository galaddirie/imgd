defmodule Imgd.Workflows.WorkflowVersionTest do
  use Imgd.DataCase, async: true
  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Workflows.Embeds.{Node, Connection, Trigger}

  describe "compute_source_hash/3" do
    test "produces the same hash even if node positions change" do
      nodes = [
        %Node{id: "n1", type_id: "t1", name: "Node 1", config: %{}, position: %{"x" => 10, "y" => 20}},
        %Node{id: "n2", type_id: "t2", name: "Node 2", config: %{}, position: %{"x" => 100, "y" => 200}}
      ]
      connections = [%Connection{id: "c1", source_node_id: "n1", target_node_id: "n2"}]
      triggers = [%Trigger{type: :manual}]

      hash1 = WorkflowVersion.compute_source_hash(nodes, connections, triggers)

      # Change positions
      nodes2 = [
        %Node{id: "n1", type_id: "t1", name: "Node 1", config: %{}, position: %{"x" => 50, "y" => 60}},
        %Node{id: "n2", type_id: "t2", name: "Node 2", config: %{}, position: %{"x" => 500, "y" => 600}}
      ]

      hash2 = WorkflowVersion.compute_source_hash(nodes2, connections, triggers)

      assert hash1 == hash2
    end

    test "produces different hash if config changes" do
      nodes = [%Node{id: "n1", type_id: "t1", name: "Node 1", config: %{"val" => 1}}]
      hash1 = WorkflowVersion.compute_source_hash(nodes, [], [])

      nodes2 = [%Node{id: "n1", type_id: "t1", name: "Node 1", config: %{"val" => 2}}]
      hash2 = WorkflowVersion.compute_source_hash(nodes2, [], [])

      assert hash1 != hash2
    end

    test "is stable regardless of input order" do
      nodes = [
        %Node{id: "n1", type_id: "t1", name: "Node 1"},
        %Node{id: "n2", type_id: "t2", name: "Node 2"}
      ]

      hash1 = WorkflowVersion.compute_source_hash(nodes, [], [])
      hash2 = WorkflowVersion.compute_source_hash(Enum.reverse(nodes), [], [])

      assert hash1 == hash2
    end

    test "handles triggers without IDs stably" do
      triggers = [
        %Trigger{type: :manual, config: %{"a" => 1}},
        %Trigger{type: :webhook, config: %{"b" => 2}}
      ]

      hash1 = WorkflowVersion.compute_source_hash([], [], triggers)
      hash2 = WorkflowVersion.compute_source_hash([], [], Enum.reverse(triggers))

      assert hash1 == hash2
    end
  end
end

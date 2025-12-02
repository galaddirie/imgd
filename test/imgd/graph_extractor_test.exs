defmodule Imgd.Workflows.GraphExtractorTest do
  use ExUnit.Case, async: true

  alias Imgd.Workflows.GraphExtractor
  alias Imgd.Workflows.Workflow

  describe "extract_from_runic/1" do
    test "extracts nodes from a linear workflow" do
      require Runic
      import Runic

      runic_workflow =
        workflow(
          name: "test_linear",
          steps: [
            step(fn x -> x * 2 end, name: :double),
            step(fn x -> x + 10 end, name: :add_ten)
          ]
        )

      result = GraphExtractor.extract_from_runic(runic_workflow)

      assert length(result.nodes) == 2
      assert Enum.any?(result.nodes, &(&1.name == "double"))
      assert Enum.any?(result.nodes, &(&1.name == "add_ten"))
      assert Enum.all?(result.nodes, &(&1.type == :step))
    end

    test "extracts nodes from a branching workflow" do
      require Runic
      import Runic

      runic_workflow =
        workflow(
          name: "test_branching",
          steps: [
            {step(fn x -> x * 2 end, name: :double),
             [
               step(fn x -> x + 5 end, name: :add_five),
               step(fn x -> x - 3 end, name: :subtract_three)
             ]}
          ]
        )

      result = GraphExtractor.extract_from_runic(runic_workflow)

      assert length(result.nodes) == 3
      node_names = Enum.map(result.nodes, & &1.name)
      assert "double" in node_names
      assert "add_five" in node_names
      assert "subtract_three" in node_names
    end

    test "extracts rules as nodes" do
      require Runic
      import Runic

      runic_workflow =
        workflow(
          name: "test_rules",
          rules: [
            rule(fn x when x > 10 -> :large end, name: :check_large),
            rule(fn x when x <= 10 -> :small end, name: :check_small)
          ]
        )

      result = GraphExtractor.extract_from_runic(runic_workflow)

      assert length(result.nodes) == 2
      assert Enum.all?(result.nodes, &(&1.type == :rule))
    end

    test "computes layout positions for all nodes" do
      require Runic
      import Runic

      runic_workflow =
        workflow(
          name: "test_layout",
          steps: [
            step(fn x -> x * 2 end, name: :first),
            step(fn x -> x + 10 end, name: :second),
            step(fn x -> "Result: #{x}" end, name: :third)
          ]
        )

      result = GraphExtractor.extract_from_runic(runic_workflow)

      # Every node should have a layout position
      for node <- result.nodes do
        assert Map.has_key?(result.layout, node.id),
               "Node #{node.name} (#{node.id}) missing from layout"
      end
    end
  end

  describe "extract/1" do
    test "returns error for workflow without definition" do
      workflow = %Workflow{definition: nil}

      assert {:error, :no_definition} = GraphExtractor.extract(workflow)
    end
  end
end

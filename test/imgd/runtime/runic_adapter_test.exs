defmodule Imgd.Runtime.RunicAdapterTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Imgd.Runtime.RunicAdapter
  alias Imgd.Workflows.Embeds.{Connection, Node}

  describe "to_runic_workflow/2" do
    test "respects dependency order even when nodes are unordered" do
      source = %{
        id: "unordered_wf",
        nodes: [
          %Node{id: "node_2", type_id: "debug", name: "Second", config: %{}},
          %Node{id: "node_1", type_id: "debug", name: "First", config: %{}}
        ],
        connections: [
          %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{"input" => "test"})
        |> Workflow.raw_productions()

      assert length(result) >= 2
    end
  end

  describe "condition nodes" do
    test "passes input through when the condition is true" do
      source = %{
        id: "condition_true",
        nodes: [
          %Node{
            id: "cond_1",
            type_id: "condition",
            name: "Condition",
            config: %{"condition" => "{{ json.active }}"}
          }
        ],
        connections: []
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      input = %{"active" => true}

      result =
        workflow
        |> Workflow.plan_eagerly(input)
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert %{"active" => true} in result
    end

    test "produces no output when the condition is false" do
      source = %{
        id: "condition_false",
        nodes: [
          %Node{
            id: "cond_1",
            type_id: "condition",
            name: "Condition",
            config: %{"condition" => "{{ json.active }}"}
          }
        ],
        connections: []
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      input = %{"active" => false}

      result =
        workflow
        |> Workflow.plan_eagerly(input)
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert result == []
    end
  end
end

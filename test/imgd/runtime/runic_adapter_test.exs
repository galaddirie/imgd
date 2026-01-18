defmodule Imgd.Runtime.RunicAdapterTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Imgd.Runtime.RunicAdapter
  alias Imgd.Runtime.Hooks.Observability
  alias Imgd.Workflows.Embeds.{Connection, NodeGroup, Step}

  describe "to_runic_workflow/2" do
    test "respects dependency order even when steps are unordered" do
      source = %{
        id: "unordered_wf",
        steps: [
          %Step{id: "step_2", type_id: "debug", name: "Second", config: %{}},
          %Step{id: "step_1", type_id: "debug", name: "First", config: %{}}
        ],
        connections: [
          %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
        ]
      }

      workflow =
        source
        |> RunicAdapter.to_runic_workflow()
        |> Observability.attach_all_hooks(execution_id: "test_exec", workflow_id: "grouped_wf")

      result =
        workflow
        |> Workflow.react_until_satisfied(%{"input" => "test"})
        |> Workflow.raw_productions()

      assert length(result) >= 2
    end

    test "auto-joins multiple parents before executing a child step" do
      source = %{
        id: "join_wf",
        steps: [
          %Step{
            id: "left",
            type_id: "math",
            name: "Left",
            config: %{"operation" => "abs", "value" => -1}
          },
          %Step{
            id: "right",
            type_id: "math",
            name: "Right",
            config: %{"operation" => "abs", "value" => -2}
          },
          %Step{id: "child", type_id: "debug", name: "Child", config: %{}}
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "left", target_step_id: "child"},
          %Connection{id: "c2", source_step_id: "right", target_step_id: "child"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{})
        |> Workflow.raw_productions()

      assert Enum.any?(result, &(&1 == [1, 2]))
    end

    test "uses connection order when joining parents" do
      source = %{
        id: "join_order_wf",
        steps: [
          %Step{
            id: "left",
            type_id: "math",
            name: "Left",
            config: %{"operation" => "abs", "value" => -1}
          },
          %Step{
            id: "right",
            type_id: "math",
            name: "Right",
            config: %{"operation" => "abs", "value" => -2}
          },
          %Step{id: "child", type_id: "debug", name: "Child", config: %{}}
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "right", target_step_id: "child"},
          %Connection{id: "c2", source_step_id: "left", target_step_id: "child"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{})
        |> Workflow.raw_productions()

      assert Enum.any?(result, &(&1 == [2, 1]))
    end

    test "reuses a join for siblings with the same parents" do
      source = %{
        id: "join_reuse_wf",
        steps: [
          %Step{
            id: "left",
            type_id: "math",
            name: "Left",
            config: %{"operation" => "abs", "value" => -1}
          },
          %Step{
            id: "right",
            type_id: "math",
            name: "Right",
            config: %{"operation" => "abs", "value" => -2}
          },
          %Step{id: "child_a", type_id: "debug", name: "Child A", config: %{}},
          %Step{id: "child_b", type_id: "debug", name: "Child B", config: %{}}
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "left", target_step_id: "child_a"},
          %Connection{id: "c2", source_step_id: "right", target_step_id: "child_a"},
          %Connection{id: "c3", source_step_id: "left", target_step_id: "child_b"},
          %Connection{id: "c4", source_step_id: "right", target_step_id: "child_b"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      join_count =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.count(&match?(%Workflow.Join{}, &1))

      assert join_count == 1

      executed_workflow = Workflow.react_until_satisfied(workflow, %{})

      child_a = Workflow.get_component!(executed_workflow, "child_a")
      child_b = Workflow.get_component!(executed_workflow, "child_b")

      child_a_outputs =
        executed_workflow.graph
        |> Graph.out_edges(child_a, by: :produced)
        |> Enum.map(& &1.v2.value)

      child_b_outputs =
        executed_workflow.graph
        |> Graph.out_edges(child_b, by: :produced)
        |> Enum.map(& &1.v2.value)

      assert [1, 2] in child_a_outputs
      assert [1, 2] in child_b_outputs
    end

    test "exposes group output as a composite step" do
      source = %{
        id: "grouped_wf",
        steps: [
          %Step{
            id: "inner_math",
            type_id: "math",
            name: "Inner Math",
            config: %{"operation" => "abs", "value" => -2}
          },
          %Step{
            id: "inner_output",
            type_id: "workflow_output",
            name: "Group Output",
            config: %{}
          },
          %Step{
            id: "outer_math",
            type_id: "math",
            name: "Outer Math",
            config: %{
              "operation" => "add",
              "value" => "{{ json }}",
              "operand" => 3
            }
          }
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "inner_math", target_step_id: "inner_output"},
          %Connection{id: "c2", source_step_id: "inner_output", target_step_id: "outer_math"}
        ],
        groups: [
          %NodeGroup{
            id: "group_1",
            name: "Group 1",
            step_ids: ["inner_math", "inner_output"],
            output_step_id: "inner_output",
            position: %{},
            collapsed: false
          }
        ]
      }

      Process.put(:imgd_accumulated_outputs, %{})
      Process.delete(:imgd_step_outputs)

      workflow =
        source
        |> RunicAdapter.to_runic_workflow()
        |> Observability.attach_all_hooks(execution_id: "test_exec", workflow_id: "grouped_wf")

      result =
        workflow
        |> Workflow.react_until_satisfied(%{})
        |> Workflow.raw_productions()

      assert 5 in result
      assert Process.get(:imgd_accumulated_outputs, %{})["group_1"] == 2
    end
  end

  describe "condition steps" do
    test "passes input through when the condition is true" do
      source = %{
        id: "condition_true",
        steps: [
          %Step{
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
        steps: [
          %Step{
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

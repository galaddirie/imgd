defmodule Imgd.Workflows.ValidatorTest do
  use ExUnit.Case, async: true

  alias Imgd.Workflows.Validator
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{NodeGroup, Step}

  test "fails when steps belong to multiple groups" do
    steps = [
      %Step{id: "step_a", type_id: "debug", name: "Step A", config: %{}}
    ]

    groups = [
      %NodeGroup{
        id: "group_1",
        name: "Group 1",
        step_ids: ["step_a"],
        output_step_id: "step_a"
      },
      %NodeGroup{
        id: "group_2",
        name: "Group 2",
        step_ids: ["step_a"],
        output_step_id: "step_a"
      }
    ]

    assert {:error, errors} = Validator.validate(%WorkflowDraft{steps: steps, groups: groups})
    assert Enum.any?(errors, fn {tag, _} -> tag == :groups end)
  end

  test "fails on cross-group step references" do
    steps = [
      %Step{
        id: "inside",
        type_id: "math",
        name: "Inside",
        config: %{"value" => "{{ steps.outside.json }}", "operation" => "abs"}
      },
      %Step{id: "outside", type_id: "debug", name: "Outside", config: %{}}
    ]

    groups = [
      %NodeGroup{
        id: "group_1",
        name: "Group 1",
        step_ids: ["inside"],
        output_step_id: "inside"
      }
    ]

    assert {:error, errors} = Validator.validate(%WorkflowDraft{steps: steps, groups: groups})

    assert Enum.any?(errors, fn
             {:step, "inside", _} -> true
             _ -> false
           end)
  end
end

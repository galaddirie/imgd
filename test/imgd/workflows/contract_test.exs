defmodule Imgd.Workflows.ContractTest do
  use ExUnit.Case, async: true

  alias Imgd.Workflows.Contract
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.Step

  test "derive/1 builds typed inputs and outputs" do
    input_schema = %{
      "type" => "object",
      "properties" => %{"email" => %{"type" => "string"}}
    }

    output_schema = %{
      "type" => "object",
      "properties" => %{"status" => %{"type" => "string"}}
    }

    steps = [
      %Step{
        id: "manual_trigger",
        type_id: "manual_input",
        name: "Manual Input",
        config: %{"input_schema" => input_schema}
      },
      %Step{
        id: "final_output",
        type_id: "workflow_output",
        name: "Workflow Output",
        config: %{"name" => "result", "schema" => output_schema}
      }
    ]

    contract = Contract.derive(%WorkflowDraft{steps: steps})

    assert [%{trigger_type: "manual_input", schema: ^input_schema}] = contract.inputs
    assert [%{name: "result", schema: ^output_schema}] = contract.outputs
  end
end

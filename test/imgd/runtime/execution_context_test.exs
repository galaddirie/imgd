defmodule Imgd.Runtime.ExecutionContextTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Imgd.Runtime.ExecutionContext

  describe "from_runic_workflow/2" do
    test "extracts step outputs from the Runic graph" do
      workflow =
        Workflow.new(name: "ctx_test")
        |> Workflow.add(Runic.step(fn x -> x * 2 end, name: "double"))
        |> Workflow.add(Runic.step(fn x -> x + 1 end, name: "plus_one"), to: "double")
        |> Workflow.react_until_satisfied(3)

      ctx =
        ExecutionContext.from_runic_workflow(workflow, %{
          execution_id: "exec-1",
          workflow_id: "wf-1",
          step_id: "plus_one",
          variables: %{"flag" => true},
          metadata: %{"trace_id" => "trace-1"},
          input: 3
        })

      assert ctx.execution_id == "exec-1"
      assert ctx.step_outputs["double"] == 6
      assert ctx.step_outputs["plus_one"] == 7
      assert ctx.variables["flag"] == true
    end
  end
end

defmodule Imgd.Runtime.Steps.StepRunnerTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Steps.StepRunner
  alias Imgd.Workflows.Embeds.Step

  describe "execute_with_context/3" do
    test "evaluates expressions in config before executing the step" do
      step = %Step{
        id: "math_1",
        type_id: "math",
        name: "Math",
        config: %{
          "operation" => "add",
          "value" => "{{ json.amount }}",
          "operand" => "{{ json.tax }}"
        }
      }

      result =
        StepRunner.execute_with_context(
          step,
          %{"amount" => 2, "tax" => 3},
          execution_id: "exec-1",
          workflow_id: "wf-1"
        )

      assert result == 5.0
    end

    test "throws when the executor returns an error" do
      step = %Step{
        id: "math_2",
        type_id: "math",
        name: "Math",
        config: %{
          "operation" => "divide",
          "value" => "{{ json.amount }}",
          "operand" => 0
        }
      }

      assert {:step_error, "math_2", "division by zero"} =
               catch_throw(
                 StepRunner.execute_with_context(
                   step,
                   %{"amount" => 10},
                   execution_id: "exec-1",
                   workflow_id: "wf-1"
                 )
               )
    end

    test "throws when expression evaluation fails" do
      step = %Step{
        id: "math_3",
        type_id: "math",
        name: "Math",
        config: %{
          "operation" => "add",
          "value" => "{{ json.amount | missing_filter }}",
          "operand" => 1
        }
      }

      assert {:step_error, "math_3", {:expression_error, _}} =
               catch_throw(
                 StepRunner.execute_with_context(
                   step,
                   %{"amount" => 10},
                   execution_id: "exec-1",
                   workflow_id: "wf-1"
                 )
               )
    end
  end
end

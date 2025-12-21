defmodule Imgd.Runtime.Nodes.NodeStepTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Nodes.NodeStep
  alias Imgd.Workflows.Embeds.Node

  describe "execute_with_context/3" do
    test "evaluates expressions in config before executing the node" do
      node = %Node{
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
        NodeStep.execute_with_context(
          node,
          %{"amount" => 2, "tax" => 3},
          execution_id: "exec-1",
          workflow_id: "wf-1"
        )

      assert result == 5.0
    end

    test "throws when the executor returns an error" do
      node = %Node{
        id: "math_2",
        type_id: "math",
        name: "Math",
        config: %{
          "operation" => "divide",
          "value" => "{{ json.amount }}",
          "operand" => 0
        }
      }

      assert {:node_error, "math_2", "division by zero"} =
               catch_throw(
                 NodeStep.execute_with_context(
                   node,
                   %{"amount" => 10},
                   execution_id: "exec-1",
                   workflow_id: "wf-1"
                 )
               )
    end

    test "throws when expression evaluation fails" do
      node = %Node{
        id: "math_3",
        type_id: "math",
        name: "Math",
        config: %{
          "operation" => "add",
          "value" => "{{ json.amount | missing_filter }}",
          "operand" => 1
        }
      }

      assert {:node_error, "math_3", {:expression_error, _}} =
               catch_throw(
                 NodeStep.execute_with_context(
                   node,
                   %{"amount" => 10},
                   execution_id: "exec-1",
                   workflow_id: "wf-1"
                 )
               )
    end
  end
end

defmodule Imgd.Runtime.ExpressionTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Expression
  alias Imgd.Executions.Execution

  describe "evaluate/3" do
    test "returns the input when no Liquid expressions exist" do
      assert {:ok, "plain text"} = Expression.evaluate("plain text", %{}, [])
    end

    test "evaluates with execution context variables" do
      execution = %Execution{
        id: "exec-1",
        workflow_id: "wf-1",
        trigger: %Execution.Trigger{type: :manual, data: %{"name" => "Ada"}},
        metadata: %Execution.Metadata{extras: %{"variables" => %{"threshold" => 3}}}
      }

      assert {:ok, "Hello Ada"} =
               Expression.evaluate("Hello {{ json.name }}", execution, [])

      assert {:ok, "3"} =
               Expression.evaluate("{{ variables.threshold }}", execution, [])
    end

    test "uses node outputs from a state store map" do
      execution = %Execution{
        id: "exec-1",
        workflow_id: "wf-1",
        trigger: %Execution.Trigger{type: :manual, data: %{}}
      }

      assert {:ok, "10"} =
               Expression.evaluate(
                 "{{ nodes.node_1.json.value }}",
                 execution,
                 state_store: %{"node_1" => %{"value" => 10}}
               )
    end

    test "returns an error for unknown variables when strict_variables is true" do
      assert {:error, %{type: :render_error}} =
               Expression.evaluate_with_vars("{{ missing }}", %{}, strict_variables: true)
    end

    test "returns an error for unknown filters when strict_filters is true" do
      assert {:error, %{type: :render_error}} =
               Expression.evaluate_with_vars("{{ json.name | unknown }}", %{"json" => %{}})
    end
  end

  describe "evaluate_deep/3" do
    test "evaluates nested expressions within maps and lists" do
      data = %{
        "greeting" => "Hello {{ json.name }}",
        "items" => ["{{ json.count }}", "static"],
        "nested" => %{"ok" => "{{ json.ok }}"}
      }

      vars = %{"json" => %{"name" => "Ada", "count" => 2, "ok" => true}}

      assert {:ok, result} = Expression.evaluate_deep(data, vars)
      assert result["greeting"] == "Hello Ada"
      assert result["items"] == ["2", "static"]
      assert result["nested"]["ok"] == "true"
    end

    test "returns an error when any nested expression fails" do
      data = %{"value" => "{{ json.name | missing_filter }}"}

      assert {:error, %{type: :render_error}} =
               Expression.evaluate_deep(data, %{"json" => %{}})
    end
  end

  describe "validate/1" do
    test "returns a parse error for invalid Liquid syntax" do
      assert {:error, %{type: :parse_error}} = Expression.validate("{% if %}")
    end
  end

  describe "contains_expression?/1" do
    test "detects Liquid expressions" do
      assert Expression.contains_expression?("Hello {{ name }}")
      refute Expression.contains_expression?("Hello world")
    end
  end
end

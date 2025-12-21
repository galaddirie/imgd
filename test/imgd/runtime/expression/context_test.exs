defmodule Imgd.Runtime.Expression.ContextTest do
  use ExUnit.Case, async: false

  alias Imgd.Runtime.Expression.Context
  alias Imgd.Executions.Execution

  describe "build/3" do
    test "merges execution context with runtime outputs and uses current input" do
      execution = %Execution{
        id: "exec-1",
        workflow_id: "wf-1",
        trigger: %Execution.Trigger{type: :manual, data: %{"fallback" => "input"}},
        context: %{"node_a" => %{"status" => 200}},
        metadata: %Execution.Metadata{
          trace_id: "trace-123",
          correlation_id: "corr-456"
        }
      }

      node_outputs = %{
        "node_a" => %{"status" => 500, "body" => "boom"},
        "node_b" => %{"headers" => %{"x" => "y"}}
      }

      vars = Context.build(execution, node_outputs, %{"payload" => "input"})

      assert vars["json"] == %{"payload" => "input"}
      assert vars["nodes"]["node_a"]["status"] == 500
      assert vars["nodes"]["node_a"]["body"] == "boom"
      assert vars["nodes"]["node_b"]["headers"] == %{"x" => "y"}
      assert vars["execution"]["trace_id"] == "trace-123"
      assert vars["execution"]["correlation_id"] == "corr-456"
    end

    test "uses trigger data when no current input is provided" do
      execution = %Execution{
        id: "exec-1",
        workflow_id: "wf-1",
        trigger: %Execution.Trigger{type: :manual, data: %{"fallback" => "input"}}
      }

      vars = Context.build(execution, %{}, nil)
      assert vars["json"] == %{"fallback" => "input"}
      assert vars["input"] == %{"fallback" => "input"}
    end
  end

  describe "build_minimal/1" do
    test "exposes allowed environment variables" do
      Application.put_env(:imgd, :allowed_env_vars, ["IMGD_TEST_ENV"])
      System.put_env("IMGD_TEST_ENV", "visible")

      on_exit(fn ->
        Application.delete_env(:imgd, :allowed_env_vars)
        System.delete_env("IMGD_TEST_ENV")
      end)

      vars = Context.build_minimal(%{"ok" => true})
      assert vars["env"]["IMGD_TEST_ENV"] == "visible"
    end
  end

  describe "normalize_value/1" do
    test "normalizes atoms, dates, and nested values" do
      value = %{
        status: :ok,
        active: true,
        created_at: ~D[2024-01-02],
        tags: [:alpha, :beta]
      }

      assert %{
               "status" => "ok",
               "active" => true,
               "created_at" => "2024-01-02",
               "tags" => ["alpha", "beta"]
             } = Context.normalize_value(value)
    end
  end
end

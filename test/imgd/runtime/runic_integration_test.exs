defmodule Imgd.Runtime.RunicIntegrationTest do
  @moduledoc """
  Integration tests for the Runic workflow execution system.
  Tests the full flow from workflow definition through execution.
  """
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Imgd.Runtime.{ExecutionContext, RunicAdapter, Events}
  alias Imgd.Runtime.Steps.StepRunner
  alias Imgd.Workflows.Embeds.{Step, Connection}

  # ===========================================================================
  # ExecutionContext Tests
  # ===========================================================================

  describe "ExecutionContext" do
    test "new/1 creates context with defaults" do
      ctx = ExecutionContext.new()

      assert ctx.execution_id == nil
      assert ctx.step_outputs == %{}
      assert ctx.variables == %{}
      assert ctx.input == nil
    end

    test "new/1 accepts keyword options" do
      ctx =
        ExecutionContext.new(
          execution_id: "exec_123",
          workflow_id: "wf_456",
          step_id: "step_1",
          variables: %{"key" => "value"},
          input: %{"data" => 42}
        )

      assert ctx.execution_id == "exec_123"
      assert ctx.workflow_id == "wf_456"
      assert ctx.step_id == "step_1"
      assert ctx.variables == %{"key" => "value"}
      assert ctx.input == %{"data" => 42}
    end

    test "put_output/3 adds step output" do
      ctx = ExecutionContext.new()
      ctx = ExecutionContext.put_output(ctx, "step_1", %{"result" => 100})

      assert ExecutionContext.get_output(ctx, "step_1") == %{"result" => 100}
    end

    test "get_output/2 returns nil for missing step" do
      ctx = ExecutionContext.new()
      assert ExecutionContext.get_output(ctx, "missing") == nil
    end
  end

  # ===========================================================================
  # StepStep Tests
  # ===========================================================================

  describe "StepRunner.create/2" do
    test "creates a Runic step from a step" do
      step = %Step{
        id: "debug_1",
        type_id: "debug",
        name: "Test Debug",
        config: %{"label" => "Test"}
      }

      step = StepRunner.create(step)

      assert %Runic.Workflow.Step{} = step
      assert step.name == "debug_1"
    end

    test "executes debug step and returns input unchanged" do
      step = %Step{
        id: "debug_1",
        type_id: "debug",
        name: "Test Debug",
        config: %{"label" => "Test", "level" => "debug"}
      }

      step = StepRunner.create(step)

      # Create a minimal workflow and execute
      wrk = Workflow.new(name: "test")
      wrk = Workflow.add(wrk, step)

      result =
        wrk
        |> Workflow.react_until_satisfied(%{"value" => 42})
        |> Workflow.raw_productions()

      assert %{"value" => 42} in result
    end
  end

  # ===========================================================================
  # RunicAdapter Tests
  # ===========================================================================

  describe "RunicAdapter.to_runic_workflow/2" do
    test "builds workflow from source with single step" do
      source = %{
        id: "test_wf",
        steps: [
          %Step{id: "step_1", type_id: "debug", name: "Debug 1", config: %{}}
        ],
        connections: []
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      assert %Workflow{} = workflow
      assert workflow.name == "execution_test_wf"
    end

    test "builds workflow with linear pipeline" do
      source = %{
        id: "linear_wf",
        steps: [
          %Step{id: "step_1", type_id: "debug", name: "Debug 1", config: %{"label" => "First"}},
          %Step{id: "step_2", type_id: "debug", name: "Debug 2", config: %{"label" => "Second"}}
        ],
        connections: [
          %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      # Execute and verify both steps ran
      result =
        workflow
        |> Workflow.react_until_satisfied(%{"input" => "test"})
        |> Workflow.raw_productions()

      # Both debug steps should pass through the same input
      assert length(result) >= 2
    end

    test "handles fan-out pattern (one parent, multiple children)" do
      source = %{
        id: "fanout_wf",
        steps: [
          %Step{id: "root", type_id: "debug", name: "Root", config: %{}},
          %Step{id: "child_a", type_id: "debug", name: "Child A", config: %{}},
          %Step{id: "child_b", type_id: "debug", name: "Child B", config: %{}}
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "root", target_step_id: "child_a"},
          %Connection{id: "c2", source_step_id: "root", target_step_id: "child_b"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{"data" => 1})
        |> Workflow.raw_productions()

      # Root + 2 children = at least 3 outputs
      assert length(result) >= 3
    end
  end

  # ===========================================================================
  # Splitter & Aggregator Tests
  # ===========================================================================

  describe "Splitter executor" do
    test "splits list input" do
      step = %Step{
        id: "split_1",
        type_id: "splitter",
        name: "Splitter",
        config: %{}
      }

      # Test executor directly
      {:ok, result} = Imgd.Steps.Executors.Splitter.execute(%{}, [1, 2, 3], nil)
      assert result == [1, 2, 3]
    end

    test "extracts nested field" do
      {:ok, result} =
        Imgd.Steps.Executors.Splitter.execute(
          %{"field" => "items"},
          %{"items" => [1, 2, 3]},
          nil
        )

      assert result == [1, 2, 3]
    end

    test "wraps single item in list" do
      {:ok, result} = Imgd.Steps.Executors.Splitter.execute(%{}, "single", nil)
      assert result == ["single"]
    end
  end

  describe "Aggregator executor" do
    test "sum operation" do
      {:ok, result} =
        Imgd.Steps.Executors.Aggregator.execute(
          %{"operation" => "sum"},
          [1, 2, 3, 4],
          nil
        )

      assert result == 10
    end

    test "count operation" do
      {:ok, result} =
        Imgd.Steps.Executors.Aggregator.execute(
          %{"operation" => "count"},
          [1, 2, 3, 4, 5],
          nil
        )

      assert result == 5
    end

    test "collect operation" do
      {:ok, result} =
        Imgd.Steps.Executors.Aggregator.execute(
          %{"operation" => "collect"},
          [1, 2, 3],
          nil
        )

      assert result == [1, 2, 3]
    end

    test "concat operation" do
      {:ok, result} =
        Imgd.Steps.Executors.Aggregator.execute(
          %{"operation" => "concat"},
          ["a", "b", "c"],
          nil
        )

      assert result == "abc"
    end
  end

  # ===========================================================================
  # Condition & Switch Tests
  # ===========================================================================

  describe "Condition executor" do
    test "passes input when condition is true" do
      ctx = ExecutionContext.new(input: %{"value" => 10})

      {:ok, result} =
        Imgd.Steps.Executors.Condition.execute(
          %{"condition" => "true"},
          %{"value" => 10},
          ctx
        )

      assert result == %{"value" => 10}
    end

    test "skips when condition is false" do
      ctx = ExecutionContext.new(input: %{"value" => 10})

      result =
        Imgd.Steps.Executors.Condition.execute(
          %{"condition" => "false"},
          %{"value" => 10},
          ctx
        )

      assert result == {:skip, :condition_false}
    end

    test "evaluates expression conditions" do
      ctx = ExecutionContext.new(input: %{"status" => "active"})

      # When expression evaluates to truthy
      {:ok, _} =
        Imgd.Steps.Executors.Condition.execute(
          %{"condition" => "{{ json.status }}"},
          %{"status" => "active"},
          ctx
        )
    end
  end

  describe "Switch executor" do
    test "matches case and returns tagged output" do
      ctx = ExecutionContext.new()

      {:ok, {:branch, output, _data}} =
        Imgd.Steps.Executors.Switch.execute(
          %{
            "value" => "{{ json.type }}",
            "cases" => [
              %{"match" => "order", "output" => "orders"},
              %{"match" => "user", "output" => "users"}
            ]
          },
          %{"type" => "order"},
          ctx
        )

      assert output == "orders"
    end

    test "returns default when no case matches" do
      ctx = ExecutionContext.new()

      {:ok, {:branch, output, _data}} =
        Imgd.Steps.Executors.Switch.execute(
          %{
            "value" => "{{ json.type }}",
            "cases" => [
              %{"match" => "order", "output" => "orders"}
            ],
            "default_output" => "unknown"
          },
          %{"type" => "something_else"},
          ctx
        )

      assert output == "unknown"
    end
  end

  # ===========================================================================
  # Events Tests
  # ===========================================================================

  describe "Events" do
    test "emit/3 returns :ok" do
      result = Events.emit(:step_completed, "test_exec", %{step: "step_1"})
      assert result == :ok
    end
  end

  # ===========================================================================
  # Full Integration Test
  # ===========================================================================

  describe "Full workflow execution" do
    test "executes multi-step workflow end to end" do
      # Create a simple 3-step pipeline
      source = %{
        id: "integration_test",
        steps: [
          %Step{id: "start", type_id: "debug", name: "Start", config: %{"label" => "Start"}},
          %Step{id: "middle", type_id: "debug", name: "Middle", config: %{"label" => "Middle"}},
          %Step{id: "end", type_id: "debug", name: "End", config: %{"label" => "End"}}
        ],
        connections: [
          %Connection{id: "c1", source_step_id: "start", target_step_id: "middle"},
          %Connection{id: "c2", source_step_id: "middle", target_step_id: "end"}
        ]
      }

      workflow = RunicAdapter.to_runic_workflow(source)

      # Execute the workflow
      final_workflow =
        workflow
        |> Workflow.react_until_satisfied(%{"test" => "data"})

      # Verify we have productions
      productions = Workflow.raw_productions(final_workflow)
      assert length(productions) >= 3

      # All productions should be the same (debug passes through)
      assert Enum.all?(productions, &(&1 == %{"test" => "data"}))
    end
  end
end

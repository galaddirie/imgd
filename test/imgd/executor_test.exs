defmodule Imgd.Workflows.ExecutorTest do
  use Imgd.DataCase, async: true

  alias Imgd.Workflows.Executor
  alias Imgd.Workflows.Workflow

  describe "run/2" do
    test "executes a linear workflow successfully" do
      workflow =
        build_workflow_with_definition(fn ->
          require Runic
          import Runic

          workflow(
            name: "test_linear",
            steps: [
              step(fn x -> x * 2 end, name: :double),
              step(fn x -> x + 10 end, name: :add_ten)
            ]
          )
        end)

      assert {:ok, result} = Executor.run(workflow, 5)

      assert result.status == :completed
      assert result.input == 5
      # 5 -> 10 (double) -> 20 (add_ten)
      assert 10 in result.productions
      assert 20 in result.productions
      assert result.error == nil
      assert result.duration_ms >= 0
    end

    test "executes a branching workflow successfully" do
      workflow =
        build_workflow_with_definition(fn ->
          require Runic
          import Runic

          workflow(
            name: "test_branching",
            steps: [
              {step(fn x -> x * 2 end, name: :double),
               [
                 step(fn x -> x + 5 end, name: :add_five),
                 step(fn x -> x - 3 end, name: :subtract_three)
               ]}
            ]
          )
        end)

      assert {:ok, result} = Executor.run(workflow, 5)

      assert result.status == :completed
      # 5 -> 10 (double) -> 15 (add_five), 7 (subtract_three)
      assert 10 in result.productions
      assert 15 in result.productions
      assert 7 in result.productions
    end

    test "executes a workflow with rules" do
      workflow =
        build_workflow_with_definition(fn ->
          require Runic
          import Runic

          workflow(
            name: "test_rules",
            steps: [
              step(fn x -> x * 2 end, name: :double)
            ],
            rules: [
              rule(fn x when is_number(x) and x > 20 -> {:large, x} end, name: :check_large),
              rule(fn x when is_number(x) and x <= 20 -> {:small, x} end, name: :check_small)
            ]
          )
        end)

      # Test with input that results in small (5 * 2 = 10 <= 20)
      assert {:ok, result} = Executor.run(workflow, 5)
      assert {:small, 10} in result.productions

      # Test with input that results in large (15 * 2 = 30 > 20)
      assert {:ok, result} = Executor.run(workflow, 15)
      assert {:large, 30} in result.productions
    end

    test "returns error for workflow without definition" do
      workflow = %Workflow{definition: nil}

      assert {:error, result} = Executor.run(workflow, 5)
      assert result.status == :failed
      assert result.error.type == "InvalidWorkflow"
    end

    test "handles execution errors gracefully" do
      workflow =
        build_workflow_with_definition(fn ->
          require Runic
          import Runic

          workflow(
            name: "test_error",
            steps: [
              step(fn _x -> raise "Intentional error" end, name: :failing_step)
            ]
          )
        end)

      assert {:error, result} = Executor.run(workflow, 5)
      assert result.status == :failed
      refute is_nil(result.error)
    end
  end

  # Helper to build a workflow with a serialized definition
  defp build_workflow_with_definition(build_fn) do
    runic_workflow = build_fn.()
    build_log = Runic.Workflow.log(runic_workflow)

    definition = %{
      "encoded" => build_log |> :erlang.term_to_binary() |> Base.encode64()
    }

    %Workflow{
      id: Ecto.UUID.generate(),
      name: "Test Workflow",
      definition: definition,
      version: 1,
      status: :published
    }
  end
end

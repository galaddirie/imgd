defmodule Imgd.Engine.RunnerTest do
  use Imgd.DataCase

  import Imgd.AccountsFixtures
  import Imgd.WorkflowsFixtures

  alias Imgd.Engine.{Runner, StepExecutor}
  alias Imgd.Engine.DataFlow
  alias Imgd.Workflows.Execution
  alias Imgd.Repo

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  test "prepare/2 and plan_input/2 produce runnables", %{scope: scope} do
    %{workflow: runic_workflow} = runic_workflow_with_single_step()
    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)

    execution =
      execution_fixture(scope, workflow, input: %{foo: "bar"}) |> Repo.preload(:workflow)

    {:ok, state} = Runner.prepare(execution, :start)
    state = Runner.plan_input(state, DataFlow.unwrap(execution.input))

    assert Runner.has_runnables?(state)
    assert [{_node, %Runic.Workflow.Fact{value: %{foo: "bar"}}}] = Runner.get_runnables(state)
  end

  test "advance/2 updates the generation after a step completes", %{scope: scope} do
    %{workflow: runic_workflow} = runic_workflow_with_single_step(work: :mark_done)

    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)
    execution = execution_fixture(scope, workflow, input: %{foo: "bar"})

    {:ok, state} = Runner.prepare(execution, :start)
    state = Runner.plan_input(state, DataFlow.unwrap(execution.input))

    [{node, fact}] = Runner.get_runnables(state)
    execution = state.execution

    {:ok, updated_workflow, _events} =
      StepExecutor.execute(execution, state.workflow, node, fact, generation: state.generation)

    {:ok, next_state} = Runner.advance(state, updated_workflow)

    assert next_state.generation == updated_workflow.generations
    refute Runner.has_runnables?(next_state)
  end

  test "complete/1 marks the execution as completed with output", %{scope: scope} do
    %{workflow: runic_workflow} = runic_workflow_with_single_step()
    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)
    execution = execution_fixture(scope, workflow, input: %{foo: "bar"})

    {:ok, state} = Runner.prepare(execution, :start)
    state = Runner.plan_input(state, DataFlow.unwrap(execution.input))

    [{node, fact}] = Runner.get_runnables(state)
    {run_after_step, _events} = Runic.Workflow.invoke_with_events(state.workflow, node, fact)
    {:ok, state} = Runner.advance(state, run_after_step)

    assert {:ok, %Execution{} = completed} = Runner.complete(state)
    assert completed.status == :completed
    assert completed.output[:productions] |> Enum.count() == 1
    assert completed.output[:generation] == run_after_step.generations
  end

  test "fail/2 marks the execution as failed", %{scope: scope} do
    %{workflow: runic_workflow} = runic_workflow_with_single_step()
    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)
    execution = execution_fixture(scope, workflow, input: %{foo: "bar"})

    {:ok, state} = Runner.prepare(execution, :start)
    state = Runner.plan_input(state, DataFlow.unwrap(execution.input))

    assert {:ok, %Execution{} = failed} = Runner.fail(state, :boom)
    assert failed.status == :failed
    assert failed.error.message =~ "boom"
  end
end

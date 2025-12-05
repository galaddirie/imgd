defmodule Imgd.Engine.StepExecutorTest do
  use Imgd.DataCase

  import Imgd.AccountsFixtures
  import Imgd.WorkflowsFixtures

  alias Imgd.Engine.StepExecutor
  alias Imgd.Engine.DataFlow
  alias Imgd.Workflows.ExecutionStep
  alias Imgd.Repo

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  test "execute/5 persists and completes a step", %{scope: scope} do
    %{workflow: runic_workflow} =
      runic_workflow_with_single_step(work: :mark_done)

    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)

    execution =
      execution_fixture(scope, workflow, input: %{foo: "bar"})
      |> Repo.preload(:workflow)

    planned_workflow =
      Runic.Workflow.plan_eagerly(runic_workflow, DataFlow.unwrap(execution.input))

    [{node, fact}] = Runic.Workflow.next_runnables(planned_workflow)

    assert {:ok, updated_workflow, events} =
             StepExecutor.execute(execution, planned_workflow, node, fact,
               generation: planned_workflow.generations
             )

    assert length(events) == 1
    assert updated_workflow.generations == planned_workflow.generations

    [step_record] = Repo.all(ExecutionStep)
    assert step_record.status == :completed
    assert step_record.output_fact_hash
    assert is_map(step_record.output_snapshot)
    assert Map.has_key?(step_record.output_snapshot, "value")
  end

  test "execute/5 marks the step as failed on timeout", %{scope: scope} do
    %{workflow: runic_workflow} =
      runic_workflow_with_single_step(work: :slow)

    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)

    execution =
      execution_fixture(scope, workflow, input: %{foo: "bar"})
      |> Repo.preload(:workflow)

    planned_workflow =
      Runic.Workflow.plan_eagerly(runic_workflow, DataFlow.unwrap(execution.input))

    [{node, fact}] = Runic.Workflow.next_runnables(planned_workflow)

    assert {:error, {:timeout, 10}, nil} =
             StepExecutor.execute(execution, planned_workflow, node, fact,
               timeout_ms: 10,
               generation: planned_workflow.generations
             )

    [step_record] = Repo.all(ExecutionStep)
    assert step_record.status == :failed
    assert step_record.error["type"] == "timeout"
  end

  test "retry_delay_ms/2 applies backoff deterministically without jitter" do
    delay = StepExecutor.retry_delay_ms(3, base_delay_ms: 100, max_delay_ms: 1_000)
    assert delay >= 300 and delay <= 500
  end
end

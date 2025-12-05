defmodule Imgd.Workers.ExecutionWorkerTest do
  use Imgd.DataCase

  import Imgd.AccountsFixtures
  import Imgd.WorkflowsFixtures

  alias Imgd.Workers.ExecutionWorker
  alias Imgd.Workflows.Execution

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  test "perform/1 runs the workflow to completion", %{scope: scope} do
    %{workflow: runic_workflow} = runic_workflow_with_single_step()
    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)
    execution = execution_fixture(scope, workflow, input: %{foo: "bar"})

    assert {:ok, %Execution{status: :completed} = finished} =
             ExecutionWorker.perform(%Oban.Job{args: %{"execution_id" => execution.id}})

    assert finished.output[:productions] |> Enum.count() == 1
    assert finished.current_generation == finished.output[:generation]
  end

  test "perform/1 handles invalid arguments and statuses", %{scope: scope} do
    assert {:discard, :invalid_args} = ExecutionWorker.perform(%Oban.Job{args: %{}})

    %{workflow: runic_workflow} = runic_workflow_with_single_step()
    workflow = published_workflow_from_runic_fixture(scope, runic_workflow)
    execution = completed_execution_fixture(scope, workflow)

    assert {:error, {:invalid_status_for_start, :completed}} =
             ExecutionWorker.perform(%Oban.Job{args: %{"execution_id" => execution.id}})
  end
end

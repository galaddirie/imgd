defmodule Imgd.Workers.ExecutionWorkerTest do
  use Imgd.DataCase, async: false
  use Oban.Testing, repo: Imgd.Repo

  import Imgd.Factory
  alias Imgd.Executions.Execution
  alias Imgd.Workers.ExecutionWorker

  setup do
    workflow = insert(:workflow, status: :active, public: true)
    version = insert(:workflow_version, workflow: workflow)
    Imgd.Repo.update_all(Imgd.Workflows.Workflow, set: [published_version_id: version.id])

    %{workflow: workflow, version: version}
  end

  describe "maybe_schedule_next/1" do
    test "schedules next run for :schedule triggers", %{workflow: workflow} do
      # 1. Create a "completed" execution that just finished (triggered by schedule)
      execution =
        insert(:execution,
          workflow: workflow,
          # The logic checks for :pending + :schedule
          status: :pending,
          trigger: %Execution.Trigger{type: :schedule, data: %{"interval_seconds" => 60}}
        )

      # 2. Call the scheduling logic
      assert {:ok, _job} = ExecutionWorker.maybe_schedule_next(execution.id)

      # 3. Verify exactly one NEW execution was created for the next run
      next_executions = Repo.all(from e in Execution, where: e.id != ^execution.id)
      assert length(next_executions) == 1
      next_execution = List.first(next_executions)

      assert next_execution.workflow_id == workflow.id
      assert next_execution.trigger.type == :schedule
      assert next_execution.trigger.data["interval_seconds"] == 60

      # 4. Verify an Oban job was enqueued for the NEW execution
      assert_enqueued(
        worker: ExecutionWorker,
        args: %{"execution_id" => next_execution.id}
      )

      # 5. Check scheduled_at is roughly 60s from now
      [job] = all_enqueued(worker: ExecutionWorker, args: %{"execution_id" => next_execution.id})
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff >= 55 and diff <= 65
    end

    test "does nothing for non-schedule triggers", %{workflow: workflow} do
      execution =
        insert(:execution,
          workflow: workflow,
          trigger: %Execution.Trigger{type: :manual, data: %{}}
        )

      assert :ok = ExecutionWorker.maybe_schedule_next(execution.id)

      # No new executions should be created beyond the initial one
      assert Repo.aggregate(Execution, :count, :id) == 1
      refute_enqueued(worker: ExecutionWorker)
    end
  end
end

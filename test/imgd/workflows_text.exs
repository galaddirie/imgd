defmodule Imgd.WorkflowsTest do
  use Imgd.DataCase

  alias Imgd.Engine.DataFlow
  alias Imgd.Workflows
  alias Imgd.Workflows.{Workflow, Execution}

  import Imgd.AccountsFixtures
  import Imgd.WorkflowsFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope}
  end

  # ============================================================================
  # Workflows
  # ============================================================================

  describe "list_workflows/2" do
    test "returns all workflows for the scoped user", %{scope: scope} do
      workflow = workflow_fixture(scope)
      assert [found] = Workflows.list_workflows(scope)
      assert found.id == workflow.id
    end

    test "does not return workflows from other users", %{scope: scope} do
      other_scope = user_scope_fixture()
      _other_workflow = workflow_fixture(other_scope)
      workflow = workflow_fixture(scope)

      assert [found] = Workflows.list_workflows(scope)
      assert found.id == workflow.id
    end

    test "filters by status", %{scope: scope} do
      _draft = workflow_fixture(scope, %{name: "draft"})
      published = published_workflow_fixture(scope, %{name: "published"})

      assert [found] = Workflows.list_workflows(scope, status: :published)
      assert found.id == published.id
    end

    test "limits results", %{scope: scope} do
      for i <- 1..5, do: workflow_fixture(scope, %{name: "workflow-#{i}"})

      assert length(Workflows.list_workflows(scope, limit: 3)) == 3
    end

    test "orders by updated_at descending", %{scope: scope} do
      w1 = workflow_fixture(scope, %{name: "first"})
      w2 = workflow_fixture(scope, %{name: "second"})

      [first, second] = Workflows.list_workflows(scope)
      assert first.id == w2.id
      assert second.id == w1.id
    end
  end

  describe "get_workflow!/2" do
    test "returns the workflow with given id", %{scope: scope} do
      workflow = workflow_fixture(scope)
      assert Workflows.get_workflow!(scope, workflow.id).id == workflow.id
    end

    test "raises if workflow does not exist", %{scope: scope} do
      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(scope, Ecto.UUID.generate())
      end
    end

    test "raises if workflow belongs to another user", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = workflow_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(scope, workflow.id)
      end
    end
  end

  describe "get_workflow/2" do
    test "returns the workflow with given id", %{scope: scope} do
      workflow = workflow_fixture(scope)
      assert Workflows.get_workflow(scope, workflow.id).id == workflow.id
    end

    test "returns nil if workflow does not exist", %{scope: scope} do
      assert Workflows.get_workflow(scope, Ecto.UUID.generate()) == nil
    end

    test "returns nil if workflow belongs to another user", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = workflow_fixture(other_scope)

      assert Workflows.get_workflow(scope, workflow.id) == nil
    end
  end

  describe "create_workflow/2" do
    test "creates a workflow with valid data", %{scope: scope} do
      attrs = valid_workflow_attributes(%{name: "my-workflow"})
      assert {:ok, %Workflow{} = workflow} = Workflows.create_workflow(scope, attrs)

      assert workflow.name == "my-workflow"
      assert workflow.status == :draft
      assert workflow.version == 1
      assert workflow.user_id == scope.user.id
    end

    test "returns error changeset with invalid data", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Workflows.create_workflow(scope, %{name: nil})
    end

    test "validates name length", %{scope: scope} do
      long_name = String.duplicate("a", 256)
      attrs = valid_workflow_attributes(%{name: long_name})

      assert {:error, changeset} = Workflows.create_workflow(scope, attrs)
      assert "should be at most 255 character(s)" in errors_on(changeset).name
    end
  end

  describe "update_workflow/3" do
    test "updates the workflow with valid data", %{scope: scope} do
      workflow = workflow_fixture(scope)
      attrs = %{name: "updated-name", description: "Updated description"}

      assert {:ok, %Workflow{} = updated} = Workflows.update_workflow(scope, workflow, attrs)
      assert updated.name == "updated-name"
      assert updated.description == "Updated description"
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = workflow_fixture(other_scope)

      assert {:error, :unauthorized} =
               Workflows.update_workflow(scope, workflow, %{name: "hacked"})
    end

    test "returns error changeset with invalid data", %{scope: scope} do
      workflow = workflow_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               Workflows.update_workflow(scope, workflow, %{name: nil})
    end
  end

  describe "publish_workflow/3" do
    test "publishes a workflow and creates a version", %{scope: scope} do
      workflow = workflow_fixture(scope)
      definition = valid_workflow_definition()

      assert {:ok, %Workflow{} = published} =
               Workflows.publish_workflow(scope, workflow, %{definition: definition})

      assert published.status == :published
      assert published.version == 2
      assert published.published_at != nil

      # Verify version was created
      versions = Workflows.list_workflow_versions(scope, published)
      assert [version] = versions
      assert version.version == 2
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = workflow_fixture(other_scope)

      assert {:error, :unauthorized} =
               Workflows.publish_workflow(scope, workflow, %{
                 definition: valid_workflow_definition()
               })
    end
  end

  describe "archive_workflow/2" do
    test "archives a published workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      assert {:ok, %Workflow{} = archived} = Workflows.archive_workflow(scope, workflow)
      assert archived.status == :archived
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)

      assert {:error, :unauthorized} = Workflows.archive_workflow(scope, workflow)
    end
  end

  describe "delete_workflow/2" do
    test "deletes a draft workflow with no executions", %{scope: scope} do
      workflow = workflow_fixture(scope)

      assert {:ok, %Workflow{}} = Workflows.delete_workflow(scope, workflow)
      assert Workflows.get_workflow(scope, workflow.id) == nil
    end

    test "returns error when trying to delete a published workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      assert {:error, :not_draft} = Workflows.delete_workflow(scope, workflow)
    end

    test "returns error when workflow has executions", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      _execution = execution_fixture(scope, workflow)

      # Reset to draft to test execution constraint
      workflow = %{workflow | status: :draft}

      assert {:error, :has_executions} = Workflows.delete_workflow(scope, workflow)
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = workflow_fixture(other_scope)

      assert {:error, :unauthorized} = Workflows.delete_workflow(scope, workflow)
    end
  end

  describe "change_workflow/2" do
    test "returns a changeset", %{scope: scope} do
      workflow = workflow_fixture(scope)
      assert %Ecto.Changeset{} = Workflows.change_workflow(workflow)
    end
  end

  # ============================================================================
  # Workflow Versions
  # ============================================================================

  describe "list_workflow_versions/2" do
    test "returns all versions for a workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      versions = Workflows.list_workflow_versions(scope, workflow)
      assert length(versions) == 1
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)

      assert {:error, :unauthorized} = Workflows.list_workflow_versions(scope, workflow)
    end
  end

  describe "get_workflow_version!/3" do
    test "returns a specific version", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      version = Workflows.get_workflow_version!(scope, workflow, 2)
      assert version.version == 2
    end
  end

  describe "get_latest_workflow_version/2" do
    test "returns the latest version", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      # Publish again to create version 3
      {:ok, workflow} =
        Workflows.publish_workflow(scope, workflow, %{definition: valid_workflow_definition()})

      version = Workflows.get_latest_workflow_version(scope, workflow)
      assert version.version == 3
    end

    test "returns nil for unpublished workflow", %{scope: scope} do
      workflow = workflow_fixture(scope)

      assert Workflows.get_latest_workflow_version(scope, workflow) == nil
    end
  end

  # ============================================================================
  # Executions
  # ============================================================================

  describe "list_executions/3" do
    test "returns executions for a workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert [found] = Workflows.list_executions(scope, workflow)
      assert found.id == execution.id
    end

    test "filters by status", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      _running = execution_fixture(scope, workflow)
      completed = completed_execution_fixture(scope, workflow)

      assert [found] = Workflows.list_executions(scope, workflow, status: :completed)
      assert found.id == completed.id
    end

    test "filters by multiple statuses", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      running = execution_fixture(scope, workflow)
      completed = completed_execution_fixture(scope, workflow)

      found = Workflows.list_executions(scope, workflow, status: [:running, :completed])

      assert length(found) == 2
      ids = Enum.map(found, & &1.id)
      assert running.id in ids
      assert completed.id in ids
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)

      assert {:error, :unauthorized} = Workflows.list_executions(scope, workflow)
    end
  end

  describe "list_recent_executions/2" do
    test "returns recent executions across all workflows", %{scope: scope} do
      w1 = published_workflow_fixture(scope, %{name: "workflow-1"})
      w2 = published_workflow_fixture(scope, %{name: "workflow-2"})

      e1 = execution_fixture(scope, w1)
      e2 = execution_fixture(scope, w2)

      executions = Workflows.list_recent_executions(scope)
      ids = Enum.map(executions, & &1.id)

      assert e1.id in ids
      assert e2.id in ids
    end

    test "does not return executions from other users", %{scope: scope} do
      other_scope = user_scope_fixture()
      other_workflow = published_workflow_fixture(other_scope)
      _other_execution = execution_fixture(other_scope, other_workflow)

      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      executions = Workflows.list_recent_executions(scope)
      ids = Enum.map(executions, & &1.id)

      assert execution.id in ids
      assert length(ids) == 1
    end
  end

  describe "get_execution!/2" do
    test "returns the execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      found = Workflows.get_execution!(scope, execution.id)
      assert found.id == execution.id
    end

    test "raises for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)
      execution = execution_fixture(other_scope, workflow)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_execution!(scope, execution.id)
      end
    end
  end

  describe "start_execution/3" do
    test "starts an execution for a published workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      assert {:ok, %Execution{} = execution} =
               Workflows.start_execution(scope, workflow,
                 input: %{key: "value"},
                 trigger_type: :manual
               )

      assert execution.status == :running
      assert execution.workflow_id == workflow.id
      assert execution.workflow_version == workflow.version
      assert DataFlow.unwrap(execution.input) == %{key: "value"}
      assert execution.metadata["trace_id"]
      assert execution.started_at != nil
      assert execution.expires_at != nil
    end

    test "returns error for unpublished workflow", %{scope: scope} do
      workflow = workflow_fixture(scope)

      assert {:error, :not_published} = Workflows.start_execution(scope, workflow)
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)

      assert {:error, :unauthorized} = Workflows.start_execution(scope, workflow)
    end
  end

  describe "complete_execution/3" do
    test "marks execution as completed", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = completed} =
               Workflows.complete_execution(scope, execution, %{result: "success"})

      assert completed.status == :completed
      assert completed.output == %{result: "success"}
      assert completed.completed_at != nil
    end

    test "returns error for unauthorized access", %{scope: scope} do
      other_scope = user_scope_fixture()
      workflow = published_workflow_fixture(other_scope)
      execution = execution_fixture(other_scope, workflow)

      assert {:error, :unauthorized} =
               Workflows.complete_execution(scope, execution, %{result: "hacked"})
    end
  end

  describe "fail_execution/3" do
    test "marks execution as failed", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = failed} =
               Workflows.fail_execution(scope, execution, %{
                 type: "RuntimeError",
                 message: "Something went wrong"
               })

      assert failed.status == :failed
      assert failed.error.type == "RuntimeError"
      assert failed.completed_at != nil
    end
  end

  describe "pause_execution/2" do
    test "pauses a running execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = paused} = Workflows.pause_execution(scope, execution)
      assert paused.status == :paused
    end

    test "returns error for non-running execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = completed_execution_fixture(scope, workflow)

      assert {:error, :not_running} = Workflows.pause_execution(scope, execution)
    end
  end

  describe "resume_execution/2" do
    test "resumes a paused execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = paused_execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = resumed} = Workflows.resume_execution(scope, execution)
      assert resumed.status == :running
    end

    test "resumes a failed execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = failed_execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = resumed} = Workflows.resume_execution(scope, execution)
      assert resumed.status == :running
    end

    test "returns error for non-resumable execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = completed_execution_fixture(scope, workflow)

      assert {:error, :not_resumable} = Workflows.resume_execution(scope, execution)
    end
  end

  describe "cancel_execution/2" do
    test "cancels a running execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert {:ok, %Execution{} = cancelled} = Workflows.cancel_execution(scope, execution)
      assert cancelled.status == :cancelled
      assert cancelled.completed_at != nil
    end

    test "returns error for terminal execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = completed_execution_fixture(scope, workflow)

      assert {:error, :already_terminal} = Workflows.cancel_execution(scope, execution)
    end
  end

  describe "update_execution_generation/2" do
    test "updates the current generation", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      assert {:ok, updated} = Workflows.update_execution_generation(execution, 3)
      assert updated.current_generation == 3
    end
  end

  # ============================================================================
  # Execution Steps
  # ============================================================================

  describe "list_execution_steps/3" do
    test "returns steps for an execution", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      assert [found] = Workflows.list_execution_steps(scope, execution)
      assert found.id == step.id
    end

    test "filters by status", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      _pending = execution_step_fixture(execution)
      completed = completed_step_fixture(execution)

      assert [found] = Workflows.list_execution_steps(scope, execution, status: :completed)
      assert found.id == completed.id
    end

    test "filters by generation", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      _gen0 = execution_step_fixture(execution, %{generation: 0})
      gen1 = execution_step_fixture(execution, %{generation: 1})

      assert [found] = Workflows.list_execution_steps(scope, execution, generation: 1)
      assert found.id == gen1.id
    end
  end

  describe "get_execution_step!/3" do
    test "returns the step", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      found = Workflows.get_execution_step!(scope, execution, step.id)
      assert found.id == step.id
    end
  end

  describe "start_step/1" do
    test "marks step as running", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      assert {:ok, started} = Workflows.start_step(step)
      assert started.status == :running
      assert started.started_at != nil
    end
  end

  describe "complete_step/3" do
    test "marks step as completed", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)
      {:ok, step} = Workflows.start_step(step)

      output_fact = %{hash: 12345, value: "result"}

      assert {:ok, completed} = Workflows.complete_step(step, output_fact, 150)
      assert completed.status == :completed
      assert completed.output_fact_hash == 12345
      assert completed.duration_ms == 150
      assert completed.completed_at != nil
    end
  end

  describe "fail_step/3" do
    test "marks step as failed", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)
      {:ok, step} = Workflows.start_step(step)

      assert {:ok, failed} =
               Workflows.fail_step(step, %{type: "Error", message: "Failed"}, 50)

      assert failed.status == :failed
      assert failed.error.type == "Error"
      assert failed.duration_ms == 50
    end
  end

  describe "skip_step/2" do
    test "marks step as skipped", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      assert {:ok, skipped} = Workflows.skip_step(step, "Condition not met")
      assert skipped.status == :skipped
      assert skipped.error.message == "Condition not met"
    end
  end

  describe "schedule_step_retry/2" do
    test "schedules step for retry", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      next_retry = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, retrying} = Workflows.schedule_step_retry(step, next_retry)
      assert retrying.status == :retrying
      assert retrying.next_retry_at == next_retry
    end
  end

  describe "append_step_logs/2" do
    test "appends logs to step", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      step = execution_step_fixture(execution)

      assert {:ok, step} = Workflows.append_step_logs(step, "Line 1\n")
      assert {:ok, step} = Workflows.append_step_logs(step, "Line 2\n")
      assert step.logs == "Line 1\nLine 2\n"
    end
  end

  describe "get_failed_steps/1" do
    test "returns failed steps", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)
      _pending = execution_step_fixture(execution)
      failed = failed_step_fixture(execution)

      found = Workflows.get_failed_steps(execution)
      assert length(found) == 1
      assert hd(found).id == failed.id
    end
  end

  describe "get_slowest_steps/2" do
    test "returns slowest steps ordered by duration", %{scope: scope} do
      workflow = published_workflow_fixture(scope)
      execution = execution_fixture(scope, workflow)

      s1 = execution_step_fixture(execution, %{step_name: "fast"})
      {:ok, s1} = Workflows.start_step(s1)
      {:ok, _} = Workflows.complete_step(s1, %{hash: 1, value: "a"}, 50)

      s2 = execution_step_fixture(execution, %{step_name: "slow"})
      {:ok, s2} = Workflows.start_step(s2)
      {:ok, _} = Workflows.complete_step(s2, %{hash: 2, value: "b"}, 500)

      [slowest | _] = Workflows.get_slowest_steps(execution, 2)
      assert slowest.step_name == "slow"
      assert slowest.duration_ms == 500
    end
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  describe "get_workflow_stats/2" do
    test "returns execution statistics for a workflow", %{scope: scope} do
      workflow = published_workflow_fixture(scope)

      _running = execution_fixture(scope, workflow)
      _completed = completed_execution_fixture(scope, workflow)
      _failed = failed_execution_fixture(scope, workflow)

      assert {:ok, stats} = Workflows.get_workflow_stats(scope, workflow)
      assert stats.total == 3
      assert stats.running == 1
      assert stats.completed == 1
      assert stats.failed == 1
    end
  end

  describe "count_active_executions/1" do
    test "counts active executions for user", %{scope: scope} do
      w1 = published_workflow_fixture(scope, %{name: "w1"})
      w2 = published_workflow_fixture(scope, %{name: "w2"})

      _running1 = execution_fixture(scope, w1)
      _running2 = execution_fixture(scope, w2)
      _paused = paused_execution_fixture(scope, w1)
      _completed = completed_execution_fixture(scope, w1)

      assert Workflows.count_active_executions(scope) == 3
    end

    test "does not count other users' executions", %{scope: scope} do
      other_scope = user_scope_fixture()
      other_workflow = published_workflow_fixture(other_scope)
      _other_execution = execution_fixture(other_scope, other_workflow)

      workflow = published_workflow_fixture(scope)
      _execution = execution_fixture(scope, workflow)

      assert Workflows.count_active_executions(scope) == 1
    end
  end
end

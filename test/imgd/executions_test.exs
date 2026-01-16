defmodule Imgd.ExecutionsTest do
  use Imgd.DataCase, async: true

  alias Imgd.Executions
  alias Imgd.Executions.Execution
  alias Imgd.Executions.StepExecution
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope
  alias Imgd.Repo

  describe "execution CRUD operations" do
    setup do
      # Create users and workflow
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

      # Create and publish a version
      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

      {:ok, {_workflow, version}} =
        Workflows.publish_workflow(scope, workflow, %{version_tag: "1.0.0"})

      %{scope: scope, workflow: workflow, version: version}
    end

    test "create_execution/2 creates a new execution", %{
      scope: scope,
      workflow: workflow,
      version: _version
    } do
      execution_attrs = %{
        workflow_id: workflow.id,
        trigger: %{type: :manual, data: %{reason: "test"}},
        execution_type: :production,
        metadata: %{trace_id: "trace-123", correlation_id: "corr-456"}
      }

      assert {:ok, execution} = Executions.create_execution(scope, execution_attrs)
      assert execution.workflow_id == workflow.id
      assert execution.workflow_id == workflow.id
      assert execution.status == :pending
      assert execution.execution_type == :production
      assert execution.trigger.type == :manual
      assert execution.triggered_by_user_id == scope.user.id
      assert execution.metadata.trace_id == "trace-123"
    end

    test "create_execution/2 fails when workflow not found", %{scope: scope} do
      execution_attrs = %{
        workflow_id: Ecto.UUID.generate(),
        trigger: %{type: :manual, data: %{}}
      }

      assert {:error, :workflow_not_found} = Executions.create_execution(scope, execution_attrs)
    end

    test "create_execution/2 fails when workflow not published", %{scope: scope} do
      # Create unpublished workflow
      {:ok, unpublished_workflow} = Workflows.create_workflow(scope, %{name: "Unpublished"})

      execution_attrs = %{
        workflow_id: unpublished_workflow.id,
        trigger: %{type: :manual, data: %{}}
      }

      assert {:error, :workflow_not_published} =
               Executions.create_execution(scope, execution_attrs)
    end

    test "create_execution/2 allows preview execution on draft workflow for editors", %{
      scope: scope
    } do
      {:ok, draft_workflow} = Workflows.create_workflow(scope, %{name: "Draft Preview"})

      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft} = Workflows.update_workflow_draft(scope, draft_workflow, draft_attrs)

      execution_attrs = %{
        workflow_id: draft_workflow.id,
        trigger: %{type: :manual, data: %{}},
        execution_type: :preview
      }

      assert {:ok, execution} = Executions.create_execution(scope, execution_attrs)
      assert execution.workflow_id == draft_workflow.id
      assert execution.execution_type == :preview
    end

    test "create_execution/2 fails when user lacks access", %{workflow: workflow} do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      execution_attrs = %{
        workflow_id: workflow.id,
        trigger: %{type: :manual, data: %{}}
      }

      assert {:error, :access_denied} = Executions.create_execution(other_scope, execution_attrs)
    end

    test "get_execution/2 returns execution for user with access", %{
      scope: scope,
      workflow: workflow,
      version: version
    } do
      # Create execution
      {:ok, execution} = create_test_execution(workflow, version, scope)

      assert {:ok, fetched} = Executions.get_execution(scope, execution.id)
      assert fetched.id == execution.id
      assert fetched.workflow_id == workflow.id
    end

    test "get_execution/2 returns execution with preloaded associations", %{
      scope: scope,
      workflow: workflow,
      version: version
    } do
      {:ok, execution} = create_test_execution(workflow, version, scope)

      assert {:ok, fetched} = Executions.get_execution_with_steps(scope, execution.id)
      assert fetched.workflow.id == workflow.id
      assert fetched.triggered_by_user.id == scope.user.id
    end

    test "get_execution/2 returns error for non-existent execution", %{scope: scope} do
      assert {:error, :not_found} = Executions.get_execution(scope, Ecto.UUID.generate())
    end

    test "get_execution/2 returns error when user lacks access", %{
      workflow: workflow,
      version: version,
      scope: scope
    } do
      # Create execution
      {:ok, execution} = create_test_execution(workflow, version, scope)

      # Try to access with different user
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert {:error, :not_found} = Executions.get_execution(other_scope, execution.id)
    end
  end

  describe "execution status management" do
    setup do
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

      # Create and publish a version
      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

      {:ok, {_workflow, version}} =
        Workflows.publish_workflow(scope, workflow, %{version_tag: "1.0.0"})

      {:ok, execution} = create_test_execution(workflow, version, scope)

      %{scope: scope, workflow: workflow, execution: execution}
    end

    test "update_execution_status/4 updates status to running", %{
      scope: scope,
      execution: execution
    } do
      assert {:ok, updated} = Executions.update_execution_status(scope, execution, :running)
      assert updated.status == :running
      assert updated.started_at != nil
    end

    test "update_execution_status/4 updates status to completed", %{
      scope: scope,
      execution: execution
    } do
      output = %{"result" => "success"}

      assert {:ok, updated} =
               Executions.update_execution_status(scope, execution, :completed, output: output)

      assert updated.status == :completed
      assert updated.completed_at != nil
      assert updated.output == output
    end

    test "update_execution_status/4 updates status to failed with error", %{
      scope: scope,
      execution: execution
    } do
      error = {:step_failed, "step1", "connection timeout"}

      assert {:ok, updated} =
               Executions.update_execution_status(scope, execution, :failed, error: error)

      assert updated.status == :failed
      assert updated.completed_at != nil
      assert updated.error == Execution.format_error(error)
    end

    test "update_execution_status/4 fails when user lacks access", %{execution: execution} do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert {:error, :access_denied} =
               Executions.update_execution_status(other_scope, execution, :running)
    end

    test "cancel_execution/2 cancels running execution", %{scope: scope, execution: execution} do
      # Start execution
      {:ok, running} = Executions.update_execution_status(scope, execution, :running)

      # Cancel it
      assert {:ok, cancelled} = Executions.cancel_execution(scope, running)
      assert cancelled.status == :cancelled
      assert cancelled.completed_at != nil
    end

    test "cancel_execution/2 fails for already completed execution", %{
      scope: scope,
      execution: execution
    } do
      # Complete execution
      {:ok, completed} = Executions.update_execution_status(scope, execution, :completed)

      # Try to cancel
      assert {:error, :already_terminal} = Executions.cancel_execution(scope, completed)
    end
  end

  describe "step execution management" do
    setup do
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

      # Create and publish a version
      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft} = Workflows.update_workflow_draft(scope, workflow, draft_attrs)

      {:ok, {_workflow, version}} =
        Workflows.publish_workflow(scope, workflow, %{version_tag: "1.0.0"})

      {:ok, execution} = create_test_execution(workflow, version, scope)

      %{scope: scope, workflow: workflow, execution: execution}
    end

    test "create_step_execution/2 creates a new step execution", %{
      scope: scope,
      execution: execution
    } do
      step_attrs = %{
        execution_id: execution.id,
        step_id: "step1",
        step_type_id: "input_step",
        input_data: %{"value" => 42},
        metadata: %{"priority" => "high"}
      }

      assert {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)
      assert step_execution.execution_id == execution.id
      assert step_execution.step_id == "step1"
      assert step_execution.step_type_id == "input_step"
      assert step_execution.status == :pending
      assert step_execution.input_data == %{"value" => 42}
      assert step_execution.metadata == %{"priority" => "high"}
    end

    test "create_step_execution/2 fails when execution not found", %{scope: scope} do
      step_attrs = %{
        execution_id: Ecto.UUID.generate(),
        step_id: "step1",
        step_type_id: "input_step"
      }

      assert {:error, :execution_not_found} = Executions.create_step_execution(scope, step_attrs)
    end

    test "create_step_execution/2 fails when user lacks access", %{execution: execution} do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      step_attrs = %{
        execution_id: execution.id,
        step_id: "step1",
        step_type_id: "input_step"
      }

      assert {:error, :access_denied} = Executions.create_step_execution(other_scope, step_attrs)
    end

    test "update_step_execution_status/4 updates status through lifecycle", %{
      scope: scope,
      execution: execution
    } do
      # Create step execution
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)

      # Queue it
      assert {:ok, queued} =
               Executions.update_step_execution_status(scope, step_execution, :queued)

      assert queued.status == :queued
      assert queued.queued_at != nil

      # Start it
      assert {:ok, running} = Executions.update_step_execution_status(scope, queued, :running)
      assert running.status == :running
      assert running.started_at != nil

      # Complete it
      output_data = %{"result" => "success"}

      assert {:ok, completed} =
               Executions.update_step_execution_status(scope, running, :completed,
                 output_data: output_data,
                 output_item_count: 5
               )

      assert completed.status == :completed
      assert completed.completed_at != nil
      assert completed.output_data == output_data
      assert completed.output_item_count == 5
    end

    test "update_step_execution_status/4 persists output_item_count", %{
      scope: scope,
      execution: execution
    } do
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)
      {:ok, running} = Executions.update_step_execution_status(scope, step_execution, :running)

      # complete with item count
      {:ok, completed} =
        Executions.update_step_execution_status(scope, running, :completed,
          output_data: %{},
          output_item_count: 10
        )

      assert completed.output_item_count == 10

      # verify DB
      assert Repo.get(Executions.StepExecution, step_execution.id).output_item_count == 10
    end

    test "update_step_execution_status/4 handles failed status with error", %{
      scope: scope,
      execution: execution
    } do
      # Create and start step execution
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)
      {:ok, running} = Executions.update_step_execution_status(scope, step_execution, :running)

      # Fail it
      error = %{"type" => "timeout", "message" => "Connection timed out"}

      assert {:ok, failed} =
               Executions.update_step_execution_status(scope, running, :failed, error: error)

      assert failed.status == :failed
      assert failed.completed_at != nil
      assert failed.error == error
    end

    test "update_step_execution_status/4 fails when user lacks access", %{
      scope: scope,
      execution: execution
    } do
      # Create step execution
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)

      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert {:error, :access_denied} =
               Executions.update_step_execution_status(other_scope, step_execution, :running)
    end

    test "retry_step_execution/2 creates a retry step execution", %{
      scope: scope,
      execution: execution
    } do
      # Create and fail original step execution
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)
      {:ok, failed} = Executions.update_step_execution_status(scope, step_execution, :failed)

      # Retry it
      assert {:ok, retry} = Executions.retry_step_execution(scope, failed)
      assert retry.execution_id == execution.id
      assert retry.step_id == "step1"
      assert retry.step_type_id == "input_step"
      assert retry.attempt == 2
      assert retry.retry_of_id == failed.id
      assert retry.input_data == failed.input_data
    end

    test "retry_step_execution/2 fails when user lacks access", %{
      scope: scope,
      execution: execution
    } do
      # Create step execution
      step_attrs = %{execution_id: execution.id, step_id: "step1", step_type_id: "input_step"}
      {:ok, step_execution} = Executions.create_step_execution(scope, step_attrs)

      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert {:error, :access_denied} =
               Executions.retry_step_execution(other_scope, step_execution)
    end

    test "list_step_executions/2 returns step executions for accessible execution", %{
      scope: scope,
      execution: execution
    } do
      # Create multiple step executions
      {:ok, _step1} =
        Executions.create_step_execution(
          scope,
          %{execution_id: execution.id, step_id: "step1", step_type_id: "input"}
        )

      {:ok, _step2} =
        Executions.create_step_execution(
          scope,
          %{execution_id: execution.id, step_id: "step2", step_type_id: "output"}
        )

      step_executions = Executions.list_step_executions(scope, execution)
      assert length(step_executions) == 2

      step_ids = Enum.map(step_executions, & &1.step_id) |> Enum.sort()
      assert step_ids == ["step1", "step2"]
    end

    test "list_step_executions/2 returns empty list when user lacks access", %{
      execution: execution
    } do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert Executions.list_step_executions(other_scope, execution) == []
    end

    test "get_step_execution/2 returns step execution for user with access", %{
      scope: scope,
      execution: execution
    } do
      {:ok, step_execution} =
        Executions.create_step_execution(
          scope,
          %{execution_id: execution.id, step_id: "step1", step_type_id: "input"}
        )

      assert {:ok, fetched} = Executions.get_step_execution(scope, step_execution.id)
      assert fetched.id == step_execution.id
      assert fetched.execution.workflow_id == execution.workflow_id
    end

    test "get_step_execution/2 returns error when user lacks access", %{
      scope: scope,
      execution: execution
    } do
      {:ok, step_execution} =
        Executions.create_step_execution(
          scope,
          %{execution_id: execution.id, step_id: "step1", step_type_id: "input"}
        )

      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert {:error, :not_found} = Executions.get_step_execution(other_scope, step_execution.id)
    end

    test "cancel_active_step_executions/1 cancels all non-terminal steps and broadcasts", %{
      scope: scope,
      execution: execution
    } do
      # Subscribe to broadcasts
      Imgd.Executions.PubSub.subscribe_execution(scope, execution.id)

      # Create steps in various states
      {:ok, running} =
        Executions.create_step_execution(scope, %{
          execution_id: execution.id,
          step_id: "step1",
          step_type_id: "type1",
          status: :running
        })

      {:ok, queued} =
        Executions.create_step_execution(scope, %{
          execution_id: execution.id,
          step_id: "step2",
          step_type_id: "type1",
          status: :queued
        })

      {:ok, pending} =
        Executions.create_step_execution(scope, %{
          execution_id: execution.id,
          step_id: "step3",
          step_type_id: "type1",
          status: :pending
        })

      # Create a terminal step that should NOT be touched
      {:ok, completed} =
        Executions.create_step_execution(scope, %{
          execution_id: execution.id,
          step_id: "terminal",
          step_type_id: "type1",
          status: :completed
        })

      # Run cancellation
      assert {3, nil} = Executions.cancel_active_step_executions(execution.id)

      # Verify database state (need to refresh or get from DB)
      assert Repo.get(Executions.StepExecution, running.id).status == :cancelled
      assert Repo.get(Executions.StepExecution, queued.id).status == :cancelled
      assert Repo.get(Executions.StepExecution, pending.id).status == :cancelled
      assert Repo.get(Executions.StepExecution, completed.id).status == :completed

      # Verify broadcasts
      assert_receive {:step_cancelled, %{step_id: "step1", status: :cancelled}}
      assert_receive {:step_cancelled, %{step_id: "step2", status: :cancelled}}
      assert_receive {:step_cancelled, %{step_id: "step3", status: :cancelled}}
      refute_receive {:step_cancelled, %{step_id: "terminal"}}
    end
  end

  describe "step execution batching" do
    setup do
      execution = insert(:execution)
      %{execution: execution}
    end

    test "record_step_executions_batch/1 persists failed over running", %{execution: execution} do
      started_at =
        DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:microsecond)

      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      error = Execution.format_error({:step_failed, "step-1", :boom})

      events = [
        %{
          execution_id: execution.id,
          step_id: "step-1",
          step_type_id: "debug",
          status: :running,
          input_data: %{"value" => 1},
          started_at: started_at
        },
        %{
          execution_id: execution.id,
          step_id: "step-1",
          status: :failed,
          error: error,
          completed_at: completed_at
        }
      ]

      assert {:ok, _count} = Executions.record_step_executions_batch(Enum.reverse(events))

      step_execution =
        Repo.get_by(StepExecution, execution_id: execution.id, step_id: "step-1")

      assert step_execution.status == :failed
      assert step_execution.input_data == %{"value" => 1}
      assert step_execution.completed_at == completed_at
    end

    test "record_step_executions_batch/1 ignores stale running after failure", %{
      execution: execution
    } do
      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      error = Execution.format_error({:step_failed, "step-2", :boom})

      failed =
        %StepExecution{}
        |> StepExecution.changeset(%{
          execution_id: execution.id,
          step_id: "step-2",
          step_type_id: "debug",
          status: :failed,
          error: error,
          completed_at: completed_at
        })
        |> Repo.insert!()

      running_event = %{
        execution_id: execution.id,
        step_id: "step-2",
        step_type_id: "debug",
        status: :running,
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      assert {:ok, _count} = Executions.record_step_executions_batch([running_event])

      reloaded = Repo.get(StepExecution, failed.id)
      assert reloaded.status == :failed
      assert reloaded.completed_at == completed_at
    end
  end

  describe "execution listing and analytics" do
    setup do
      # Create users
      {:ok, user1} =
        Accounts.register_user(%{email: "user1@example.com", password: "password123"})

      {:ok, user2} =
        Accounts.register_user(%{email: "user2@example.com", password: "password123"})

      scope1 = Scope.for_user(user1)
      scope2 = Scope.for_user(user2)

      # Create workflows
      {:ok, workflow1} = Workflows.create_workflow(scope1, %{name: "Workflow 1"})
      {:ok, workflow2} = Workflows.create_workflow(scope2, %{name: "Workflow 2"})

      # Publish versions
      draft_attrs = %{
        steps: [%{id: "step1", type_id: "input", name: "Input Step", config: %{}}],
        connections: []
      }

      {:ok, _draft1} = Workflows.update_workflow_draft(scope1, workflow1, draft_attrs)
      {:ok, _draft2} = Workflows.update_workflow_draft(scope2, workflow2, draft_attrs)

      {:ok, {_w1, version1}} =
        Workflows.publish_workflow(scope1, workflow1, %{version_tag: "1.0.0"})

      {:ok, {_w2, version2}} =
        Workflows.publish_workflow(scope2, workflow2, %{version_tag: "1.0.0"})

      # Create executions with different statuses
      {:ok, exec1} = create_test_execution(workflow1, version1, scope1, :pending)
      {:ok, exec2} = create_test_execution(workflow1, version1, scope1, :running)
      {:ok, exec3} = create_test_execution(workflow1, version1, scope1, :completed)
      {:ok, exec4} = create_test_execution(workflow2, version2, scope2, :failed)

      %{scope1: scope1, scope2: scope2, executions: [exec1, exec2, exec3, exec4]}
    end

    test "list_executions/1 returns executions for user", %{
      scope1: scope1,
      executions: _executions
    } do
      # User1 should see their executions (first 3)
      user1_executions = Executions.list_executions(scope1)
      assert length(user1_executions) == 3

      workflow_ids = Enum.map(user1_executions, & &1.workflow_id) |> Enum.uniq()
      # All from workflow1
      assert length(workflow_ids) == 1
    end

    test "list_executions/1 returns empty list for nil scope" do
      assert Executions.list_executions(nil) == []
    end

    test "list_workflow_executions/3 returns executions for accessible workflow", %{
      scope1: scope1,
      scope2: _scope2
    } do
      # Get user1's workflow
      user1 = Accounts.get_user_by_email("user1@example.com")
      [workflow] = Imgd.Workflows.list_owned_workflows(Scope.for_user(user1))

      executions = Executions.list_workflow_executions(scope1, workflow)
      assert length(executions) == 3
    end

    test "list_workflow_executions/3 respects limit", %{scope1: scope1, scope2: _scope2} do
      user1 = Accounts.get_user_by_email("user1@example.com")
      [workflow] = Imgd.Workflows.list_owned_workflows(Scope.for_user(user1))

      executions = Executions.list_workflow_executions(scope1, workflow, limit: 2)
      assert length(executions) == 2
    end

    test "count_executions_by_status/1 returns status counts", %{scope1: scope1} do
      counts = Executions.count_executions_by_status(scope1)
      assert counts[:pending] == 1
      assert counts[:running] == 1
      assert counts[:completed] == 1
    end

    test "get_execution_stats/2 returns daily execution counts", %{scope1: scope1} do
      # Create an execution from yesterday
      yesterday = Date.add(Date.utc_today(), -1)
      user1 = Accounts.get_user_by_email("user1@example.com")
      [workflow] = Imgd.Workflows.list_owned_workflows(Scope.for_user(user1))

      # Get version
      versions = Workflows.list_workflow_versions(scope1, workflow)
      version = hd(versions)

      # Create execution with yesterday's date
      yesterday_execution_attrs = %{
        workflow_id: workflow.id,
        workflow_version_id: version.id,
        trigger: %{type: :manual, data: %{}},
        inserted_at: DateTime.new!(yesterday, ~T[12:00:00], "Etc/UTC")
      }

      %Execution{}
      |> Execution.changeset(yesterday_execution_attrs)
      |> Repo.insert()

      stats = Executions.get_execution_stats(scope1, 7)
      # At least today's stats
      assert length(stats) >= 1

      # Find today's stats
      today_stats = Enum.find(stats, &(&1.date == Date.utc_today()))
      # The original executions
      assert today_stats.count >= 3

      # Find yesterday's stats (if any)
      yesterday_stats = Enum.find(stats, &(&1.date == yesterday))
      if yesterday_stats, do: assert(yesterday_stats.count >= 1)
    end
  end

  # Helper functions

  defp create_test_execution(workflow, version, scope, status \\ :pending) do
    execution_attrs = %{
      workflow_id: workflow.id,
      workflow_version_id: version.id,
      trigger: %{type: :manual, config: %{reason: "test"}},
      execution_type: :production,
      status: status,
      triggered_by_user_id: scope.user.id
    }

    %Execution{}
    |> Execution.changeset(execution_attrs)
    |> Repo.insert()
  end
end

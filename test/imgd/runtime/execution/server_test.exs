defmodule Imgd.Runtime.Execution.ServerTest do
  use Imgd.DataCase, async: false

  alias Imgd.Repo
  alias Imgd.Executions.Execution
  alias Imgd.Runtime.Execution.Server
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Connection, Step}

  setup do
    ensure_execution_registry_started()
    :ok
  end

  test "completes a workflow execution and persists runic results" do
    workflow = insert(:workflow)

    steps = [
      %Step{id: "step_1", type_id: "debug", name: "Debug 1", config: %{}},
      %Step{id: "step_2", type_id: "debug", name: "Debug 2", config: %{}}
    ]

    connections = [
      %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
    ]

    insert_draft(workflow, steps, connections)

    execution =
      insert_execution(workflow,
        status: :pending,
        trigger_data: %{"value" => 1},
        metadata: %{trace_id: "trace-1"}
      )

    {:ok, pid} = start_supervised({Server, execution_id: execution.id})
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    execution = Repo.get!(Execution, execution.id)
    assert execution.status == :completed
    assert execution.started_at
    assert execution.completed_at
    assert execution.context["step_1"] == %{"value" => 1}
    assert execution.context["step_2"] == %{"value" => 1}
  end

  test "marks execution as failed when a step raises an expression error" do
    workflow = insert(:workflow)

    steps = [
      %Step{
        id: "step_1",
        type_id: "debug",
        name: "Debug 1",
        config: %{"label" => "{{ json.value | missing_filter }}"}
      }
    ]

    insert_draft(workflow, steps, [])

    execution =
      insert_execution(workflow,
        status: :pending,
        trigger_data: %{"value" => 1},
        metadata: %{"trace_id" => "trace-1"}
      )

    {:ok, pid} = start_supervised({Server, execution_id: execution.id})
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    execution = Repo.get!(Execution, execution.id)
    assert execution.status == :failed
    assert execution.error["type"] == "step_failure"
    assert execution.error["step_id"] == "step_1"
    assert execution.completed_at
  end

  test "cancelling an execution terminates the process and updates status" do
    workflow = insert(:workflow)

    steps = [
      %Step{
        id: "wait_1",
        type_id: "wait",
        name: "Wait 1",
        config: %{"duration" => 2000, "unit" => "milliseconds"}
      }
    ]

    insert_draft(workflow, steps, [])

    execution =
      insert_execution(workflow,
        status: :pending,
        metadata: %{"trace_id" => "trace-cancel"}
      )

    {:ok, pid} = start_supervised({Server, execution_id: execution.id})
    ref = Process.monitor(pid)

    # Wait a bit for it to start running
    Process.sleep(100)

    execution = Repo.get!(Execution, execution.id)
    assert execution.status == :running

    # Cancel the execution
    workflow = Repo.get!(Imgd.Workflows.Workflow, workflow.id)
    user = Repo.get!(Imgd.Accounts.User, workflow.user_id)
    scope = Imgd.Accounts.Scope.for_user(user)
    {:ok, cancelled_execution} = Imgd.Executions.cancel_execution(scope, execution)
    assert cancelled_execution.status == :cancelled

    # Manually stop the process as the LiveView would
    try do
      GenServer.stop(pid, :shutdown)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

    # Verify execution status and step statuses
    execution = Repo.get!(Execution, execution.id)
    assert execution.status == :cancelled
    assert execution.completed_at

    # Verify active steps are cancelled
    step_executions = Imgd.Executions.list_step_executions(scope, execution)

    assert Enum.any?(step_executions, fn se ->
             se.step_id == "wait_1" && se.status == :cancelled
           end)
  end

  defp insert_draft(workflow, steps, connections) do
    %WorkflowDraft{
      workflow_id: workflow.id,
      steps: steps,
      connections: connections
    }
    |> Repo.insert!()
  end

  defp insert_execution(workflow, opts) do
    attrs = %{
      workflow_id: workflow.id,
      status: Keyword.fetch!(opts, :status),
      execution_type: :production,
      trigger: %{
        type: :manual,
        data: Keyword.get(opts, :trigger_data, %{})
      },
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %Execution{}
    |> Execution.changeset(attrs)
    |> Repo.insert!()
  end

  defp ensure_execution_registry_started do
    if Process.whereis(Imgd.Runtime.Execution.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: Imgd.Runtime.Execution.Registry})
    end
  end
end

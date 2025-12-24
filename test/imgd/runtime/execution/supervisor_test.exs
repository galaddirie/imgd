defmodule Imgd.Runtime.Execution.SupervisorTest do
  use Imgd.DataCase, async: false

  alias Imgd.Repo
  alias Imgd.Runtime.Execution.Supervisor, as: ExecutionSupervisor
  alias Imgd.Executions.Execution
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.Step

  setup do
    ensure_execution_registry_started()
    ensure_execution_supervisor_started()
    :ok
  end

  test "get_execution_pid/1 returns not_found for unknown execution" do
    assert {:error, :not_found} = ExecutionSupervisor.get_execution_pid("missing-id")
  end

  test "start_execution/1 registers a paused execution process" do
    workflow = insert(:workflow)
    insert_draft(workflow, [%Step{id: "step_1", type_id: "debug", name: "Debug", config: %{}}])

    execution =
      insert_execution(workflow,
        status: :paused,
        trigger_data: %{"value" => 1}
      )

    assert {:ok, pid} = ExecutionSupervisor.start_execution(execution.id)
    _ = :sys.get_state(pid)

    assert {:ok, ^pid} = ExecutionSupervisor.get_execution_pid(execution.id)

    GenServer.stop(pid)
  end

  defp insert_draft(workflow, steps) do
    %WorkflowDraft{
      workflow_id: workflow.id,
      steps: steps,
      connections: [],
      triggers: []
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
      metadata: %{}
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

  defp ensure_execution_supervisor_started do
    if Process.whereis(ExecutionSupervisor) == nil do
      start_supervised!({ExecutionSupervisor, []})
    end
  end
end

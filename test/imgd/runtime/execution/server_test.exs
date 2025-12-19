defmodule Imgd.Runtime.Execution.ServerTest do
  @moduledoc """
  Tests for the Execution Server.
  """
  use Imgd.DataCase, async: false

  alias Imgd.Runtime.Execution.Supervisor
  alias Imgd.Executions.Execution

  describe "start_link/1 with published workflow version" do
    test "execution transitions from pending to running with a published version" do
      # Create execution with a workflow version (published workflow)
      execution = insert(:execution)
      assert execution.status == :pending
      assert execution.workflow_version != nil

      # Start the execution process
      {:ok, pid} = Supervisor.start_execution(execution.id)
      ref = Process.monitor(pid)

      # Wait for completion
      receive do
        {:DOWN, ^ref, :process, _pid, reason} ->
          assert reason == :normal
      after
        5_000 -> flunk("Execution timed out")
      end

      # Reload and verify status changed
      updated = Repo.get!(Execution, execution.id)
      assert updated.status in [:completed, :failed]
      assert updated.started_at != nil
    end
  end

  describe "start_link/1 with draft workflow (nil workflow_version)" do
    test "execution transitions from pending to running without a published version" do
      # Create a workflow with nodes directly on it (draft mode)
      user = insert(:user)

      workflow =
        insert(:workflow,
          user: user,
          nodes: [
            %Imgd.Workflows.Embeds.Node{
              id: "debug_1",
              type_id: "debug",
              name: "Debug Node",
              config: %{label: "Test", level: "info"},
              position: %{x: 0, y: 0}
            }
          ],
          connections: []
        )

      # Create execution WITHOUT a workflow_version (draft execution)
      {:ok, execution} =
        Repo.insert(%Execution{
          status: :pending,
          workflow_id: workflow.id,
          workflow_version_id: nil,
          trigger: %{type: :manual, data: %{value: 42}},
          context: %{}
        })

      assert execution.workflow_version_id == nil

      # Start the execution process - this should NOT crash
      {:ok, pid} = Supervisor.start_execution(execution.id)
      ref = Process.monitor(pid)

      # Wait for completion
      receive do
        {:DOWN, ^ref, :process, _pid, reason} ->
          assert reason == :normal, "Expected normal exit, got: #{inspect(reason)}"
      after
        5_000 -> flunk("Execution timed out")
      end

      # Reload and verify status changed from pending
      updated = Repo.get!(Execution, execution.id)
      assert updated.status in [:completed, :failed]
      assert updated.started_at != nil
    end

    test "execution uses workflow nodes when workflow_version is nil" do
      user = insert(:user)

      # Create workflow with specific nodes
      workflow =
        insert(:workflow,
          user: user,
          nodes: [
            %Imgd.Workflows.Embeds.Node{
              id: "start_node",
              type_id: "debug",
              name: "Start",
              config: %{label: "Start", level: "info"},
              position: %{x: 0, y: 0}
            },
            %Imgd.Workflows.Embeds.Node{
              id: "end_node",
              type_id: "debug",
              name: "End",
              config: %{label: "End", level: "info"},
              position: %{x: 0, y: 100}
            }
          ],
          connections: [
            %Imgd.Workflows.Embeds.Connection{
              id: "conn_1",
              source_node_id: "start_node",
              target_node_id: "end_node",
              source_output: "main",
              target_input: "main"
            }
          ]
        )

      # Create execution without workflow_version
      {:ok, execution} =
        Repo.insert(%Execution{
          status: :pending,
          workflow_id: workflow.id,
          workflow_version_id: nil,
          trigger: %{type: :manual, data: %{}},
          context: %{}
        })

      # Start execution
      {:ok, pid} = Supervisor.start_execution(execution.id)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, reason} ->
          assert reason == :normal
      after
        5_000 -> flunk("Execution timed out")
      end

      # Verify node executions were created for the workflow's nodes
      node_executions =
        Repo.all(
          from ne in Imgd.Executions.NodeExecution,
            where: ne.execution_id == ^execution.id,
            order_by: [asc: ne.inserted_at]
        )

      # Should have executed both nodes
      assert length(node_executions) == 2
      node_ids = Enum.map(node_executions, & &1.node_id)
      assert "start_node" in node_ids
      assert "end_node" in node_ids
    end
  end
end

defmodule Imgd.Runtime.Engines.RunicTest do
  use Imgd.DataCase, async: false

  alias Imgd.Runtime.Engines.Runic
  alias Imgd.Executions.{Context, NodeExecution, NodeExecutionBuffer}
  alias Imgd.Runtime.ExecutionState
  alias Imgd.Repo

  setup do
    user = insert(:user)
    workflow = insert(:workflow, user: user)
    version = insert(:workflow_version, workflow: workflow)
    execution = insert(:execution, workflow: workflow, workflow_version: version)
    context = Context.new(execution)

    ExecutionState.start(execution.id)

    on_exit(fn ->
      ExecutionState.cleanup(execution.id)
    end)

    %{execution: execution, context: context, version: version}
  end

  describe "hooks idempotency" do
    test "handle_node_started is idempotent", %{execution: execution} do
      node_id = "test_node"
      node_info = %{type_id: "debug", name: "Test Node"}
      fact = %{value: %{"input" => "data"}}

      # First call
      Runic.handle_node_started(execution, node_id, node_info, fact, ExecutionState)

      # Second call
      Runic.handle_node_started(execution, node_id, node_info, fact, ExecutionState)

      # Flush buffer to ensure DB is updated
      NodeExecutionBuffer.flush()

      # Verify only one NodeExecution record exists
      node_execs = Repo.all(from n in NodeExecution, where: n.execution_id == ^execution.id)
      assert length(node_execs) == 1
      assert Enum.at(node_execs, 0).status == :running
    end

    test "handle_node_completed is idempotent", %{execution: execution} do
      node_id = "test_node"
      node_info = %{type_id: "debug", name: "Test Node"}
      fact_start = %{value: %{"input" => "data"}}
      fact_complete = %{value: %{"output" => "result"}}

      # Start the node
      Runic.handle_node_started(execution, node_id, node_info, fact_start, ExecutionState)

      # Complete the node twice
      Runic.handle_node_completed(execution, node_id, node_info, fact_complete, ExecutionState)
      Runic.handle_node_completed(execution, node_id, node_info, fact_complete, ExecutionState)

      # Flush buffer
      NodeExecutionBuffer.flush()

      # Verify only one NodeExecution record exists and is completed
      node_execs = Repo.all(from n in NodeExecution, where: n.execution_id == ^execution.id)
      assert length(node_execs) == 1
      assert Enum.at(node_execs, 0).status == :completed
      assert Enum.at(node_execs, 0).output_data == %{"output" => "result"}
    end

    test "handle_node_completed creates a record if it doesn't exist (e.g. missed start)", %{
      execution: execution
    } do
      node_id = "test_node"
      node_info = %{type_id: "debug", name: "Test Node"}
      fact_complete = %{value: %{"output" => "result"}}

      # Complete without starting
      Runic.handle_node_completed(execution, node_id, node_info, fact_complete, ExecutionState)

      # Flush buffer
      NodeExecutionBuffer.flush()

      # Verify record was created as completed
      node_execs = Repo.all(from n in NodeExecution, where: n.execution_id == ^execution.id)
      assert length(node_execs) == 1
      assert Enum.at(node_execs, 0).status == :completed
    end
  end

  describe "handle_node_failed" do
    test "marks a running node as failed with error context", %{execution: execution} do
      node_id = "failing_node"
      node_info = %{type_id: "format", name: "Formatter"}
      fact_start = %{value: %{"input" => "data"}}
      reason = {:expression_error, %{message: "bad template"}}

      Runic.handle_node_started(execution, node_id, node_info, fact_start, ExecutionState)
      Runic.handle_node_failed(execution, node_id, node_info, reason, ExecutionState)

      NodeExecutionBuffer.flush()

      [node_exec] =
        Repo.all(
          from n in NodeExecution,
            where: n.execution_id == ^execution.id and n.node_id == ^node_id
        )

      assert node_exec.status == :failed
      assert node_exec.completed_at
      assert %{"type" => "node_failure", "node_id" => ^node_id} = node_exec.error
      assert node_exec.error["reason"] =~ "expression_error"
    end

    test "creates a failed record when the start hook was missed", %{execution: execution} do
      node_id = "missing_start"
      node_info = %{type_id: "format", name: "Formatter"}
      reason = :unexpected

      Runic.handle_node_failed(execution, node_id, node_info, reason, ExecutionState)

      NodeExecutionBuffer.flush()

      [node_exec] =
        Repo.all(
          from n in NodeExecution,
            where: n.execution_id == ^execution.id and n.node_id == ^node_id
        )

      assert node_exec.status == :failed
      assert node_exec.started_at
      assert node_exec.completed_at
    end
  end
end

defmodule Imgd.Workflows.ExecutionSchemaTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Imgd.Workflows.Execution
  alias Imgd.Workflows.ExecutionStep

  describe "execution changesets" do
    test "start_changeset marks execution as running and sets timestamps" do
      execution = %Execution{}
      changeset = Execution.start_changeset(execution)

      assert changeset.changes.status == :running
      assert %DateTime{} = changeset.changes.started_at
      assert %DateTime{} = changeset.changes.expires_at
      assert DateTime.compare(changeset.changes.expires_at, changeset.changes.started_at) == :gt
    end

    test "complete_changeset normalizes list outputs" do
      execution = %Execution{}
      output = [%{value: 1}]

      changeset = Execution.complete_changeset(execution, output)

      assert changeset.changes.status == :completed
      assert changeset.changes.output == %{productions: output}
      assert %DateTime{} = changeset.changes.completed_at
    end

    test "fail_changeset normalizes tuple errors" do
      execution = %Execution{}

      changeset =
        try do
          raise "boom"
        rescue
          e ->
            Execution.fail_changeset(execution, {:error, e, __STACKTRACE__})
        end

      assert changeset.changes.status == :failed
      assert changeset.changes.error.type == "error"
      assert changeset.changes.error.message =~ "boom"
      assert is_binary(changeset.changes.error.stacktrace)
      assert %DateTime{} = changeset.changes.completed_at
    end

    test "resumable?/1 returns true only for paused or failed executions" do
      assert Execution.resumable?(%Execution{status: :paused})
      assert Execution.resumable?(%Execution{status: :failed})
      refute Execution.resumable?(%Execution{status: :running})
    end

    test "terminal?/1 returns true for terminal statuses" do
      for status <- [:completed, :failed, :cancelled, :timeout] do
        assert Execution.terminal?(%Execution{status: status})
      end

      refute Execution.terminal?(%Execution{status: :running})
    end
  end

  describe "execution step helpers" do
    test "step_name/1 normalizes non-string names" do
      assert ExecutionStep.step_name(%{name: :my_step, hash: 1}) == "my_step"
      assert ExecutionStep.step_name(%{name: 123, hash: 1}) == "123"
      assert ExecutionStep.step_name(%{name: nil, hash: 10}) == "step_10"
    end

    test "changeset truncates large snapshots" do
      large_snapshot = %{"data" => String.duplicate("a", 12_000)}

      changeset =
        ExecutionStep.changeset(%ExecutionStep{}, %{
          execution_id: Ecto.UUID.generate(),
          step_hash: 1,
          step_name: "truncate",
          step_type: "Step",
          generation: 0,
          input_snapshot: large_snapshot
        })

      assert %{_truncated: true, _size: size} = get_change(changeset, :input_snapshot)
      assert size > 10_000
    end

    test "changeset truncates oversized logs" do
      long_logs = String.duplicate("log", 35_000)

      changeset =
        ExecutionStep.changeset(%ExecutionStep{}, %{
          execution_id: Ecto.UUID.generate(),
          step_hash: 2,
          step_name: "loggy",
          step_type: "Step",
          generation: 0,
          logs: long_logs
        })

      truncated = get_change(changeset, :logs)
      assert truncated |> String.starts_with?("[truncated...]")
      assert String.length(truncated) <= 100_020
    end
  end
end

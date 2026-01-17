defmodule Imgd.Runtime.StepSkipIntegrationTest do
  use Imgd.DataCase
  alias Imgd.Runtime.Hooks.Observability
  alias Imgd.Runtime.Steps.StepRunner
  alias Imgd.Executions
  alias Imgd.Executions.StepExecution

  @moduletag :capture_log

  test "persists skipped status when step returns {:skip, ...}" do
    # 1. Setup execution and step
    user = insert(:user)
    workflow = insert(:workflow, user: user)

    {:ok, execution} =
      Executions.create_execution(%Imgd.Accounts.Scope{user: user}, %{
        workflow_id: workflow.id,
        trigger: %{type: :manual, data: %{}},
        execution_type: :preview
      })

    step = %Imgd.Workflows.Embeds.Step{
      id: "manual_trigger",
      # This executor skips if trigger_type is not manual
      type_id: "manual_input",
      config: %{}
    }

    # 2. Simulate step running in a context where it SHOULD skip
    # We pass trigger_type: :webhook so ManualInput executor skips
    opts = [
      execution_id: execution.id,
      workflow_id: workflow.id,
      # Mismatch to force skip
      trigger_type: :webhook,
      default_compute: Imgd.Compute.Target.local()
    ]

    # 3. Create a Runic Step that uses StepRunner
    # We need to manually invoke what Runic does or simulate the hook chain.
    # Because constructing a whole Runic workflow is heavy, let's verify the hook logic
    # by simulating what Runic calls: the before/after hooks.

    # But wait, the hook is attached to Runic.
    # Let's verify StepRunner sets the process flag first.
    Process.delete(:imgd_step_skipped)
    result = StepRunner.execute_with_context(step, nil, opts)
    assert result == nil
    assert Process.get(:imgd_step_skipped) == true

    # 4. Now verify Observability consumes the flag and persists
    # Re-set flag because we consumed it (or simulate it again)
    Process.put(:imgd_step_skipped, true)

    # Call the hook function directly (it's private, but maybe we can test via public API or just trust units?)
    # Observability.after_step_telemetry is private.

    # Integration test approach:
    # Build a minimal Runic workflow with this step, attach hooks, and run it.

    # Stub Runic workflow build
    alias Runic.Workflow

    wf = Workflow.new()
    runic_step = StepRunner.create(step, opts)
    wf = Workflow.add(wf, runic_step)

    # Attach hooks
    wf = Observability.attach_all_hooks(wf, execution_id: execution.id, workflow_id: workflow.id)

    # Run it
    Workflow.react_until_satisfied(wf, %{})

    # 5. Flush and persist (since we are not in Execution.Server)
    events = Observability.flush_step_events()
    Executions.record_step_executions_batch(events)

    # 6. Check DB
    step_exec = Repo.get_by(StepExecution, execution_id: execution.id, step_id: "manual_trigger")
    assert step_exec.status == :skipped
  end
end

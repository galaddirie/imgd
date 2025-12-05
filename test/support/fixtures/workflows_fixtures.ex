defmodule Imgd.WorkflowsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Imgd.Workflows` context.
  """

  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionStep}
  alias Imgd.Repo
  alias Imgd.Engine.DataFlow
  alias Imgd.Engine.DataFlow.Envelope

  def valid_workflow_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "test-workflow-#{System.unique_integer([:positive])}",
      description: "A test workflow",
      trigger_config: %{type: :manual, config: %{}},
      settings: %{
        timeout_ms: 300_000,
        max_retries: 3
      }
    })
  end

  def valid_workflow_definition do
    # A minimal encoded workflow definition for testing
    # In real usage, this would be a serialized Runic build log
    %{"encoded" => Base.encode64(:erlang.term_to_binary([]))}
  end

  def workflow_fixture(scope, attrs \\ %{}) do
    attrs = valid_workflow_attributes(attrs)
    {:ok, workflow} = Workflows.create_workflow(scope, attrs)
    workflow
  end

  def draft_workflow_fixture(scope, attrs \\ %{}) do
    workflow_fixture(scope, Map.put(attrs, :status, :draft))
  end

  def published_workflow_fixture(scope, attrs \\ %{}) do
    workflow = workflow_fixture(scope, attrs)

    {:ok, workflow} =
      Workflows.publish_workflow(scope, workflow, %{definition: valid_workflow_definition()})

    workflow
  end

  def archived_workflow_fixture(scope, attrs \\ %{}) do
    workflow = published_workflow_fixture(scope, attrs)
    {:ok, workflow} = Workflows.archive_workflow(scope, workflow)
    workflow
  end

  def valid_execution_attributes(workflow, attrs \\ %{}) do
    trace_id = attrs[:trace_id] || "test-trace-#{System.unique_integer([:positive])}"
    raw_input = attrs[:input] || %{test: "input"}
    input_envelope = DataFlow.wrap(raw_input, source: :input, trace_id: trace_id)

    Enum.into(attrs, %{
      workflow_id: workflow.id,
      workflow_version: workflow.version,
      trigger_type: :manual,
      input: Envelope.to_map(input_envelope),
      metadata: Map.put(attrs[:metadata] || %{}, "trace_id", trace_id)
    })
  end

  def execution_fixture(scope, workflow, attrs \\ %{}) do
    {:ok, execution} =
      Workflows.start_execution(scope, workflow,
        input: attrs[:input] || %{test: "input"},
        trigger_type: attrs[:trigger_type] || :manual,
        metadata: attrs[:metadata] || %{}
      )

    execution
  end

  def pending_execution_fixture(_scope, workflow, attrs \\ %{}) do
    # Create execution without starting it (stays in pending state)
    attrs = valid_execution_attributes(workflow, attrs)

    %Execution{}
    |> Execution.changeset(attrs)
    |> Repo.insert!()
  end

  def completed_execution_fixture(scope, workflow, attrs \\ %{}) do
    execution = execution_fixture(scope, workflow, attrs)
    {:ok, execution} = Workflows.complete_execution(scope, execution, %{result: "success"})
    execution
  end

  def failed_execution_fixture(scope, workflow, attrs \\ %{}) do
    execution = execution_fixture(scope, workflow, attrs)

    {:ok, execution} =
      Workflows.fail_execution(scope, execution, %{
        type: "RuntimeError",
        message: "Test failure"
      })

    execution
  end

  def paused_execution_fixture(scope, workflow, attrs \\ %{}) do
    execution = execution_fixture(scope, workflow, attrs)
    {:ok, execution} = Workflows.pause_execution(scope, execution)
    execution
  end

  def valid_step_attributes(execution, attrs \\ %{}) do
    step_hash = attrs[:step_hash] || :erlang.phash2("step-#{System.unique_integer()}")
    snapshot_value = attrs[:input_snapshot] || DataFlow.snapshot(%{"value" => "test_input"})

    Enum.into(attrs, %{
      execution_id: execution.id,
      step_hash: step_hash,
      step_name: attrs[:step_name] || "test_step_#{step_hash}",
      step_type: attrs[:step_type] || "Step",
      generation: attrs[:generation] || 0,
      input_fact_hash:
        attrs[:input_fact_hash] || :erlang.phash2("fact-#{System.unique_integer()}"),
      input_snapshot: snapshot_value,
      status: :pending
    })
  end

  def execution_step_fixture(execution, attrs \\ %{}) do
    attrs = valid_step_attributes(execution, attrs)

    %ExecutionStep{}
    |> ExecutionStep.changeset(attrs)
    |> Repo.insert!()
  end

  def completed_step_fixture(execution, attrs \\ %{}) do
    step = execution_step_fixture(execution, attrs)

    step
    |> ExecutionStep.start_changeset()
    |> Repo.update!()
    |> ExecutionStep.complete_changeset(
      %{hash: :erlang.phash2("output"), value: "result"},
      100
    )
    |> Repo.update!()
  end

  def failed_step_fixture(execution, attrs \\ %{}) do
    step = execution_step_fixture(execution, attrs)

    step
    |> ExecutionStep.start_changeset()
    |> Repo.update!()
    |> ExecutionStep.fail_changeset(%{type: "Error", message: "Step failed"}, 50)
    |> Repo.update!()
  end
end

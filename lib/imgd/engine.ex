defmodule Imgd.Engine do
  @moduledoc """
  The workflow execution engine.

  Provides the runtime layer for executing Runic workflows with:
  - Durable execution via Oban workers
  - Observability (telemetry, tracing, structured logs)

  ## Architecture

  The engine consists of:

  - `Engine.Runner` - Orchestrates workflow execution, manages the execution loop
  - `Engine.StepExecutor` - Executes individual steps with error handling
  - `Workers.ExecutionWorker` - Oban worker for execution coordination

  ## Execution Flow

  1. `Workflows.start_execution/3` creates an execution record and enqueues `ExecutionWorker`
  2. `ExecutionWorker` loads the workflow, plans input, finds runnables, and executes them
  3. Steps are executed and recorded until the workflow completes
  """

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "A Runic workflow struct"
  @type workflow :: Runic.Workflow.t()

  @typedoc "A runnable is a tuple of {node, fact} that can be executed"
  @type runnable :: {Runic.Workflow.Step.t() | Runic.Workflow.Rule.t(), Runic.Workflow.Fact.t()}

  @typedoc "Step execution result"
  @type step_result ::
          {:ok, workflow()}
          | {:error, term(), workflow()}
          | {:error, term(), Exception.stacktrace(), workflow()}

  @typedoc "Execution mode for the runner"
  @type execution_mode :: :start | :continue | :resume

  @typedoc "Options for starting execution"
  @type start_opts :: [
          input: term(),
          trigger_type: :manual | :schedule | :webhook | :event,
          metadata: map()
        ]

  # ============================================================================
  # Telemetry Events
  # ============================================================================

  @doc """
  Telemetry event names used by the engine.

  ## Events

  - `[:imgd, :engine, :execution, :start]` - Execution started
  - `[:imgd, :engine, :execution, :complete]` - Execution completed
  - `[:imgd, :engine, :execution, :fail]` - Execution failed
  - `[:imgd, :engine, :step, :start]` - Step execution started
  - `[:imgd, :engine, :step, :stop]` - Step execution completed (success or failure)
  - `[:imgd, :engine, :step, :exception]` - Step raised an exception
  - `[:imgd, :engine, :generation, :complete]` - Generation completed
  """
  def telemetry_events do
    [
      [:imgd, :engine, :execution, :start],
      [:imgd, :engine, :execution, :complete],
      [:imgd, :engine, :execution, :fail],
      [:imgd, :engine, :step, :start],
      [:imgd, :engine, :step, :stop],
      [:imgd, :engine, :step, :exception],
      [:imgd, :engine, :generation, :complete]
    ]
  end
end

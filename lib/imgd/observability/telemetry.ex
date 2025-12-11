defmodule Imgd.Observability.Telemetry do
  @moduledoc """
  Telemetry event definitions and tracing helpers for the workflow engine.

  The helpers in this module align with the current `Workflow`, `Execution`, and
  `NodeExecution` schemas so observability stays consistent while the runtime is
  being built. Events follow the `[:imgd, :engine, ...]` naming convention and
  include the IDs and metadata required for PromEx, Grafana, and OpenTelemetry.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Span
  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Workflows.{Workflow, WorkflowVersion}

  @doc """
  All telemetry events emitted by the engine.
  """
  def events do
    [
      [:imgd, :engine, :execution, :start],
      [:imgd, :engine, :execution, :stop],
      [:imgd, :engine, :execution, :exception],
      [:imgd, :engine, :node, :start],
      [:imgd, :engine, :node, :stop],
      [:imgd, :engine, :node, :exception],
      [:imgd, :engine, :stats, :poll]
    ]
  end

  # TODO: traced span and event emission for the engine
end

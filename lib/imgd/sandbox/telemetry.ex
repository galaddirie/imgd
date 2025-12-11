defmodule Imgd.Sandbox.Telemetry do
  @moduledoc false

  require Logger

  def span(event, metadata, fun) do
    :telemetry.span(event, metadata, fun)
  end

  def setup do
    events = [
      [:sandbox, :eval, :stop],
      [:sandbox, :eval, :exception]
    ]

    :telemetry.attach_many(
      "imgd-sandbox-logger",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:sandbox, :eval, :stop], measurements, metadata, _config) do
    Logger.info("sandbox_eval_complete",
      duration_ms: div(measurements.duration, 1_000_000),
      status: metadata.status,
      code_size: metadata.code_size,
      fuel_consumed: metadata[:fuel_consumed]
    )
  end

  def handle_event([:sandbox, :eval, :exception], _measurements, metadata, _config) do
    Logger.error("sandbox_eval_exception",
      kind: metadata.kind,
      reason: inspect(metadata.reason)
    )
  end

  def handle_event(_, _, _, _), do: :ok
end

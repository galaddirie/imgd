defmodule Imgd.Observability.Telemetry do
  @moduledoc """
  Telemetry event definitions and setup for the workflow engine.

  ## Event Naming Convention

  All engine events follow the pattern `[:imgd, :engine, <domain>, <action>]`:

  - `[:imgd, :engine, :execution, :start | :stop | :exception]`
  - `[:imgd, :engine, :step, :start | :stop | :exception | :retry]`
  - `[:imgd, :engine, :expression, :evaluate]`
  - `[:imgd, :engine, :stats, :poll]`

  ## Measurements and Metadata

  Each event includes specific measurements and metadata documented in `events/0`.
  The PromEx plugin (`Imgd.Observability.PromEx.Plugins.Engine`) subscribes to
  these events to generate Prometheus metrics.

  ## Setup

  Call `Imgd.Observability.Telemetry.setup/0` in your application startup
  to attach any custom handlers (beyond PromEx).
  """

  require Logger

  @doc """
  All telemetry events emitted by the workflow engine.

  Returns a list of `{event_name, measurements, metadata}` tuples describing
  each event for documentation and testing purposes.
  """
  def events do
    [
      # ========================================================================
      # Execution Events
      # ========================================================================
      {[:imgd, :engine, :execution, :start], %{system_time: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         trigger_type: :atom
       }},
      {[:imgd, :engine, :execution, :stop], %{duration_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         trigger_type: :atom,
         status: :atom
       }},
      {[:imgd, :engine, :execution, :exception], %{duration_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         exception: :exception
       }},

      # ========================================================================
      # Step Events
      # ========================================================================
      {[:imgd, :engine, :step, :start], %{system_time: :integer, queue_time_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         step_id: :string,
         step_type_id: :string,
         attempt: :integer
       }},
      {[:imgd, :engine, :step, :stop], %{duration_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         step_id: :string,
         step_type_id: :string,
         attempt: :integer,
         status: :atom
       }},
      {[:imgd, :engine, :step, :exception], %{duration_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         step_id: :string,
         step_type_id: :string,
         attempt: :integer,
         exception: :exception
       }},
      {[:imgd, :engine, :step, :retry], %{backoff_ms: :integer},
       %{
         execution_id: :string,
         workflow_id: :string,
         step_id: :string,
         step_type_id: :string,
         attempt: :integer
       }},

      # ========================================================================
      # Expression Events (high-frequency, lightweight)
      # ========================================================================
      {[:imgd, :engine, :expression, :evaluate], %{duration_us: :integer},
       %{
         execution_id: :string,
         expression_type: :atom,
         status: :atom
       }},

      # ========================================================================
      # Polling/Gauge Events
      # ========================================================================
      {[:imgd, :engine, :stats, :poll],
       %{
         active_executions: :integer,
         pending_executions: :integer,
         running_steps: :integer
       }, %{}}
    ]
  end

  @doc """
  Returns just the event names for attachment.
  """
  def event_names do
    Enum.map(events(), fn {name, _, _} -> name end)
  end

  @doc """
  Sets up telemetry handlers for the workflow engine.

  Call this from your Application.start/2 callback.
  PromEx handles metric collection automatically; this function
  is for any additional handlers you want to attach.
  """
  def setup do
    # Attach debug handler in dev/test for visibility
    if Application.get_env(:imgd, :env) in [:dev, :test] do
      attach_debug_handler()
    end

    :ok
  end

  @doc """
  Attaches a debug handler that logs all engine events.
  Useful during development to verify events are firing.
  """
  def attach_debug_handler do
    events = [
      [:imgd, :engine, :execution, :start],
      [:imgd, :engine, :execution, :stop],
      [:imgd, :engine, :execution, :exception],
      [:imgd, :engine, :step, :start],
      [:imgd, :engine, :step, :stop],
      [:imgd, :engine, :step, :exception],
      [:imgd, :engine, :step, :retry]
    ]

    :telemetry.attach_many(
      "imgd-engine-debug-handler",
      events,
      &handle_debug_event/4,
      nil
    )
  end

  @doc """
  Detaches the debug handler.
  """
  def detach_debug_handler do
    :telemetry.detach("imgd-engine-debug-handler")
  end

  defp handle_debug_event(event, measurements, metadata, _config) do
    event_name = Enum.join(event, ".")

    Logger.debug(
      "[Telemetry] #{event_name}",
      event: event_name,
      measurements: measurements,
      metadata: sanitize_metadata(metadata)
    )
  end

  defp sanitize_metadata(metadata) do
    Map.new(metadata, fn
      {:exception, e} -> {:exception, Exception.message(e)}
      {k, v} when is_binary(v) or is_atom(v) or is_number(v) -> {k, v}
      {k, v} -> {k, inspect(v)}
    end)
  end

  # ============================================================================
  # Convenience Functions for Manual Event Emission
  # ============================================================================

  @doc """
  Emits a custom engine event.

  Use this for events not covered by the standard Instrumentation module,
  such as workflow-specific business events.

  ## Example

      Telemetry.emit(:workflow, :activated, %{workflow_id: wf.id}, %{count: 1})
  """
  def emit(domain, action, metadata, measurements \\ %{}) do
    event = [:imgd, :engine, domain, action]
    :telemetry.execute(event, measurements, metadata)
  end

  @doc """
  Measures the execution time of a function and emits a telemetry event.

  ## Example

      Telemetry.span(:custom, :operation, %{workflow_id: id}, fn ->
        do_expensive_work()
      end)
  """
  def span(domain, action, metadata, fun) do
    # :telemetry.span expects an event prefix - it automatically appends
    # :start, :stop, or :exception to create the full event names
    event_prefix = [:imgd, :engine, domain, action]

    :telemetry.span(
      event_prefix,
      metadata,
      fn ->
        result = fun.()
        {result, metadata}
      end
    )
  end
end

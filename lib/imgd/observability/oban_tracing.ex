defmodule Imgd.Observability.ObanTracing do
  @moduledoc """
  Trace context propagation for Oban jobs.

  OpenTelemetry traces don't automatically propagate across process boundaries.
  This module provides helpers to serialize trace context when enqueuing jobs
  and restore it when the job executes.

  ## Usage

  When enqueuing a job from an instrumented context:

      def schedule_step_execution(execution, step) do
        args =
          %{execution_id: execution.id, step_id: step.id}
          |> ObanTracing.inject_trace_context()

        %{args: args}
        |> StepExecutionWorker.new()
        |> Oban.insert()
      end

  In your Oban worker:

      defmodule StepExecutionWorker do
        use Oban.Worker

        alias Imgd.Observability.ObanTracing

        @impl Oban.Worker
        def perform(%Oban.Job{args: args}) do
          ObanTracing.with_trace_context(args, fn ->
            # Your job logic here - it's now in the parent trace
            do_work(args)
          end)
        end
      end
  """

  require OpenTelemetry.Tracer, as: Tracer

  @trace_context_key "otel_trace_context"

  @doc """
  Injects the current trace context into job args.

  Call this when building args for Oban.insert/1.
  """
  def inject_trace_context(args) when is_map(args) do
    case extract_current_context() do
      nil -> args
      ctx -> Map.put(args, @trace_context_key, ctx)
    end
  end

  @doc """
  Executes a function within the trace context stored in job args.

  Creates a new span as a child of the original trace.
  """
  def with_trace_context(args, fun) when is_map(args) and is_function(fun, 0) do
    case Map.get(args, @trace_context_key) do
      nil ->
        # No trace context - just run the function
        fun.()

      ctx ->
        restore_context(ctx)

        Tracer.with_span "oban.job.execute", %{} do
          fun.()
        end
    end
  end

  @doc """
  Creates a linked span for background work that's related but not a child.

  Use this when you want correlation without strict parent-child relationship.
  """
  def with_linked_context(args, span_name, fun) when is_map(args) do
    case Map.get(args, @trace_context_key) do
      nil ->
        Tracer.with_span span_name, %{} do
          fun.()
        end

      ctx ->
        links = build_links(ctx)

        Tracer.with_span span_name, %{links: links} do
          fun.()
        end
    end
  end

  @doc """
  Strips trace context from args before passing to business logic.

  Use this to avoid leaking trace metadata into your domain.
  """
  def strip_trace_context(args) when is_map(args) do
    Map.delete(args, @trace_context_key)
  end

  # Private helpers

  defp extract_current_context do
    case :otel_propagator_text_map.inject([]) do
      [{"traceparent", traceparent} | rest] ->
        ctx = %{"traceparent" => traceparent}

        case List.keyfind(rest, "tracestate", 0) do
          {"tracestate", tracestate} -> Map.put(ctx, "tracestate", tracestate)
          nil -> ctx
        end

      _ ->
        nil
    end
  end

  defp restore_context(ctx) when is_map(ctx) do
    headers =
      ctx
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    :otel_propagator_text_map.extract(headers)
  end

  defp build_links(ctx) when is_map(ctx) do
    # Restore context temporarily to get the span context
    restore_context(ctx)

    case OpenTelemetry.Tracer.current_span_ctx() do
      :undefined -> []
      span_ctx -> [OpenTelemetry.link(span_ctx)]
    end
  end
end

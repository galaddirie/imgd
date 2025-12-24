defmodule Imgd.Observability.Instrumentation do
  @moduledoc """
  Unified instrumentation API for the workflow engine.

  Combines OpenTelemetry tracing and Telemetry events (for PromEx metrics)
  into a single coherent interface.

  ## Usage in Runtime

      def execute_workflow(execution) do
        Instrumentation.trace_execution(execution, fn ctx ->
          # ctx contains span context for propagation
          do_work(ctx)
        end)
      end

  ## Step Tracing

  Step-level tracing is handled via Runic hooks installed by the execution engine.
  This ensures all step lifecycle events (start/complete/fail) are tracked
  consistently with proper timing, PubSub broadcasts, and telemetry.

  ## Context Propagation

  The instrumentation automatically:
  - Creates OpenTelemetry spans with proper parent/child relationships
  - Emits telemetry events for PromEx metrics
  - Attaches trace context to Logger metadata
  - Records timing and status information
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Ctx
  alias Imgd.Executions.Execution
  alias Imgd.Executions.StepExecution
  alias Imgd.Executions.PubSub, as: ExecutionPubSub

  # ============================================================================
  # Execution Lifecycle
  # ============================================================================

  @doc """
  Records that an execution has started.
  """
  def record_execution_started(%Execution{} = execution) do
    emit_execution_start(execution)
    ExecutionPubSub.broadcast_execution_started(execution)
  end

  @doc """
  Records that an execution has completed successfully.
  """
  def record_execution_completed(%Execution{} = execution, duration_us) do
    emit_execution_stop(execution, :completed, duration_us)
    ExecutionPubSub.broadcast_execution_completed(execution)
  end

  @doc """
  Records that an execution has failed.
  """
  def record_execution_failed(%Execution{} = execution, reason, duration_us) do
    error = Execution.format_error(reason)
    record_span_error(error)
    emit_execution_stop(execution, :failed, duration_us)
    ExecutionPubSub.broadcast_execution_failed(execution, error)
  end

  # ============================================================================
  # Step Lifecycle
  # ============================================================================

  @doc """
  Records that a step has started executing.
  """
  def record_step_started(%Execution{} = execution, %StepExecution{} = step_execution) do
    :telemetry.execute(
      [:imgd, :step, :start],
      %{system_time: System.system_time(), queue_time_us: nil},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_id: step_execution.step_id,
        step_type_id: step_execution.step_type_id,
        attempt: step_execution.attempt
      }
    )

    ExecutionPubSub.broadcast_step_started(execution, step_execution)
  end

  @doc """
  Records that a step has completed successfully.
  """
  def record_step_completed(
        %Execution{} = execution,
        %StepExecution{} = step_execution,
        duration_us
      ) do
    :telemetry.execute(
      [:imgd, :step, :stop],
      %{duration_us: duration_us},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_id: step_execution.step_id,
        step_type_id: step_execution.step_type_id,
        attempt: step_execution.attempt,
        status: :completed
      }
    )

    ExecutionPubSub.broadcast_step_completed(execution, step_execution)
  end

  @doc """
  Records that a step has failed.
  """
  def record_step_failed(
        %Execution{} = execution,
        %StepExecution{} = step_execution,
        reason,
        duration_us
      ) do
    error = Execution.format_error(reason)

    :telemetry.execute(
      [:imgd, :step, :stop],
      %{duration_us: duration_us},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_id: step_execution.step_id,
        step_type_id: step_execution.step_type_id,
        attempt: step_execution.attempt,
        status: :failed,
        error: error
      }
    )

    ExecutionPubSub.broadcast_step_failed(execution, step_execution, error)
  end

  # ============================================================================
  # Execution Tracing
  # ============================================================================

  @doc """
  Traces a complete workflow execution.

  Creates a root span for the execution, emits start/stop telemetry events,
  and handles exceptions with proper error recording.

  Returns `{:ok, result}` or `{:error, reason}` from the callback.
  """
  def trace_execution(%Execution{} = execution, fun) when is_function(fun, 0) do
    trace_execution(execution, fn _ctx -> fun.() end)
  end

  def trace_execution(%Execution{} = execution, fun) when is_function(fun, 1) do
    span_name = "workflow.execute"
    start_time = System.monotonic_time()

    attrs = execution_span_attributes(execution)

    Tracer.with_span span_name, %{attributes: attrs} do
      ctx = build_trace_context(execution)
      attach_logger_metadata(ctx)

      # PubSub and logging moved to separate functions called by WorkflowRunner/Engines
      emit_execution_start(execution)

      try do
        result = fun.(ctx)
        duration_us = monotonic_duration_us(start_time)

        case result do
          {:ok, updated_execution} when is_struct(updated_execution, Execution) ->
            emit_execution_stop(updated_execution, :completed, duration_us)
            result

          {:ok, _} = success ->
            emit_execution_stop(execution, :completed, duration_us)
            success

          {:error, reason} = error ->
            record_span_error(Execution.format_error(reason))
            emit_execution_stop(execution, :failed, duration_us)
            error
        end
      rescue
        e ->
          duration_us = monotonic_duration_us(start_time)
          record_span_exception(e, __STACKTRACE__)
          emit_execution_stop(execution, :failed, duration_us)
          emit_execution_exception(execution, e, duration_us)
          reraise e, __STACKTRACE__
      end
    end
  end

  @doc """
  Wraps an existing execution in a trace context without creating a new span.

  Useful when resuming an execution or when the span was created elsewhere.
  """
  def with_execution_context(%Execution{} = execution, fun) do
    ctx = build_trace_context(execution)
    attach_logger_metadata(ctx)
    fun.(ctx)
  end

  @doc """
  Records a step retry event.

  Call this when scheduling a retry to track retry patterns.
  """
  def record_step_retry(%Execution{} = execution, step_info, attempt, backoff_us) do
    :telemetry.execute(
      [:imgd, :step, :retry],
      %{backoff_us: backoff_us},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_id: step_info.id,
        step_type_id: step_info.type_id,
        attempt: attempt
      }
    )

    Logger.info("Step retry scheduled",
      event: "step.retry",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_id: step_info.id,
      step_type_id: step_info.type_id,
      attempt: attempt,
      backoff_us: backoff_us
    )
  end

  # ============================================================================
  # Expression/Transform Tracing (lightweight)
  # ============================================================================

  @doc """
  Traces expression evaluation with minimal overhead.

  For hot paths like expression evaluation, we only emit telemetry
  (no spans) to keep overhead low.
  """
  def trace_expression(execution_id, expression_type, fun) do
    start_time = System.monotonic_time()

    try do
      result = fun.()

      duration_us =
        (System.monotonic_time() - start_time) |> System.convert_time_unit(:native, :microsecond)

      :telemetry.execute(
        [:imgd, :expression, :evaluate],
        %{duration_us: duration_us},
        %{execution_id: execution_id, expression_type: expression_type, status: :ok}
      )

      result
    rescue
      e ->
        duration_us =
          (System.monotonic_time() - start_time)
          |> System.convert_time_unit(:native, :microsecond)

        :telemetry.execute(
          [:imgd, :expression, :evaluate],
          %{duration_us: duration_us},
          %{execution_id: execution_id, expression_type: expression_type, status: :error}
        )

        reraise e, __STACKTRACE__
    end
  end

  # ============================================================================
  # Oban Job Tracing
  # ============================================================================

  @doc """
  Extracts trace context from an Oban job's args for propagation.

  Call this at the start of your Oban worker to continue the trace.
  """
  def extract_trace_context(%{"trace_context" => ctx}) when is_map(ctx) do
    # Reconstruct OpenTelemetry context from serialized form
    case ctx do
      %{"traceparent" => traceparent} ->
        :otel_propagator_text_map.extract([{"traceparent", traceparent}])

      _ ->
        :ok
    end
  end

  def extract_trace_context(_), do: :ok

  @doc """
  Serializes current trace context for inclusion in Oban job args.

  Call this when enqueuing an Oban job to propagate the trace.
  """
  def serialize_trace_context do
    carrier = :otel_propagator_text_map.inject([])

    case carrier do
      [{"traceparent", traceparent} | _] ->
        %{"traceparent" => traceparent}

      _ ->
        %{}
    end
  end

  # ============================================================================
  # Telemetry Event Emission (for PromEx)
  # ============================================================================

  defp emit_execution_start(%Execution{} = execution) do
    :telemetry.execute(
      [:imgd, :execution, :start],
      %{system_time: System.system_time()},
      execution_metadata(execution)
    )
  end

  defp emit_execution_stop(%Execution{} = execution, status, duration_us) do
    :telemetry.execute(
      [:imgd, :execution, :stop],
      %{duration_us: duration_us},
      execution_metadata(execution) |> Map.put(:status, status)
    )
  end

  defp emit_execution_exception(%Execution{} = execution, exception, duration_us) do
    :telemetry.execute(
      [:imgd, :execution, :exception],
      %{duration_us: duration_us},
      execution_metadata(execution) |> Map.put(:exception, exception)
    )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_trace_context(%Execution{} = execution) do
    trace_id =
      get_in(execution.metadata || %{}, [Access.key(:trace_id)]) ||
        get_in(execution.metadata || %{}, [Access.key("trace_id")])

    %{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      trace_id: trace_id,
      otel_ctx: Ctx.get_current()
    }
  end

  defp attach_logger_metadata(ctx) do
    Logger.metadata(
      execution_id: ctx.execution_id,
      workflow_id: ctx.workflow_id
    )

    # OpenTelemetry logger metadata is handled by opentelemetry_logger_metadata
  end

  defp execution_span_attributes(%Execution{} = execution) do
    %{
      "workflow.id": execution.workflow_id,
      "execution.id": execution.id,
      "execution.trigger_type": Execution.trigger_type(execution) |> to_string(),
      "execution.triggered_by": execution.triggered_by_user_id
    }
  end

  defp execution_metadata(%Execution{} = execution) do
    %{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      trigger_type: Execution.trigger_type(execution)
    }
  end

  defp monotonic_duration_us(start_time) do
    (System.monotonic_time() - start_time)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp record_span_error(reason) do
    span_ctx = Tracer.current_span_ctx()
    OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:error, inspect(reason)))
    Tracer.set_attribute(:error, true)
    Tracer.set_attribute(:"error.reason", inspect(reason))
  end

  defp record_span_exception(exception, stacktrace) do
    span_ctx = Tracer.current_span_ctx()
    OpenTelemetry.Span.record_exception(span_ctx, exception, stacktrace)

    OpenTelemetry.Span.set_status(
      span_ctx,
      OpenTelemetry.status(:error, Exception.message(exception))
    )
  end
end

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

  ## Node Tracing

  Node-level tracing is handled via Runic hooks installed by the execution engine.
  This ensures all node lifecycle events (start/complete/fail) are tracked
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
  alias Imgd.Executions.NodeExecution
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
  def record_execution_completed(%Execution{} = execution, duration_ms) do
    emit_execution_stop(execution, :completed, duration_ms)
    ExecutionPubSub.broadcast_execution_completed(execution)
  end

  @doc """
  Records that an execution has failed.
  """
  def record_execution_failed(%Execution{} = execution, reason, duration_ms) do
    error = Execution.format_error(reason)
    record_span_error(error)
    emit_execution_stop(execution, :failed, duration_ms)
    ExecutionPubSub.broadcast_execution_failed(execution, error)
  end

  # ============================================================================
  # Node Lifecycle
  # ============================================================================

  @doc """
  Records that a node has started executing.
  """
  def record_node_started(%Execution{} = execution, %NodeExecution{} = node_execution) do
    :telemetry.execute(
      [:imgd, :engine, :node, :start],
      %{system_time: System.system_time(), queue_time_ms: nil},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        node_id: node_execution.node_id,
        node_type_id: node_execution.node_type_id,
        attempt: node_execution.attempt
      }
    )

    ExecutionPubSub.broadcast_node_started(execution, node_execution)
  end

  @doc """
  Records that a node has completed successfully.
  """
  def record_node_completed(
        %Execution{} = execution,
        %NodeExecution{} = node_execution,
        duration_ms
      ) do
    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: duration_ms},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        node_id: node_execution.node_id,
        node_type_id: node_execution.node_type_id,
        attempt: node_execution.attempt,
        status: :completed
      }
    )

    ExecutionPubSub.broadcast_node_completed(execution, node_execution)
  end

  @doc """
  Records that a node has failed.
  """
  def record_node_failed(
        %Execution{} = execution,
        %NodeExecution{} = node_execution,
        reason,
        duration_ms
      ) do
    error = Execution.format_error(reason)

    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: duration_ms},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        node_id: node_execution.node_id,
        node_type_id: node_execution.node_type_id,
        attempt: node_execution.attempt,
        status: :failed,
        error: error
      }
    )

    ExecutionPubSub.broadcast_node_failed(execution, node_execution, error)
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
        duration_ms = monotonic_duration_ms(start_time)

        case result do
          {:ok, updated_execution} when is_struct(updated_execution, Execution) ->
            emit_execution_stop(updated_execution, :completed, duration_ms)
            result

          {:ok, _} = success ->
            emit_execution_stop(execution, :completed, duration_ms)
            success

          {:error, reason} = error ->
            record_span_error(Execution.format_error(reason))
            emit_execution_stop(execution, :failed, duration_ms)
            error
        end
      rescue
        e ->
          duration_ms = monotonic_duration_ms(start_time)
          record_span_exception(e, __STACKTRACE__)
          emit_execution_exception(execution, e, duration_ms)
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
  Records a node retry event.

  Call this when scheduling a retry to track retry patterns.
  """
  def record_node_retry(%Execution{} = execution, node_info, attempt, backoff_ms) do
    :telemetry.execute(
      [:imgd, :engine, :node, :retry],
      %{backoff_ms: backoff_ms},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        node_id: node_info.id,
        node_type_id: node_info.type_id,
        attempt: attempt
      }
    )

    Logger.info("Node retry scheduled",
      event: "node.retry",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      node_id: node_info.id,
      node_type_id: node_info.type_id,
      attempt: attempt,
      backoff_ms: backoff_ms
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
        [:imgd, :engine, :expression, :evaluate],
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
          [:imgd, :engine, :expression, :evaluate],
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
      [:imgd, :engine, :execution, :start],
      %{system_time: System.system_time()},
      execution_metadata(execution)
    )
  end

  defp emit_execution_stop(%Execution{} = execution, status, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :execution, :stop],
      %{duration_ms: duration_ms},
      execution_metadata(execution) |> Map.put(:status, status)
    )
  end

  defp emit_execution_exception(%Execution{} = execution, exception, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :execution, :exception],
      %{duration_ms: duration_ms},
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
      workflow_version_id: execution.workflow_version_id,
      trace_id: trace_id,
      otel_ctx: Ctx.get_current()
    }
  end

  defp attach_logger_metadata(ctx) do
    Logger.metadata(
      execution_id: ctx.execution_id,
      workflow_id: ctx.workflow_id,
      workflow_version_id: ctx.workflow_version_id
    )

    # OpenTelemetry logger metadata is handled by opentelemetry_logger_metadata
  end

  defp execution_span_attributes(%Execution{} = execution) do
    %{
      "workflow.id": execution.workflow_id,
      "workflow.version_id": execution.workflow_version_id,
      "execution.id": execution.id,
      "execution.trigger_type": Execution.trigger_type(execution) |> to_string(),
      "execution.triggered_by": execution.triggered_by_user_id
    }
  end

  defp execution_metadata(%Execution{} = execution) do
    %{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_version_id: execution.workflow_version_id,
      workflow_version_tag: get_version_tag(execution),
      trigger_type: Execution.trigger_type(execution)
    }
  end

  defp get_version_tag(%Execution{workflow_version: %{version_tag: tag}}), do: tag
  defp get_version_tag(_), do: nil

  defp monotonic_duration_ms(start_time) do
    (System.monotonic_time() - start_time)
    |> System.convert_time_unit(:native, :millisecond)
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

defmodule Imgd.Observability.Instrumentation do
  @moduledoc """
  Unified instrumentation API for the workflow engine.

  Combines OpenTelemetry tracing, Telemetry events (for PromEx metrics),
  and structured logging into a single coherent interface.

  ## Usage in Runtime

      def execute_workflow(execution) do
        Instrumentation.trace_execution(execution, fn ctx ->
          # ctx contains span context for propagation
          do_work(ctx)
        end)
      end

      def execute_node(execution, node, input) do
        Instrumentation.trace_node(execution, node, fn ->
          # Node execution logic
          {:ok, output}
        end)
      end

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

      emit_execution_start(execution)
      log_execution_event(:started, execution)

      try do
        result = fun.(ctx)
        duration_ms = monotonic_duration_ms(start_time)

        case result do
          {:ok, _} = success ->
            emit_execution_stop(execution, :completed, duration_ms)
            log_execution_event(:completed, execution, duration_ms: duration_ms)
            success

          {:error, reason} = error ->
            record_span_error(reason)
            emit_execution_stop(execution, :failed, duration_ms)
            log_execution_event(:failed, execution, duration_ms: duration_ms, error: reason)
            error
        end
      rescue
        e ->
          duration_ms = monotonic_duration_ms(start_time)
          record_span_exception(e, __STACKTRACE__)
          emit_execution_exception(execution, e, duration_ms)
          log_execution_event(:exception, execution, duration_ms: duration_ms, error: e)
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

  # ============================================================================
  # Node Tracing
  # ============================================================================

  @doc """
  Traces a single node execution within a workflow.

  Creates a child span under the current execution span.
  Automatically records queuing time if `queued_at` is provided in opts.

  ## Options
    * `:queued_at` - DateTime when the node was queued (for queue time metrics)
    * `:attempt` - Current retry attempt number (default: 1)
    * `:input` - Input data for the node (included in span attributes)
  """
  def trace_node(%Execution{} = execution, node_info, opts \\ [], fun) do
    span_name = "node.execute.#{node_info.type_id}"
    start_time = System.monotonic_time()
    attempt = Keyword.get(opts, :attempt, 1)

    attrs = node_span_attributes(execution, node_info, opts)

    Tracer.with_span span_name, %{attributes: attrs} do
      emit_node_start(execution, node_info, opts)
      log_node_event(:started, execution, node_info, attempt: attempt)

      try do
        result = fun.()
        duration_ms = monotonic_duration_ms(start_time)

        case result do
          {:ok, output} = success ->
            Tracer.set_attribute(:output_keys, output |> Map.keys() |> inspect())
            emit_node_stop(execution, node_info, :completed, duration_ms, opts)
            log_node_event(:completed, execution, node_info, duration_ms: duration_ms)
            success

          {:error, reason} = error ->
            record_span_error(reason)
            emit_node_stop(execution, node_info, :failed, duration_ms, opts)
            log_node_event(:failed, execution, node_info, duration_ms: duration_ms, error: reason)
            error

          {:skip, reason} ->
            Tracer.set_attribute(:skip_reason, inspect(reason))
            emit_node_stop(execution, node_info, :skipped, duration_ms, opts)
            log_node_event(:skipped, execution, node_info, reason: reason)
            {:skip, reason}
        end
      rescue
        e ->
          duration_ms = monotonic_duration_ms(start_time)
          record_span_exception(e, __STACKTRACE__)
          emit_node_exception(execution, node_info, e, duration_ms, opts)
          log_node_event(:exception, execution, node_info, duration_ms: duration_ms, error: e)
          reraise e, __STACKTRACE__
      end
    end
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

  defp emit_node_start(%Execution{} = execution, node_info, opts) do
    queue_time_ms = calculate_queue_time(opts)

    :telemetry.execute(
      [:imgd, :engine, :node, :start],
      %{system_time: System.system_time(), queue_time_ms: queue_time_ms},
      node_metadata(execution, node_info, opts)
    )
  end

  defp emit_node_stop(%Execution{} = execution, node_info, status, duration_ms, opts) do
    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: duration_ms},
      node_metadata(execution, node_info, opts) |> Map.put(:status, status)
    )
  end

  defp emit_node_exception(%Execution{} = execution, node_info, exception, duration_ms, opts) do
    :telemetry.execute(
      [:imgd, :engine, :node, :exception],
      %{duration_ms: duration_ms},
      node_metadata(execution, node_info, opts) |> Map.put(:exception, exception)
    )
  end

  # ============================================================================
  # Structured Logging
  # ============================================================================

  defp log_execution_event(event, %Execution{} = execution, extra \\ []) do
    level = log_level_for_event(event)
    message = execution_event_message(event)

    metadata =
      [
        event: "execution.#{event}",
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        trigger_type: Execution.trigger_type(execution)
      ] ++ extra

    Logger.log(level, message, metadata)
  end

  defp log_node_event(event, %Execution{} = execution, node_info, extra) do
    level = log_level_for_event(event)
    message = node_event_message(event, node_info)

    metadata =
      [
        event: "node.#{event}",
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        node_id: node_info.id,
        node_type_id: node_info.type_id,
        node_name: Map.get(node_info, :name, node_info.id)
      ] ++ extra

    Logger.log(level, message, metadata)
  end

  defp log_level_for_event(:exception), do: :error
  defp log_level_for_event(:failed), do: :warning
  defp log_level_for_event(_), do: :info

  defp execution_event_message(:started), do: "Workflow execution started"
  defp execution_event_message(:completed), do: "Workflow execution completed"
  defp execution_event_message(:failed), do: "Workflow execution failed"
  defp execution_event_message(:exception), do: "Workflow execution raised exception"

  defp node_event_message(:started, node), do: "Node #{node.id} started"
  defp node_event_message(:completed, node), do: "Node #{node.id} completed"
  defp node_event_message(:failed, node), do: "Node #{node.id} failed"
  defp node_event_message(:skipped, node), do: "Node #{node.id} skipped"
  defp node_event_message(:exception, node), do: "Node #{node.id} raised exception"

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

  defp node_span_attributes(%Execution{} = execution, node_info, opts) do
    base = %{
      "workflow.id": execution.workflow_id,
      "execution.id": execution.id,
      "node.id": node_info.id,
      "node.type_id": node_info.type_id,
      "node.name": Map.get(node_info, :name, node_info.id),
      "node.attempt": Keyword.get(opts, :attempt, 1)
    }

    case Keyword.get(opts, :input) do
      nil -> base
      input -> Map.put(base, "node.input_keys", input |> Map.keys() |> inspect())
    end
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

  defp node_metadata(%Execution{} = execution, node_info, opts) do
    %{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_version_id: execution.workflow_version_id,
      node_id: node_info.id,
      node_type_id: node_info.type_id,
      attempt: Keyword.get(opts, :attempt, 1)
    }
  end

  defp get_version_tag(%Execution{workflow_version: %{version_tag: tag}}), do: tag
  defp get_version_tag(_), do: nil

  defp calculate_queue_time(opts) do
    case Keyword.get(opts, :queued_at) do
      %DateTime{} = queued_at ->
        DateTime.diff(DateTime.utc_now(), queued_at, :millisecond)

      _ ->
        nil
    end
  end

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

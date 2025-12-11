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

  # ============================================================================
  # Instrumentation Helpers
  # ============================================================================

  @doc """
  Wraps a workflow execution in a traced span and emits start/stop/exception
  telemetry events.
  """
  def with_execution_span(%Execution{} = execution, workflow \\ nil, fun)
      when is_function(fun, 0) do
    span_name = "execution #{execution_span_name(workflow, execution)}"
    attributes = execution_attributes(execution, workflow)

    Tracer.with_span span_name, %{attributes: attributes, kind: :internal} do
      emit_execution_start(execution, workflow)
      start_time = System.monotonic_time()

      try do
        result = fun.()
        duration_ms = duration_since(start_time)
        status = execution_status_from_result(result, execution)

        set_span_status(status, result)
        emit_execution_stop(execution, workflow, status, duration_ms)

        result
      rescue
        exception ->
          duration_ms = duration_since(start_time)
          Span.record_exception(Tracer.current_span_ctx(), exception, __STACKTRACE__)
          Span.set_status(Tracer.current_span_ctx(), {:error, Exception.message(exception)})

          emit_execution_exception(execution, workflow, exception, __STACKTRACE__, duration_ms)
          reraise exception, __STACKTRACE__
      end
    end
  end

  @doc """
  Wraps a node execution in a traced span and emits node telemetry events.

  Accepts either a `NodeExecution` struct or a workflow node map/struct with
  `:id`, `:name`, and `:type_id` keys. Attempts and status can be overridden via
  options for cases like retries.
  """
  def with_node_span(%Execution{} = execution, node_info, fun) when is_function(fun, 0) do
    with_node_span(execution, node_info, [], fun)
  end

  def with_node_span(%Execution{} = execution, node_info, opts, fun) when is_function(fun, 0) do
    metadata = node_metadata(execution, node_info, opts)
    span_name = "node #{node_label(metadata)}"
    attributes = node_attributes(metadata)

    Tracer.with_span span_name, %{attributes: attributes, kind: :internal} do
      emit_node_start(metadata)
      start_time = System.monotonic_time()

      try do
        result = fun.()
        duration_ms = duration_since(start_time)

        {status, stop_meta} = node_status_from_result(result, metadata)
        combined_meta = Map.merge(metadata, stop_meta)

        set_span_status(status, result)
        emit_node_stop(combined_meta, status, duration_ms)

        result
      rescue
        exception ->
          duration_ms = duration_since(start_time)
          Span.record_exception(Tracer.current_span_ctx(), exception, __STACKTRACE__)
          Span.set_status(Tracer.current_span_ctx(), {:error, Exception.message(exception)})

          emit_node_exception(metadata, exception, __STACKTRACE__, duration_ms)
          reraise exception, __STACKTRACE__
      end
    end
  end

  @doc """
  Backwards compatible shim that delegates to `with_node_span/4`.
  """
  def with_step_span(%Execution{} = execution, node_info, opts \\ [], fun)
      when is_function(fun, 0) do
    with_node_span(execution, node_info, opts, fun)
  end

  # ============================================================================
  # Context Propagation
  # ============================================================================

  @doc """
  Extracts the current trace context for propagation to async jobs.
  """
  def extract_trace_context do
    case OpenTelemetry.Ctx.get_current() do
      :undefined -> nil
      ctx -> :otel_propagator_text_map.inject(ctx)
    end
  end

  @doc """
  Restores trace context from a propagated map.
  """
  def restore_trace_context(nil), do: :ok

  def restore_trace_context(context) when is_map(context) do
    ctx = :otel_propagator_text_map.extract(context)
    OpenTelemetry.Ctx.attach(ctx)
    :ok
  end

  @doc """
  Sets workflow context in Logger metadata for structured logging.
  """
  def set_log_context(%Execution{} = execution, workflow \\ nil) do
    metadata =
      [
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_name: workflow && workflow.name,
        workflow_version_id: execution.workflow_version_id,
        workflow_version_tag: workflow_version_tag(workflow, execution),
        trigger_type: trigger_type(execution)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Logger.metadata(metadata)
  end

  @doc """
  Sets node context in Logger metadata.
  """
  def set_node_log_context(%Execution{} = execution, node_info, opts \\ []) do
    metadata = node_metadata(execution, node_info, opts)

    [
      {:execution_id, metadata.execution_id},
      {:workflow_id, metadata.workflow_id},
      {:workflow_version_id, metadata.workflow_version_id},
      {:workflow_version_tag, metadata.workflow_version_tag},
      {:node_execution_id, metadata.node_execution_id},
      {:node_id, metadata.node_id},
      {:node_type_id, metadata.node_type_id},
      {:node_name, metadata.node_name},
      {:attempt, metadata.attempt}
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Logger.metadata()
  end

  # ============================================================================
  # Private: Event Emission
  # ============================================================================

  defp emit_execution_start(execution, workflow) do
    :telemetry.execute(
      [:imgd, :engine, :execution, :start],
      %{system_time: System.system_time()},
      %{
        execution: execution,
        workflow: workflow,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        workflow_version_tag: workflow_version_tag(workflow, execution),
        workflow_name: workflow && workflow.name,
        execution_id: execution.id,
        trigger_type: trigger_type(execution)
      }
    )
  end

  defp emit_execution_stop(execution, workflow, status, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :execution, :stop],
      %{duration_ms: duration_ms},
      %{
        execution: execution,
        workflow: workflow,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        workflow_version_tag: workflow_version_tag(workflow, execution),
        workflow_name: workflow && workflow.name,
        execution_id: execution.id,
        status: status,
        trigger_type: trigger_type(execution)
      }
    )
  end

  defp emit_execution_exception(execution, workflow, exception, stacktrace, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :execution, :exception],
      %{duration_ms: duration_ms},
      %{
        execution: execution,
        workflow: workflow,
        workflow_id: execution.workflow_id,
        workflow_version_id: execution.workflow_version_id,
        workflow_version_tag: workflow_version_tag(workflow, execution),
        execution_id: execution.id,
        exception: exception,
        stacktrace: stacktrace
      }
    )
  end

  defp emit_node_start(metadata) do
    :telemetry.execute(
      [:imgd, :engine, :node, :start],
      %{system_time: System.system_time()},
      %{
        node_execution: metadata.node_execution,
        execution: metadata.execution,
        execution_id: metadata.execution_id,
        workflow_id: metadata.workflow_id,
        workflow_version_id: metadata.workflow_version_id,
        workflow_version_tag: metadata.workflow_version_tag,
        node_execution_id: metadata.node_execution_id,
        node_id: metadata.node_id,
        node_type_id: metadata.node_type_id,
        node_name: metadata.node_name,
        attempt: metadata.attempt || 1
      }
    )
  end

  defp emit_node_stop(metadata, status, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: duration_ms},
      %{
        node_execution: metadata.node_execution,
        execution: metadata.execution,
        execution_id: metadata.execution_id,
        workflow_id: metadata.workflow_id,
        workflow_version_id: metadata.workflow_version_id,
        workflow_version_tag: metadata.workflow_version_tag,
        node_execution_id: metadata.node_execution_id,
        node_id: metadata.node_id,
        node_type_id: metadata.node_type_id,
        node_name: metadata.node_name,
        status: status,
        attempt: metadata.attempt || 1
      }
    )
  end

  defp emit_node_exception(metadata, exception, stacktrace, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :node, :exception],
      %{duration_ms: duration_ms},
      %{
        node_execution: metadata.node_execution,
        execution: metadata.execution,
        execution_id: metadata.execution_id,
        workflow_id: metadata.workflow_id,
        workflow_version_id: metadata.workflow_version_id,
        workflow_version_tag: metadata.workflow_version_tag,
        node_execution_id: metadata.node_execution_id,
        node_id: metadata.node_id,
        node_type_id: metadata.node_type_id,
        node_name: metadata.node_name,
        exception: exception,
        stacktrace: stacktrace,
        attempt: metadata.attempt || 1
      }
    )
  end

  # ============================================================================
  # Private: Attribute Building
  # ============================================================================

  defp execution_attributes(%Execution{} = execution, workflow) do
    %{
      "workflow.id": execution.workflow_id,
      "workflow.name": workflow && workflow.name,
      "workflow.version_id": execution.workflow_version_id,
      "workflow.version_tag": workflow_version_tag(workflow, execution),
      "execution.id": execution.id,
      "execution.status": execution.status,
      "execution.trigger_type": trigger_type(execution),
      "execution.triggered_by_user_id": execution.triggered_by_user_id
    }
    |> reject_nil_values()
  end

  defp node_attributes(metadata) do
    %{
      "workflow.id": metadata.workflow_id,
      "workflow.version_id": metadata.workflow_version_id,
      "workflow.version_tag": metadata.workflow_version_tag,
      "execution.id": metadata.execution_id,
      "node.execution_id": metadata.node_execution_id,
      "node.id": metadata.node_id,
      "node.type_id": metadata.node_type_id,
      "node.name": metadata.node_name,
      "node.attempt": metadata.attempt
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp workflow_version_tag(%WorkflowVersion{version_tag: tag}, _execution), do: tag

  defp workflow_version_tag(
         %Workflow{published_version: %WorkflowVersion{version_tag: tag}},
         _execution
       ),
       do: tag

  defp workflow_version_tag(%Workflow{current_version_tag: tag}, _execution) when is_binary(tag),
    do: tag

  defp workflow_version_tag(_workflow, %Execution{workflow_version_tag: tag}) when is_binary(tag),
    do: tag

  defp workflow_version_tag(_workflow, %Execution{
         workflow_version: %WorkflowVersion{version_tag: tag}
       }),
       do: tag

  defp workflow_version_tag(_workflow, %Execution{workflow_version_id: id}) when not is_nil(id),
    do: id

  defp workflow_version_tag(_workflow, _execution), do: nil

  defp trigger_type(%Execution{trigger_type: trigger_type}) when not is_nil(trigger_type),
    do: trigger_type

  defp trigger_type(%Execution{trigger: trigger}) when is_map(trigger) do
    Map.get(trigger, :type) || Map.get(trigger, "type")
  end

  defp trigger_type(_), do: nil

  defp execution_span_name(nil, %Execution{id: id}), do: id
  defp execution_span_name(%Workflow{name: name}, _execution) when is_binary(name), do: name
  defp execution_span_name(_workflow, %Execution{id: id}), do: id

  defp node_metadata(%Execution{} = execution, node_info, opts) do
    {node_id, node_type_id, node_name} = node_identity(node_info)
    attempt = Keyword.get(opts, :attempt) || attempt_from(node_info) || 1
    status = Keyword.get(opts, :status) || node_status(node_info)

    %{
      execution: execution,
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_version_id: execution.workflow_version_id,
      workflow_version_tag: workflow_version_tag(nil, execution),
      node_execution: node_execution_struct(node_info),
      node_execution_id: node_execution_id(node_info),
      node_id: node_id,
      node_type_id: node_type_id,
      node_name: node_name,
      attempt: attempt,
      status: status
    }
  end

  defp node_identity(%NodeExecution{node_id: node_id, node_type_id: node_type_id}) do
    {node_id, node_type_id, nil}
  end

  defp node_identity(%{node_id: node_id, node_type_id: node_type_id, node_name: node_name}) do
    {node_id, node_type_id, node_name}
  end

  defp node_identity(%{id: node_id, type_id: type_id} = node) do
    {node_id, type_id, Map.get(node, :name)}
  end

  defp node_identity(node) do
    {
      Map.get(node, :id) || Map.get(node, "id"),
      Map.get(node, :type_id) || Map.get(node, "type_id"),
      Map.get(node, :name) || Map.get(node, "name")
    }
  end

  defp node_label(metadata) do
    cond do
      metadata.node_name -> metadata.node_name
      metadata.node_id -> metadata.node_id
      true -> "node"
    end
  end

  defp node_execution_struct(%NodeExecution{} = node_execution), do: node_execution
  defp node_execution_struct(_), do: nil

  defp node_execution_id(%NodeExecution{id: id}), do: id
  defp node_execution_id(%{node_execution_id: id}) when not is_nil(id), do: id
  defp node_execution_id(_), do: nil

  defp attempt_from(%NodeExecution{attempt: attempt}), do: attempt
  defp attempt_from(%{attempt: attempt}), do: attempt
  defp attempt_from(_), do: nil

  defp node_status(%NodeExecution{status: status}), do: status
  defp node_status(%{status: status}), do: status
  defp node_status(_), do: nil

  defp execution_status_from_result({:ok, %Execution{status: status}}, _execution), do: status
  defp execution_status_from_result(%Execution{status: status}, _execution), do: status
  defp execution_status_from_result({:ok, _}, _execution), do: :completed
  defp execution_status_from_result(:ok, _execution), do: :completed
  defp execution_status_from_result({:error, _}, _execution), do: :failed

  defp execution_status_from_result(_result, %Execution{status: status}) when not is_nil(status),
    do: status

  defp execution_status_from_result(_result, _execution), do: :completed

  defp node_status_from_result({:error, reason}, metadata), do: {:failed, %{error: reason}}

  defp node_status_from_result({:ok, %NodeExecution{} = node_execution}, metadata) do
    status = node_execution.status || metadata.status || :completed

    {status,
     %{
       node_execution: node_execution,
       status: status,
       attempt: node_execution.attempt || metadata.attempt
     }}
  end

  defp node_status_from_result(%NodeExecution{} = node_execution, metadata) do
    status = node_execution.status || metadata.status || :completed

    {status,
     %{
       node_execution: node_execution,
       status: status,
       attempt: node_execution.attempt || metadata.attempt
     }}
  end

  defp node_status_from_result({:ok, result}, metadata) do
    {metadata.status || :completed, %{output_data: result}}
  end

  defp node_status_from_result(:ok, metadata), do: {metadata.status || :completed, %{}}
  defp node_status_from_result(_result, metadata), do: {metadata.status || :completed, %{}}

  defp set_span_status(status, {:error, reason}) do
    Span.set_status(Tracer.current_span_ctx(), {:error, inspect(reason)})
    Span.set_attribute(Tracer.current_span_ctx(), :"error.message", inspect(reason))
  end

  defp set_span_status(status, _result) do
    case status do
      status when status in [:failed, :cancelled, :timeout] ->
        Span.set_status(Tracer.current_span_ctx(), {:error, Atom.to_string(status)})

      _ ->
        Span.set_status(Tracer.current_span_ctx(), :ok)
    end
  end

  defp duration_since(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end
end

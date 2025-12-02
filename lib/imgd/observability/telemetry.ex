defmodule Imgd.Observability.Telemetry do
  @moduledoc """
  Telemetry event definitions and handlers for imgd observability.

  This module defines all telemetry events emitted by the workflow engine
  and sets up handlers for tracing, metrics, and logging integration.

  ## Event Naming Convention

  All events follow the pattern: `[:imgd, :domain, :action, :stage]`

  - domain: `engine`, `workflow`, `step`, `checkpoint`
  - action: specific operation being performed
  - stage: `start`, `stop`, `exception`

  ## Span Attributes

  Traces include these standard attributes:
  - `workflow.id` - UUID of the workflow definition
  - `workflow.name` - Human-readable workflow name
  - `execution.id` - UUID of this execution instance
  - `execution.status` - Current status (running, completed, failed, etc.)
  - `step.hash` - Unique hash of the step node
  - `step.name` - Human-readable step name
  - `step.type` - Type of step (Step, Condition, Accumulator, etc.)
  - `generation` - Current generation in the workflow graph
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Span

  # ============================================================================
  # Event Definitions
  # ============================================================================

  @doc """
  All telemetry events emitted by the imgd engine.
  """
  def events do
    [
      # Execution lifecycle
      [:imgd, :engine, :execution, :start],
      [:imgd, :engine, :execution, :stop],
      [:imgd, :engine, :execution, :exception],

      # Step execution
      [:imgd, :engine, :step, :start],
      [:imgd, :engine, :step, :stop],
      [:imgd, :engine, :step, :exception],

      # Checkpointing
      [:imgd, :engine, :checkpoint, :start],
      [:imgd, :engine, :checkpoint, :stop],

      # Generation advancement
      [:imgd, :engine, :generation, :complete],

      # Workflow preparation
      [:imgd, :engine, :prepare, :start],
      [:imgd, :engine, :prepare, :stop]
    ]
  end

  # ============================================================================
  # Instrumentation Helpers
  # ============================================================================

  @doc """
  Wraps a workflow execution in a traced span.

  Creates a root span for the entire workflow execution, with child spans
  for each step. Automatically handles errors and sets appropriate status.

  ## Example

      Telemetry.with_execution_span(execution, workflow, fn ->
        # Execute workflow logic
        {:ok, result}
      end)
  """
  def with_execution_span(execution, workflow, fun) when is_function(fun, 0) do
    span_name = "workflow.execute #{workflow.name || "unnamed"}"

    attributes = execution_attributes(execution, workflow)

    Tracer.with_span span_name, %{attributes: attributes, kind: :internal} do
      emit_execution_start(execution, workflow)
      start_time = System.monotonic_time()

      try do
        result = fun.()
        duration_ms = duration_since(start_time)

        case result do
          {:ok, _} = success ->
            Span.set_status(Tracer.current_span_ctx(), :ok)
            emit_execution_stop(execution, workflow, :completed, duration_ms)
            success

          {:error, reason} = error ->
            Span.set_status(Tracer.current_span_ctx(), {:error, inspect(reason)})
            Span.set_attribute(Tracer.current_span_ctx(), :"error.message", inspect(reason))
            emit_execution_stop(execution, workflow, :failed, duration_ms)
            error
        end
      rescue
        e ->
          duration_ms = duration_since(start_time)
          Span.record_exception(Tracer.current_span_ctx(), e, __STACKTRACE__)
          Span.set_status(Tracer.current_span_ctx(), {:error, Exception.message(e)})
          emit_execution_exception(execution, workflow, e, __STACKTRACE__, duration_ms)
          reraise e, __STACKTRACE__
      end
    end
  end

  @doc """
  Wraps a step execution in a traced span.

  Creates a child span under the current workflow execution span.
  Records step-specific attributes and timing.

  ## Example

      Telemetry.with_step_span(execution, node, fact, fn ->
        # Execute step logic
        {:ok, result}
      end)
  """
  def with_step_span(execution, node, fact, opts \\ [], fun) when is_function(fun, 0) do
    step_name = node.name || "step_#{node.hash}"
    span_name = "step.execute #{step_name}"

    attributes =
      step_attributes(execution, node, fact)
      |> Map.merge(%{
        "step.attempt": opts[:attempt] || 1,
        "step.generation": opts[:generation] || 0
      })

    Tracer.with_span span_name, %{attributes: attributes, kind: :internal} do
      emit_step_start(execution, node, fact, opts)
      start_time = System.monotonic_time()

      try do
        result = fun.()
        duration_ms = duration_since(start_time)

        case result do
          {:ok, workflow, events} ->
            output_fact = extract_output_fact(events)

            Span.set_attribute(
              Tracer.current_span_ctx(),
              :"step.output_fact_hash",
              output_fact.hash
            )

            Span.set_status(Tracer.current_span_ctx(), :ok)
            emit_step_stop(execution, node, fact, :completed, duration_ms, output_fact)
            {:ok, workflow, events}

          {:error, reason} = error ->
            Span.set_status(Tracer.current_span_ctx(), {:error, inspect(reason)})
            Span.set_attribute(Tracer.current_span_ctx(), :"error.message", inspect(reason))
            emit_step_stop(execution, node, fact, :failed, duration_ms, nil)
            error

          {:error, reason, workflow} ->
            Span.set_status(Tracer.current_span_ctx(), {:error, inspect(reason)})
            emit_step_stop(execution, node, fact, :failed, duration_ms, nil)
            {:error, reason, workflow}
        end
      rescue
        e ->
          duration_ms = duration_since(start_time)
          Span.record_exception(Tracer.current_span_ctx(), e, __STACKTRACE__)
          Span.set_status(Tracer.current_span_ctx(), {:error, Exception.message(e)})
          emit_step_exception(execution, node, fact, e, __STACKTRACE__, duration_ms)
          reraise e, __STACKTRACE__
      end
    end
  end

  @doc """
  Wraps checkpoint creation in a traced span.
  """
  def with_checkpoint_span(execution, reason, fun) when is_function(fun, 0) do
    span_name = "checkpoint.create"

    attributes = %{
      "execution.id": execution.id,
      "checkpoint.reason": reason
    }

    Tracer.with_span span_name, %{attributes: attributes, kind: :internal} do
      start_time = System.monotonic_time()

      :telemetry.execute([:imgd, :engine, :checkpoint, :start], %{}, %{
        execution: execution,
        reason: reason
      })

      result = fun.()
      duration_ms = duration_since(start_time)

      :telemetry.execute([:imgd, :engine, :checkpoint, :stop], %{duration_ms: duration_ms}, %{
        execution: execution,
        reason: reason,
        success: match?({:ok, _}, result)
      })

      result
    end
  end

  # ============================================================================
  # Context Propagation
  # ============================================================================

  @doc """
  Extracts the current trace context for propagation to async jobs.

  Use this when enqueuing Oban jobs to maintain trace continuity.

  ## Example

      trace_context = Telemetry.extract_trace_context()
      %{execution_id: id, trace_context: trace_context}
      |> StepWorker.new()
      |> Oban.insert()
  """
  def extract_trace_context do
    case OpenTelemetry.Ctx.get_current() do
      :undefined -> nil
      ctx -> :otel_propagator_text_map.inject(ctx)
    end
  end

  @doc """
  Restores trace context from a propagated map.

  Use this at the start of Oban job execution.

  ## Example

      def perform(%Oban.Job{args: %{"trace_context" => ctx}}) do
        Telemetry.restore_trace_context(ctx)
        # ... job logic with tracing continuity
      end
  """
  def restore_trace_context(nil), do: :ok

  def restore_trace_context(context) when is_map(context) do
    ctx = :otel_propagator_text_map.extract(context)
    OpenTelemetry.Ctx.attach(ctx)
    :ok
  end

  @doc """
  Sets workflow context in Logger metadata for structured logging.

  This ensures all logs within the current process include workflow context.
  """
  def set_log_context(execution, workflow \\ nil) do
    metadata =
      [
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        workflow_name: workflow && workflow.name,
        workflow_version: execution.workflow_version,
        trigger_type: execution.trigger_type
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Logger.metadata(metadata)
  end

  @doc """
  Sets step context in Logger metadata.
  """
  def set_step_log_context(execution, node, opts \\ []) do
    metadata =
      [
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_hash: node.hash,
        step_name: node.name,
        step_type: node.__struct__ |> Module.split() |> List.last(),
        generation: opts[:generation],
        attempt: opts[:attempt]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Logger.metadata(metadata)
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
        workflow_name: workflow.name,
        execution_id: execution.id,
        trigger_type: execution.trigger_type
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
        workflow_name: workflow.name,
        execution_id: execution.id,
        status: status,
        trigger_type: execution.trigger_type
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
        execution_id: execution.id,
        exception: exception,
        stacktrace: stacktrace
      }
    )
  end

  defp emit_step_start(execution, node, fact, opts) do
    :telemetry.execute(
      [:imgd, :engine, :step, :start],
      %{system_time: System.system_time()},
      %{
        execution: execution,
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_hash: node.hash,
        step_name: node.name,
        step_type: node.__struct__ |> Module.split() |> List.last(),
        input_fact_hash: fact.hash,
        generation: opts[:generation] || 0,
        attempt: opts[:attempt] || 1
      }
    )
  end

  defp emit_step_stop(execution, node, fact, status, duration_ms, output_fact) do
    :telemetry.execute(
      [:imgd, :engine, :step, :stop],
      %{duration_ms: duration_ms},
      %{
        execution: execution,
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_hash: node.hash,
        step_name: node.name,
        step_type: node.__struct__ |> Module.split() |> List.last(),
        input_fact_hash: fact.hash,
        output_fact_hash: output_fact && output_fact.hash,
        status: status,
        generation: 0,
        attempt: 1
      }
    )
  end

  defp emit_step_exception(execution, node, fact, exception, stacktrace, duration_ms) do
    :telemetry.execute(
      [:imgd, :engine, :step, :exception],
      %{duration_ms: duration_ms},
      %{
        execution: execution,
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        step_hash: node.hash,
        step_name: node.name,
        step_type: node.__struct__ |> Module.split() |> List.last(),
        input_fact_hash: fact.hash,
        exception: exception,
        stacktrace: stacktrace
      }
    )
  end

  # ============================================================================
  # Private: Attribute Building
  # ============================================================================

  defp execution_attributes(execution, workflow) do
    %{
      "workflow.id": execution.workflow_id,
      "workflow.name": workflow.name || "unnamed",
      "workflow.version": execution.workflow_version,
      "execution.id": execution.id,
      "execution.status": execution.status,
      "execution.trigger_type": execution.trigger_type,
      "execution.triggered_by_user_id": execution.triggered_by_user_id
    }
    |> reject_nil_values()
  end

  defp step_attributes(execution, node, fact) do
    step_type = node.__struct__ |> Module.split() |> List.last()

    %{
      "workflow.id": execution.workflow_id,
      "execution.id": execution.id,
      "step.hash": node.hash,
      "step.name": node.name || "step_#{node.hash}",
      "step.type": step_type,
      "step.input_fact_hash": fact.hash
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_output_fact(events) do
    Enum.find_value(events, %{hash: 0}, fn
      %Runic.Workflow.ReactionOccurred{reaction: :produced, to: fact} -> fact
      _ -> nil
    end)
  end

  defp duration_since(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end
end

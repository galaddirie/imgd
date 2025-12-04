defmodule Imgd.Engine.StepExecutor do
  @moduledoc """
  Executes individual workflow steps with error handling, timeouts, and observability.

  This module wraps Runic's `invoke/3` and `invoke_with_events/3` with:
  - Timeout enforcement
  - Exception catching and normalization
  - Telemetry events and OpenTelemetry spans
  - Structured logging with trace context
  - Step record persistence

  ## Observability

  Each step execution:
  - Creates an OpenTelemetry span with workflow/step attributes
  - Emits telemetry events for metrics collection
  - Logs structured JSON with trace_id for Loki correlation
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionStep}
  alias Imgd.Engine.DataFlow
  alias Imgd.Engine.DataFlow.Envelope
  alias Imgd.Observability.{Telemetry, StructuredLogger}

  require Logger

  @default_timeout_ms 30_000

  @type execute_opts :: [
          timeout_ms: pos_integer(),
          attempt: pos_integer(),
          generation: non_neg_integer()
        ]

  @type execute_result ::
          {:ok, Runic.Workflow.t(), [Runic.Workflow.ReactionOccurred.t()]}
          | {:error, term(), Runic.Workflow.t() | nil}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Executes a single step within a workflow.

  Creates a step record, executes via Runic with timeout, and persists results.
  All execution is wrapped in OpenTelemetry spans and emits telemetry events.

  Returns `{:ok, updated_workflow, events}` or `{:error, reason, workflow}`.
  """
  @spec execute(Execution.t(), Runic.Workflow.t(), term(), term(), execute_opts()) ::
          execute_result()
  def execute(%Execution{} = execution, workflow, node, fact, opts \\ []) do
    timeout_ms = opts[:timeout_ms] || get_step_timeout(execution, node)
    attempt = opts[:attempt] || 1
    generation = opts[:generation] || workflow.generations
    trace_id = trace_id_for_execution(execution)

    # Set logging context for this step
    Telemetry.set_step_log_context(execution, node, generation: generation, attempt: attempt)

    with {:ok, step} <- create_step_record(execution, node, fact, generation, attempt, trace_id) do
      # Execute with full observability (spans, metrics, logs)
      Telemetry.with_step_span(
        execution,
        node,
        fact,
        [generation: generation, attempt: attempt],
        fn ->
          StructuredLogger.step_started(execution, node, fact,
            generation: generation,
            attempt: attempt
          )

          result = execute_with_timeout(workflow, node, fact, timeout_ms)

          handle_result(result, execution, step, node, fact, timeout_ms, trace_id, [generation: generation, attempt: attempt])
        end
      )
    else
      {:error, changeset} ->
        Logger.error("Failed to create step record",
          execution_id: execution.id,
          step_hash: node.hash,
          errors: inspect(changeset.errors)
        )

        {:error, %{type: "step_record_invalid", errors: changeset.errors}, workflow}
    end
  end

  @doc """
  Executes a step without persistence (for testing or dry-runs).

  Returns `{:ok, workflow, events}` or `{:error, reason}`.
  """
  @spec execute_dry(Runic.Workflow.t(), term(), term(), keyword()) ::
          {:ok, Runic.Workflow.t(), list()} | {:error, term()}
  def execute_dry(workflow, node, fact, opts \\ []) do
    timeout_ms = opts[:timeout_ms] || @default_timeout_ms

    case execute_with_timeout(workflow, node, fact, timeout_ms) do
      {:ok, _workflow, _events} = success -> success
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Determines if a step should be retried based on the error and attempt count.
  """
  @spec should_retry?(term(), pos_integer(), term()) :: boolean()
  def should_retry?(node, attempt, _error) do
    max_attempts = get_max_attempts(node)
    attempt < max_attempts
  end

  @doc """
  Calculates the next retry delay using exponential backoff.
  """
  @spec retry_delay_ms(pos_integer(), keyword()) :: pos_integer()
  def retry_delay_ms(attempt, opts \\ []) do
    base_ms = opts[:base_delay_ms] || 1_000
    max_ms = opts[:max_delay_ms] || 60_000
    jitter = opts[:jitter] || true

    delay = min(base_ms * :math.pow(2, attempt - 1), max_ms) |> round()

    if jitter do
      jitter_range = div(delay, 4)
      delay + :rand.uniform(max(jitter_range, 1)) - div(jitter_range, 2)
    else
      delay
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp execute_with_timeout(workflow, node, fact, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          Logger.debug("StepExecutor.execute_with_timeout - before invoke_with_events",
            node_hash: node.hash,
            fact_hash: fact.hash,
            workflow_generations: workflow.generations,
            workflow_generations_type: inspect(workflow.generations.__struct__)
          )

          {updated_workflow, events} = Runic.Workflow.invoke_with_events(workflow, node, fact)

          Logger.debug("StepExecutor.execute_with_timeout - after invoke_with_events",
            node_hash: node.hash,
            fact_hash: fact.hash,
            updated_workflow_generations: updated_workflow.generations,
            updated_workflow_generations_type: inspect(updated_workflow.generations.__struct__),
            events_count: length(events)
          )

          {:ok, updated_workflow, events}
        rescue
          e ->
            {:error, {:exception, e, __STACKTRACE__}}
        catch
          kind, reason ->
            {:error, {:caught, kind, reason, __STACKTRACE__}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, {:timeout, timeout_ms}}
    end
  end

  defp handle_result({:ok, workflow, events}, execution, step, node, _fact, _timeout_ms, trace_id, opts) do
    output_fact = extract_output_fact(events)
    duration_ms = calculate_duration(step.started_at)

    # Update step record
    {:ok, _step} =
      Workflows.complete_step(step, output_fact, duration_ms, trace_id: trace_id)

    # Log completion
    StructuredLogger.step_completed(execution, node, duration_ms, output_fact, opts)

    {:ok, workflow, events}
  end

  defp handle_result(
         {:error, {:timeout, timeout_ms} = reason},
         execution,
         step,
         node,
         _fact,
         _timeout_ms,
         _trace_id,
         _opts
       ) do
    duration_ms = calculate_duration(step.started_at)

    # Update step record with error
    {:ok, _step} = Workflows.fail_step(step, normalize_error(reason), duration_ms)

    # Log timeout
    StructuredLogger.step_timeout(execution, node, timeout_ms)

    {:error, reason, nil}
  end

  defp handle_result({:error, reason}, execution, step, node, _fact, _timeout_ms, _trace_id, _opts) do
    duration_ms = calculate_duration(step.started_at)

    # Update step record with error
    {:ok, _step} = Workflows.fail_step(step, normalize_error(reason), duration_ms)

    # Log failure
    StructuredLogger.step_failed(execution, node, reason, duration_ms)

    {:error, reason, nil}
  end

  defp create_step_record(execution, node, fact, generation, attempt, trace_id) do
    step_name = ExecutionStep.step_name(node)
    input_snapshot = snapshot_fact(fact, trace_id, %{step_hash: node.hash, step_name: step_name})

    step_attrs = %{
      execution_id: execution.id,
      step_hash: node.hash,
      step_name: step_name,
      step_type: node.__struct__ |> Module.split() |> List.last(),
      generation: generation,
      input_fact_hash: fact_hash(fact),
      input_snapshot: input_snapshot,
      attempt: attempt,
      max_attempts: get_max_attempts(node)
    }

    %ExecutionStep{}
    |> ExecutionStep.changeset(step_attrs)
    |> Repo.insert()
    |> case do
      {:ok, step} ->
        {:ok, _} = Workflows.start_step(step)

      error ->
        error
    end
  end

  defp extract_output_fact(events) do
    events
    |> Enum.find_value(fn
      %Runic.Workflow.ReactionOccurred{reaction: :produced, to: fact} -> fact
      _ -> nil
    end) || %Runic.Workflow.Fact{value: nil, hash: 0}
  end

  defp normalize_error({:exception, e, stacktrace}) do
    %{
      type: inspect(e.__struct__),
      message: Exception.message(e),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 5000)
    }
  end

  defp normalize_error({:timeout, timeout_ms}) do
    %{
      type: "timeout",
      message: "Step execution timed out after #{timeout_ms}ms"
    }
  end

  defp normalize_error({:caught, kind, reason, stacktrace}) do
    %{
      type: "#{kind}",
      message: inspect(reason),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 5000)
    }
  end

  defp normalize_error(reason) when is_map(reason), do: reason
  defp normalize_error(reason), do: %{message: inspect(reason)}

  defp snapshot_fact(fact, trace_id, metadata) do
    fact
    |> Envelope.from_fact(:step, trace_id, metadata)
    |> Envelope.to_map()
    |> DataFlow.snapshot()
  end

  defp fact_hash(%Runic.Workflow.Fact{hash: hash}), do: hash
  defp fact_hash(%{hash: hash}), do: hash
  defp fact_hash(_), do: nil

  defp trace_id_for_execution(%Execution{metadata: metadata}) do
    metadata["trace_id"] || metadata[:trace_id] || DataFlow.generate_trace_id()
  end

  defp trace_id_for_execution(_), do: DataFlow.generate_trace_id()

  defp get_step_timeout(%Execution{} = execution, node) do
    node_timeout = Map.get(node, :timeout_ms)
    execution_timeout = get_in(execution.workflow.settings, [:timeout_ms])

    node_timeout || execution_timeout || @default_timeout_ms
  end

  defp get_max_attempts(node) do
    case Map.get(node, :retry_policy) do
      %{max_attempts: n} -> n
      _ -> 1
    end
  end

  defp calculate_duration(nil), do: 0

  defp calculate_duration(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
  end
end

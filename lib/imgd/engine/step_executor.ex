defmodule Imgd.Engine.StepExecutor do
  @moduledoc """
  Executes individual workflow steps with error handling, timeouts, and observability.

  This module wraps Runic's `invoke/3` and `invoke_with_events/3` with:
  - Timeout enforcement
  - Exception catching and normalization
  - Telemetry events and spans
  - Structured logging
  - Step record persistence

  ## Execution Flow

  1. Create `ExecutionStep` record in `:running` status
  2. Emit telemetry start event and begin span
  3. Execute the step via Runic with timeout
  4. Update step record with results
  5. Emit telemetry stop event and end span
  6. Return result for checkpoint/continuation

  ## Error Handling

  Errors are captured and normalized into a consistent format:
  - Exceptions are caught and converted to error maps
  - Timeouts are handled gracefully
  - All errors include structured metadata for debugging
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionStep}

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

  Returns `{:ok, updated_workflow, events}` or `{:error, reason, workflow}`.
  """
  @spec execute(Execution.t(), Runic.Workflow.t(), term(), term(), execute_opts()) ::
          execute_result()
  def execute(%Execution{} = execution, workflow, node, fact, opts \\ []) do
    timeout_ms = opts[:timeout_ms] || get_step_timeout(execution, node)
    attempt = opts[:attempt] || 1
    generation = opts[:generation] || workflow.generations

    # Build execution context for observability
    ctx = build_context(execution, workflow, node, fact, attempt, generation)

    # Create step record
    {:ok, step} = create_step_record(execution, node, fact, generation, attempt)

    # Execute with telemetry and tracing
    result = execute_with_observability(ctx, step, fn ->
      execute_with_timeout(workflow, node, fact, timeout_ms)
    end)

    # Persist results and return
    handle_result(result, step, ctx)
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
    task = Task.async(fn ->
      try do
        {updated_workflow, events} = Runic.Workflow.invoke_with_events(workflow, node, fact)
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

  defp execute_with_observability(ctx, step, fun) do
    start_time = System.monotonic_time()

    # TODO: add observability

    # TODO: add observability

    try do
      result = fun.()
      duration_ms = duration_since(start_time)

      case result do
        {:ok, workflow, events} ->
          # TODO: add observability
          {:ok, workflow, events, duration_ms}

        {:error, reason} ->
          # TODO: add observability
          {:error, reason, duration_ms}
      end
    rescue
      e ->
        duration_ms = duration_since(start_time)
        # TODO: add observability
        {:error, {:exception, e, __STACKTRACE__}, duration_ms}
    end
  end

  defp handle_result({:ok, workflow, events, duration_ms}, step, ctx) do
    # Extract the output fact from events
    output_fact = extract_output_fact(events)

    # Update step record
    {:ok, _step} = Workflows.complete_step(step, output_fact, duration_ms)

    # TODO: add observability

    {:ok, workflow, events}
  end

  defp handle_result({:error, reason, duration_ms}, step, ctx) do
    # Update step record with error
    {:ok, _step} = Workflows.fail_step(step, normalize_error(reason), duration_ms)

    # TODO: add observability

    {:error, reason, nil}
  end

  defp create_step_record(execution, node, fact, generation, attempt) do
    step_attrs = %{
      execution_id: execution.id,
      step_hash: node.hash,
      step_name: node.name || "step_#{node.hash}",
      step_type: node.__struct__ |> Module.split() |> List.last(),
      generation: generation,
      input_fact_hash: fact.hash,
      input_snapshot: snapshot_value(fact.value),
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

  defp build_context(execution, workflow, node, fact, attempt, generation) do
    %{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_name: workflow.name,
      step_name: node.name || "step_#{node.hash}",
      step_hash: node.hash,
      step_type: node.__struct__ |> Module.split() |> List.last(),
      fact_hash: fact.hash,
      attempt: attempt,
      generation: generation,
      triggered_by_user_id: execution.triggered_by_user_id
    }
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

  defp snapshot_value(value) do
    try do
      encoded = Jason.encode!(value)

      if byte_size(encoded) > 10_000 do
        %{_truncated: true, _size: byte_size(encoded), _preview: String.slice(encoded, 0, 1000)}
      else
        value
      end
    rescue
      _ -> %{_type: "non_json_encodable", _inspect: inspect(value) |> String.slice(0, 1000)}
    end
  end

  defp get_step_timeout(%Execution{} = execution, node) do
    # Check node-level timeout first, then execution settings
    node_timeout = Map.get(node, :timeout_ms)
    execution_timeout = get_in(execution.settings, [:timeout_ms])

    node_timeout || execution_timeout || @default_timeout_ms
  end

  defp get_max_attempts(node) do
    case Map.get(node, :retry_policy) do
      %{max_attempts: n} -> n
      _ -> 1
    end
  end

  defp duration_since(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end
end

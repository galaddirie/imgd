defmodule Imgd.Observability.StructuredLogger do
  @moduledoc """
  Structured logging helpers for the imgd workflow engine.

  Provides consistent, structured log messages that include:
  - Trace context (trace_id, span_id) for correlation with Tempo
  - Workflow context (workflow_id, execution_id, step identifiers)
  - Timing and status information

  All logs are JSON-formatted via LoggerJSON, making them easily
  queryable in Loki/Grafana.

  ## Usage

      alias Imgd.Observability.StructuredLogger

      # Log execution events
      StructuredLogger.execution_started(execution, workflow)
      StructuredLogger.execution_completed(execution, workflow, duration_ms)

      # Log step events
      StructuredLogger.step_started(execution, node, fact)
      StructuredLogger.step_completed(execution, node, duration_ms, output)

  ## Log Levels

  - `:info` - Normal operations (start, complete)
  - `:warning` - Retries, timeouts, recoverable errors
  - `:error` - Failures, exceptions
  - `:debug` - Detailed execution state (checkpoints, runnables)
  """

  require Logger

  # ============================================================================
  # Execution Logging
  # ============================================================================

  @doc """
  Logs the start of a workflow execution.
  """
  def execution_started(execution, workflow) do
    Logger.info("Workflow execution started",
      event: "execution.started",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_name: workflow.name,
      workflow_version: execution.workflow_version,
      trigger_type: execution.trigger_type,
      triggered_by_user_id: execution.triggered_by_user_id
    )
  end

  @doc """
  Logs successful completion of a workflow execution.
  """
  def execution_completed(execution, workflow, duration_ms) do
    Logger.info("Workflow execution completed",
      event: "execution.completed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_name: workflow.name,
      duration_ms: duration_ms,
      final_generation: execution.current_generation,
      stats: execution.stats
    )
  end

  @doc """
  Logs a failed workflow execution.
  """
  def execution_failed(execution, workflow, error, duration_ms) do
    Logger.error("Workflow execution failed",
      event: "execution.failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_name: workflow.name,
      duration_ms: duration_ms,
      error: format_error(error),
      generation_at_failure: execution.current_generation
    )
  end

  @doc """
  Logs a workflow execution exception.
  """
  def execution_exception(execution, workflow, exception, stacktrace) do
    Logger.error("Workflow execution raised exception",
      event: "execution.exception",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_name: workflow && workflow.name,
      exception_type: exception.__struct__ |> Module.split() |> List.last(),
      exception_message: Exception.message(exception),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 2000)
    )
  end

  @doc """
  Logs execution resumption from checkpoint.
  """
  def execution_resumed(execution, checkpoint) do
    Logger.info("Workflow execution resumed from checkpoint",
      event: "execution.resumed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      checkpoint_id: checkpoint.id,
      resumed_at_generation: checkpoint.generation,
      pending_runnables_count: length(checkpoint.pending_runnables)
    )
  end

  # ============================================================================
  # Step Logging
  # ============================================================================

  @doc """
  Logs the start of a step execution.
  """
  def step_started(execution, node, fact, opts \\ []) do
    Logger.info("Step execution started",
      event: "step.started",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      step_type: node.__struct__ |> Module.split() |> List.last(),
      input_fact_hash: fact.hash,
      generation: opts[:generation],
      attempt: opts[:attempt] || 1
    )
  end

  @doc """
  Logs successful step completion.
  """
  def step_completed(execution, node, duration_ms, output_fact) do
    Logger.info("Step execution completed",
      event: "step.completed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      step_type: node.__struct__ |> Module.split() |> List.last(),
      duration_ms: duration_ms,
      output_fact_hash: output_fact && output_fact.hash
    )
  end

  @doc """
  Logs a step failure.
  """
  def step_failed(execution, node, error, duration_ms) do
    Logger.error("Step execution failed",
      event: "step.failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      step_type: node.__struct__ |> Module.split() |> List.last(),
      duration_ms: duration_ms,
      error: format_error(error)
    )
  end

  @doc """
  Logs that a step will be retried.
  """
  def step_will_retry(execution, node, attempt, error) do
    Logger.warning("Step execution will retry",
      event: "step.retry_scheduled",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      current_attempt: attempt,
      max_attempts: get_max_attempts(node),
      error: format_error(error)
    )
  end

  @doc """
  Logs that a step permanently failed after exhausting retries.
  """
  def step_permanently_failed(execution, node, error) do
    Logger.error("Step permanently failed after exhausting retries",
      event: "step.permanently_failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      max_attempts: get_max_attempts(node),
      error: format_error(error)
    )
  end

  @doc """
  Logs a step timeout.
  """
  def step_timeout(execution, node, timeout_ms) do
    Logger.error("Step execution timed out",
      event: "step.timeout",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      step_hash: node.hash,
      step_name: node.name,
      timeout_ms: timeout_ms
    )
  end

  # ============================================================================
  # Checkpoint Logging
  # ============================================================================

  @doc """
  Logs checkpoint creation.
  """
  def checkpoint_created(execution, checkpoint, duration_ms) do
    Logger.debug("Checkpoint created",
      event: "checkpoint.created",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      checkpoint_id: checkpoint.id,
      generation: checkpoint.generation,
      reason: checkpoint.reason,
      size_bytes: checkpoint.size_bytes,
      duration_ms: duration_ms,
      pending_runnables_count: length(checkpoint.pending_runnables)
    )
  end

  @doc """
  Logs checkpoint restoration.
  """
  def checkpoint_restored(execution, checkpoint) do
    Logger.debug("Checkpoint restored",
      event: "checkpoint.restored",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      checkpoint_id: checkpoint.id,
      generation: checkpoint.generation
    )
  end

  @doc """
  Logs checkpoint creation failure.
  """
  def checkpoint_failed(execution, reason, error) do
    Logger.warning("Checkpoint creation failed",
      event: "checkpoint.failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      reason: reason,
      error: format_error(error)
    )
  end

  # ============================================================================
  # Generation Logging
  # ============================================================================

  @doc """
  Logs generation completion.
  """
  def generation_completed(execution, generation, steps_count, duration_ms) do
    Logger.info("Generation completed",
      event: "generation.completed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      generation: generation,
      steps_executed: steps_count,
      duration_ms: duration_ms
    )
  end

  @doc """
  Logs runnables found for next generation.
  """
  def runnables_found(execution, generation, runnables) do
    Logger.debug("Runnables found for next generation",
      event: "generation.runnables_found",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      generation: generation,
      runnable_count: length(runnables),
      runnables:
        Enum.map(runnables, fn {node, fact} ->
          %{step_hash: node.hash, step_name: node.name, fact_hash: fact.hash}
        end)
    )
  end

  # ============================================================================
  # Worker Logging
  # ============================================================================

  @doc """
  Logs Oban worker job start.
  """
  def worker_started(worker_type, job_id, args) do
    Logger.info("Worker job started",
      event: "worker.started",
      worker_type: worker_type,
      job_id: job_id,
      execution_id: args["execution_id"],
      step_hash: args["node_hash"]
    )
  end

  @doc """
  Logs Oban worker job completion.
  """
  def worker_completed(worker_type, job_id, duration_ms) do
    Logger.info("Worker job completed",
      event: "worker.completed",
      worker_type: worker_type,
      job_id: job_id,
      duration_ms: duration_ms
    )
  end

  @doc """
  Logs Oban worker job failure.
  """
  def worker_failed(worker_type, job_id, error) do
    Logger.error("Worker job failed",
      event: "worker.failed",
      worker_type: worker_type,
      job_id: job_id,
      error: format_error(error)
    )
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp format_error(error) when is_map(error), do: error

  defp format_error({:exception, e, stacktrace}) do
    %{
      type: e.__struct__ |> Module.split() |> List.last(),
      message: Exception.message(e),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 1000)
    }
  end

  defp format_error({:timeout, timeout_ms}), do: %{type: "timeout", timeout_ms: timeout_ms}
  defp format_error(error) when is_binary(error), do: %{message: error}
  defp format_error(error), do: %{message: inspect(error)}

  defp get_max_attempts(%{retry_policy: %{max_attempts: n}}), do: n
  defp get_max_attempts(_), do: 1
end

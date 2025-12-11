defmodule Imgd.Workers.ExecutionWorker do
  @moduledoc """
  Oban worker for executing workflows.

  This worker is the entry point for all workflow executions. It:

  1. Extracts OpenTelemetry trace context from job args
  2. Loads the execution with preloaded workflow version
  3. Delegates to WorkflowRunner.run/1
  4. Returns appropriate Oban result

  ## Job Arguments

  - `execution_id` - The UUID of the execution to run
  - `trace_context` - Serialized OpenTelemetry context for distributed tracing

  ## Configuration

  - Queue: `:executions`
  - Max attempts: 1 (manual retry only per design decision)
  - Unique: prevents duplicate jobs for same execution within 60 seconds
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 1,
    unique: [period: 60, keys: [:execution_id]]

  require Logger

  alias Imgd.Repo
  alias Imgd.Executions.Execution
  alias Imgd.Runtime.WorkflowRunner
  alias Imgd.Observability.Instrumentation

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    execution_id = Map.fetch!(args, "execution_id")

    # Extract and restore trace context for distributed tracing
    Instrumentation.extract_trace_context(args)

    Logger.metadata(execution_id: execution_id)
    Logger.info("Starting workflow execution job")

    case load_execution(execution_id) do
      {:ok, execution} ->
        run_execution(execution)

      {:error, :not_found} ->
        Logger.error("Execution not found", execution_id: execution_id)
        {:cancel, "Execution not found: #{execution_id}"}

      {:error, :already_terminal} ->
        Logger.info("Execution already in terminal state, skipping")
        :ok
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_execution(execution_id) do
    case Repo.get(Execution, execution_id) do
      nil ->
        {:error, :not_found}

      %Execution{status: status} when status in [:completed, :failed, :cancelled, :timeout] ->
        {:error, :already_terminal}

      %Execution{} = execution ->
        # Preload required associations
        execution =
          Repo.preload(execution, [
            :workflow,
            workflow_version: [:workflow]
          ])

        {:ok, execution}
    end
  end

  defp run_execution(%Execution{} = execution) do
    case WorkflowRunner.run(execution) do
      {:ok, %Execution{status: :completed}} ->
        Logger.info("Workflow execution completed successfully",
          execution_id: execution.id
        )

        :ok

      {:ok, %Execution{status: :timeout}} ->
        Logger.warning("Workflow execution timed out",
          execution_id: execution.id
        )

        # Return :ok since timeout is handled - we don't want Oban to retry
        :ok

      {:ok, %Execution{status: status}} ->
        Logger.info("Workflow execution finished with status: #{status}",
          execution_id: execution.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Workflow execution failed",
          execution_id: execution.id,
          error: inspect(reason)
        )

        # Return error to let Oban know the job failed
        # Since max_attempts is 1, this won't retry
        {:error, inspect(reason)}
    end
  end

  # ============================================================================
  # Job Creation Helpers
  # ============================================================================

  @doc """
  Creates job args for an execution.

  Includes trace context propagation for distributed tracing.
  """
  def build_args(execution_id, opts \\ []) do
    base_args = %{
      "execution_id" => execution_id
    }

    # Add trace context if available
    trace_ctx = Instrumentation.serialize_trace_context()

    args =
      if map_size(trace_ctx) > 0 do
        Map.put(base_args, "trace_context", trace_ctx)
      else
        base_args
      end

    # Add any additional metadata
    case Keyword.get(opts, :metadata) do
      nil -> args
      metadata when is_map(metadata) -> Map.merge(args, metadata)
    end
  end

  @doc """
  Creates a new Oban job for the given execution.

  Returns `{:ok, job}` or `{:error, changeset}`.

  ## Options

  - `:scheduled_at` - Schedule the job for a future time
  - `:priority` - Job priority (0-3, lower is higher priority)
  - `:metadata` - Additional metadata to include in job args
  """
  def new_job(execution_id, opts \\ []) do
    args = build_args(execution_id, opts)

    job_opts =
      opts
      |> Keyword.take([:scheduled_at, :priority])
      |> Keyword.put_new(:priority, 1)

    job_opts = Keyword.put(job_opts, :args, args)

    __MODULE__
    |> Oban.Job.new(job_opts)
  end

  @doc """
  Inserts a job for the given execution.

  Returns `{:ok, job}` or `{:error, changeset}`.
  """
  def enqueue(execution_id, opts \\ []) do
    execution_id
    |> new_job(opts)
    |> Oban.insert()
  end
end

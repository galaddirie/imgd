defmodule Imgd.Workers.ExecutionWorker do
  @moduledoc """
  Oban worker for executing workflows.

  ## Role in Architecture

  This is the **job queue entry point** — a thin wrapper that handles async/background job concerns:

  - Receives Oban jobs from the queue
  - Extracts and restores OpenTelemetry trace context for distributed tracing
  - Loads the Execution record with preloaded associations
  - Guards against re-running terminal executions (completed/failed/cancelled/timeout)
  - Delegates actual workflow execution to `WorkflowRunner.run/1`
  - Returns Oban-compatible results (:ok, {:error, ...}, {:cancel, ...})

  ## Separation of Concerns

  Unlike `WorkflowRunner` which is the core execution engine, this worker focuses on:

  | Concern | ExecutionWorker | WorkflowRunner |
  |---------|-----------------|----------------|
  | Job queuing/retries | ✓ | |
  | Trace context propagation | ✓ | |
  | Loading records from DB | ✓ | |
  | Execution state machine | | ✓ |
  | Timeout handling | | ✓ |
  | PubSub broadcasts | | ✓ |
  | Runic integration | | ✓ |

  This separation allows `WorkflowRunner.run/1` to be called directly for synchronous execution
  (like in tests or preview mode) while this worker provides the production async execution path.

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

  alias Imgd.Observability.Instrumentation

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    execution_id = Map.fetch!(args, "execution_id")

    # Extract and restore trace context for distributed tracing
    Instrumentation.extract_trace_context(args)

    Logger.metadata(execution_id: execution_id)
    Logger.info("Starting workflow execution job")

    # Start the execution process (or attach to existing)
    case Imgd.Runtime.Execution.Supervisor.start_execution(execution_id) do
      {:ok, pid} ->
        monitor_and_wait(pid, execution_id)

      {:error, {:already_started, pid}} ->
        Logger.info("Execution already running, attaching", execution_id: execution_id)
        monitor_and_wait(pid, execution_id)

      {:error, reason} ->
        Logger.error("Failed to start execution process",
          execution_id: execution_id,
          reason: inspect(reason)
        )

        # Will retry if max_attempts > 1, but configured to 1
        {:error, reason}
    end
  end

  defp monitor_and_wait(pid, execution_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        # Execution completed explicitly (Server stops with :normal on finish)
        Logger.info("Execution process finished normally", execution_id: execution_id)
        :ok

      {:DOWN, ^ref, :process, _pid, :shutdown} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        Logger.error("Execution process crashed or failed",
          execution_id: execution_id,
          reason: inspect(reason)
        )

        {:error, reason}
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

    __MODULE__.new(args, job_opts)
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

defmodule Imgd.Workers.StepWorker do
  @moduledoc """
  Oban worker for executing individual workflow steps.

  This worker handles the fine-grained execution of a single step:
  1. Load execution and latest checkpoint
  2. Reconstruct workflow state
  3. Find and execute the specific step
  4. Persist step results
  5. Update checkpoint with new workflow state
  6. Trigger continuation if this was the last step in generation

  ## Job Arguments

  - `execution_id` (required) - The execution this step belongs to
  - `node_hash` (required) - Hash of the node (step) to execute
  - `fact_hash` (required) - Hash of the input fact
  - `generation` (optional) - Current generation number
  - `generation_id` (optional) - Unique ID for this generation batch
  - `attempt` (optional) - Current attempt number (for retries)

  ## Error Handling

  - Transient errors trigger Oban retries with backoff
  - Permanent errors are recorded and may trigger execution failure
  - Per-step retry policies are respected

  ## Coordination

  When a step completes, this worker checks if it was the last step
  in the current generation. If so, it triggers ExecutionWorker to
  continue to the next generation.
  """

  use Oban.Worker,
    queue: :steps,
    max_attempts: 5,
    priority: 1

  alias Imgd.Repo
  alias Imgd.Workflows.{Execution, ExecutionStep}
  alias Imgd.Engine.{Runner, StepExecutor}

  require Logger

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: oban_attempt}) do
    execution_id = args["execution_id"]
    node_hash = args["node_hash"]
    fact_hash = args["fact_hash"]
    generation = args["generation"] || 0
    generation_id = args["generation_id"]
    attempt = args["attempt"] || oban_attempt

    with {:ok, execution} <- load_execution(execution_id),
         :ok <- validate_runnable(execution),
         {:ok, state} <- prepare_state(execution),
         {:ok, {node, fact}} <- Runner.find_runnable(state, node_hash, fact_hash) do
      execute_step(state, node, fact, generation, generation_id, attempt)
    end
  end

  @impl Oban.Worker
  def timeout(%Oban.Job{args: args}) do
    # TODO: Could make this configurable per-step
    timeout_ms = args["timeout_ms"] || :timer.minutes(5)
    timeout_ms
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base = 1
    max_delay = 60
    delay = min(base * :math.pow(2, attempt - 1), max_delay) |> round()

    jitter = :rand.uniform(max(div(delay, 4), 1))
    delay + jitter
  end

  # ============================================================================
  # Public API for job creation
  # ============================================================================

  @doc """
  Enqueues a job to execute a specific step.
  """
  @spec enqueue(String.t(), integer(), integer(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(execution_id, node_hash, fact_hash, opts \\ []) do
    args =
      %{
        "execution_id" => execution_id,
        "node_hash" => node_hash,
        "fact_hash" => fact_hash,
        "generation" => opts[:generation],
        "generation_id" => opts[:generation_id],
        "attempt" => opts[:attempt] || 1,
        "timeout_ms" => opts[:timeout_ms]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    args
    |> new(Keyword.drop(opts, [:generation, :generation_id, :attempt, :timeout_ms]))
    |> Oban.insert()
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp load_execution(execution_id) do
    case Repo.get(Execution, execution_id) do
      nil -> {:error, :execution_not_found}
      execution -> {:ok, Repo.preload(execution, :workflow)}
    end
  end

  defp validate_runnable(%Execution{status: status}) do
    case status do
      :running -> :ok
      :pending -> :ok
      other -> {:error, {:invalid_status, other}}
    end
  end

  defp prepare_state(execution) do
    Runner.prepare(execution, :continue)
  end

  defp execute_step(state, node, fact, generation, generation_id, attempt) do
    %{execution: execution, workflow: workflow} = state

    opts = [
      timeout_ms: get_step_timeout(execution, node),
      attempt: attempt,
      generation: generation
    ]

    case StepExecutor.execute(execution, workflow, node, fact, opts) do
      {:ok, updated_workflow, _events} ->
        handle_step_success(state, updated_workflow, generation, generation_id)

      {:error, reason, _workflow} ->
        handle_step_failure(state, node, fact, reason, attempt, generation, generation_id)
    end
  end

  defp handle_step_success(state, updated_workflow, generation, generation_id) do
    %{execution: _execution} = state

    # Advance the runner state
    {:ok, new_state} = Runner.advance(state, updated_workflow)

    # Check if this generation is complete
    check_generation_completion(new_state, generation, generation_id)
  end

  defp handle_step_failure(state, node, _fact, reason, attempt, _generation, _generation_id) do
    %{execution: execution} = state

    # Check if we should retry
    if StepExecutor.should_retry?(node, attempt, reason) do
      # Let Oban handle the retry
      # TODO: Restore observability - StructuredLogger.step_will_retry(execution, node, attempt, reason)
      {:snooze, StepExecutor.retry_delay_ms(attempt)}
    else
      # Permanent failure - fail the execution
      Imgd.Observability.StructuredLogger.step_permanently_failed(execution, node, reason)

      # Mark execution as failed
      Runner.fail(state, reason)

      # Cancel any pending steps for this execution
      cancel_pending_steps(execution)

      {:error, {:step_failed, reason}}
    end
  end

  defp check_generation_completion(state, generation, _generation_id) do
    %{execution: execution} = state

    # Count pending/running steps for this generation
    pending_count = count_pending_steps(execution.id, generation)

    if pending_count <= 1 do
      # This is the last step (or only step) - trigger next generation
      trigger_next_generation(execution)
    end

    :ok
  end

  defp count_pending_steps(execution_id, generation) do
    ExecutionStep
    |> where(execution_id: ^execution_id, generation: ^generation)
    |> where([s], s.status in [:pending, :running])
    |> Repo.aggregate(:count)
  end

  defp trigger_next_generation(%Execution{id: _execution_id}) do
    # Small delay to allow concurrent steps to finish checkpoint writes
    # TODO: Implement ExecutionWorker.enqueue_continue/2
    # ExecutionWorker.enqueue_continue(execution_id, schedule_in: 1)
    :ok
  end

  defp cancel_pending_steps(%Execution{id: execution_id}) do
    # Find and cancel any pending Oban jobs for this execution
    Oban.Job
    |> where([j], j.queue == "steps")
    |> where([j], j.state in ["available", "scheduled"])
    |> where([j], fragment("?->>'execution_id' = ?", j.args, ^execution_id))
    |> Repo.all()
    |> Enum.each(&Oban.cancel_job/1)
  end

  defp get_step_timeout(%Execution{} = execution, node) do
    node_timeout = Map.get(node, :timeout_ms)
    execution_timeout = get_in(execution.workflow.settings, [:timeout_ms])
    node_timeout || execution_timeout || :timer.minutes(5)
  end
end

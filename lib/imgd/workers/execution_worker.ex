defmodule Imgd.Workers.ExecutionWorker do
  @moduledoc """
  Oban worker for orchestrating workflow execution.

  This worker handles high-level execution coordination:
  - Start new executions: Load workflow, plan input, enqueue step jobs
  - Continue executions: After a generation completes, find next runnables
  - Resume executions: Resume paused or failed executions from checkpoint
  - Complete/fail executions: Handle terminal states

  ## Job Arguments

  - `execution_id` (required) - The execution to process
  - `mode` (optional) - Execution mode: "start", "continue", "resume" (default: "continue")
  - `generation_id` (optional) - Unique ID for current generation batch

  ## Execution Flow

  1. `enqueue_start/2` is called after creating an execution record
  2. Worker loads workflow definition, plans input, finds runnables
  3. For each runnable, a `StepWorker` job is enqueued
  4. When all steps complete, `StepWorker` calls `enqueue_continue/2`
  5. Worker finds next runnables or completes execution
  6. Checkpoints are created at generation boundaries

  ## Queue Configuration

  Add to your Oban config:

      config :imgd, Oban,
        queues: [default: 10, executions: 5, steps: 20]
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 3,
    priority: 0

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionPubSub}
  alias Imgd.Engine.{DataFlow, Runner}
  alias Imgd.Observability.{Telemetry, StructuredLogger}
  alias Imgd.Workers.StepWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    execution_id = args["execution_id"]
    mode = parse_mode(args["mode"])

    with {:ok, execution} <- load_execution(execution_id),
         :ok <- validate_execution(execution, mode) do
      Telemetry.set_log_context(execution)
      execute(execution, mode, args)
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(10 * :math.pow(2, attempt - 1), 120) |> round()
  end

  # Public API for job creation

  @doc """
  Enqueues a job to start a new execution.

  ## Options

  - `:schedule_in` - Delay in seconds before running

  ## Example

      {:ok, execution} = Workflows.start_execution(scope, workflow, input: %{...})
      {:ok, job} = ExecutionWorker.enqueue_start(execution.id)
  """
  @spec enqueue_start(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_start(execution_id, opts \\ []) do
    %{"execution_id" => execution_id, "mode" => "start"}
    |> new(build_job_opts(opts))
    |> Oban.insert()
  end

  @doc """
  Enqueues a job to continue an execution after steps complete.

  Called by `StepWorker` when the last step in a generation finishes.

  ## Options

  - `:schedule_in` - Delay in seconds before running (default: 1)
  - `:generation_id` - Unique ID for tracking this generation batch
  """
  @spec enqueue_continue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_continue(execution_id, opts \\ []) do
    opts = Keyword.put_new(opts, :schedule_in, 1)

    %{
      "execution_id" => execution_id,
      "mode" => "continue",
      "generation_id" => opts[:generation_id] || generate_generation_id()
    }
    |> new(build_job_opts(opts))
    |> Oban.insert()
  end

  @doc """
  Enqueues a job to resume a paused or failed execution.

  ## Options

  - `:schedule_in` - Delay in seconds before running
  """
  @spec enqueue_resume(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_resume(execution_id, opts \\ []) do
    %{"execution_id" => execution_id, "mode" => "resume"}
    |> new(build_job_opts(opts))
    |> Oban.insert()
  end

  # Execution Modes

  defp execute(execution, :start, _args) do
    execution = Repo.preload(execution, :workflow)
    workflow_def = execution.workflow

    Telemetry.with_execution_span(execution, workflow_def, fn ->
      StructuredLogger.execution_started(execution, workflow_def)

      # Broadcast execution started
      ExecutionPubSub.broadcast_execution_started(execution)

      with {:ok, state} <- Runner.prepare(execution, :start) do
        # Unwrap the input value if it's in our wrapper format
        raw_input = DataFlow.unwrap(execution.input)
        state = Runner.plan_input(state, raw_input)

        # Log the workflow state for debugging
        Logger.debug("Planned workflow state",
          execution_id: execution.id,
          generations: state.workflow.generations,
          runnables_count: length(Runner.get_runnables(state))
        )

        case Runner.create_checkpoint(state, :generation) do
          {:ok, checkpoint} ->
            Logger.info("Initial checkpoint created successfully",
              execution_id: execution.id,
              checkpoint_id: checkpoint.id
            )

            state = %{state | checkpoint: checkpoint}
            dispatch_or_complete(state)

          {:error, reason} ->
            # Log the full error for debugging
            Logger.error("Failed to create initial checkpoint - continuing without checkpoint",
              execution_id: execution.id,
              workflow_id: execution.workflow_id,
              error: inspect(reason, pretty: true, limit: :infinity)
            )

            # Still try to dispatch runnables even if checkpoint failed
            # This allows execution to proceed (though without recovery capability)
            dispatch_or_complete(state)
        end
      else
        {:error, reason} ->
          handle_preparation_failure(execution, workflow_def, reason)
      end
    end)
  end

  defp execute(execution, :continue, args) do
    execution = Repo.preload(execution, :workflow)
    generation_id = args["generation_id"]

    with {:ok, state} <- Runner.prepare(execution, :continue) do
      Telemetry.set_log_context(execution, state.workflow)

      if Runner.has_runnables?(state) do
        enqueue_runnables(state, generation_id: generation_id)
        {:ok, execution}
      else
        complete_execution(state)
      end
    else
      {:error, reason} ->
        handle_preparation_failure(execution, execution.workflow, reason)
    end
  end

  defp execute(execution, :resume, _args) do
    execution = Repo.preload(execution, :workflow)

    with {:ok, state} <- Runner.prepare(execution, :resume),
         {:ok, resumed_execution} <- resume_execution_status(execution) do
      StructuredLogger.execution_resumed(resumed_execution, state.checkpoint)

      state = %{state | execution: resumed_execution}
      dispatch_or_complete(state)
    else
      {:error, reason} ->
        handle_preparation_failure(execution, execution.workflow, reason)
    end
  end

  # Dispatch Logic

  defp dispatch_or_complete(state) do
    if Runner.has_runnables?(state) do
      enqueue_runnables(state)
      {:ok, state.execution}
    else
      complete_execution(state)
    end
  end

  defp enqueue_runnables(state, opts \\ []) do
    %{execution: execution, generation: generation, workflow: workflow} = state
    generation_id = opts[:generation_id] || generate_generation_id()
    runnables = Runner.get_runnables(state)

    StructuredLogger.runnables_found(execution, generation, runnables)

    # Broadcast generation started
    ExecutionPubSub.broadcast_generation_started(execution.id, generation, length(runnables))

    results =
      Enum.map(runnables, fn {node, fact} ->
        StepWorker.enqueue(
          execution.id,
          node.hash,
          fact.hash,
          generation: generation,
          generation_id: generation_id,
          timeout_ms: get_step_timeout(execution, node)
        )
      end)

    enqueued_count = Enum.count(results, &match?({:ok, _}, &1))
    failed_count = Enum.count(results, &match?({:error, _}, &1))

    if failed_count > 0 do
      Logger.warning(
        "Failed to enqueue #{failed_count}/#{length(runnables)} step jobs",
        execution_id: execution.id,
        generation: generation
      )
    end

    Logger.info(
      "Enqueued #{enqueued_count} step jobs for generation #{generation}",
      execution_id: execution.id,
      workflow_name: workflow.name
    )

    {:ok, _} = Workflows.update_execution_generation(execution, generation)

    :ok
  end

  defp complete_execution(state) do
    %{execution: execution, workflow: workflow} = state
    duration_ms = calculate_duration(execution)

    StructuredLogger.execution_completed(execution, workflow, duration_ms)
    emit_generation_complete(execution, state.generation)

    result = Runner.complete(state)

    # Broadcast completion after updating DB
    case result do
      {:ok, updated_execution} ->
        ExecutionPubSub.broadcast_execution_completed(updated_execution)
        {:ok, updated_execution}

      error ->
        error
    end
  end

  # Error Handling

  defp handle_preparation_failure(execution, workflow, reason) do
    Logger.error(
      "Execution preparation failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      reason: inspect(reason)
    )

    case reason do
      {:invalid_status, _} ->
        {:error, reason}

      _ ->
        if workflow do
          StructuredLogger.execution_failed(execution, workflow, reason, 0)
        end

        scope = get_scope(execution)

        if scope do
          result = Workflows.fail_execution(scope, execution, normalize_error(reason))

          # Broadcast failure
          case result do
            {:ok, failed_execution} ->
              ExecutionPubSub.broadcast_execution_failed(failed_execution, reason)
              result

            _ ->
              result
          end
        else
          {:error, reason}
        end
    end
  end

  # Helper Functions

  defp load_execution(execution_id) do
    case Repo.get(Execution, execution_id) do
      nil -> {:error, :execution_not_found}
      execution -> {:ok, execution}
    end
  end

  defp validate_execution(%Execution{status: status}, :start) do
    if status in [:pending, :running],
      do: :ok,
      else: {:error, {:invalid_status_for_start, status}}
  end

  defp validate_execution(%Execution{status: status}, :continue) do
    if status == :running, do: :ok, else: {:error, {:invalid_status_for_continue, status}}
  end

  defp validate_execution(%Execution{status: status}, :resume) do
    if status in [:paused, :failed], do: :ok, else: {:error, {:invalid_status_for_resume, status}}
  end

  defp resume_execution_status(execution) do
    scope = get_scope(execution)

    if scope do
      Workflows.resume_execution(scope, execution)
    else
      execution
      |> Execution.resume_changeset()
      |> Repo.update()
    end
  end

  defp parse_mode(nil), do: :continue
  defp parse_mode("start"), do: :start
  defp parse_mode("continue"), do: :continue
  defp parse_mode("resume"), do: :resume
  defp parse_mode(mode) when is_atom(mode), do: mode

  defp build_job_opts(opts) do
    opts
    |> Keyword.take([:schedule_in, :priority, :tags, :unique])
    |> Keyword.reject(fn {_, v} -> is_nil(v) end)
  end

  defp generate_generation_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp calculate_duration(%Execution{started_at: nil}), do: 0

  defp calculate_duration(%Execution{started_at: started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
  end

  defp get_scope(%Execution{triggered_by_user_id: nil}), do: nil

  defp get_scope(%Execution{triggered_by_user_id: user_id}) do
    user = Imgd.Accounts.get_user!(user_id)
    Imgd.Accounts.Scope.for_user(user)
  rescue
    _ -> nil
  end

  defp get_step_timeout(%Execution{} = execution, node) do
    node_timeout = Map.get(node, :timeout_ms)
    execution_timeout = get_in(execution.workflow.settings, [:timeout_ms])
    node_timeout || execution_timeout || :timer.minutes(5)
  end

  defp normalize_error(reason) when is_map(reason), do: reason

  defp normalize_error({:exception, e, stacktrace}) do
    %{
      type: inspect(e.__struct__),
      message: Exception.message(e),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 5000)
    }
  end

  defp normalize_error(reason), do: %{type: "error", message: inspect(reason)}

  defp emit_generation_complete(execution, generation) do
    :telemetry.execute(
      [:imgd, :engine, :generation, :complete],
      %{},
      %{
        execution_id: execution.id,
        workflow_id: execution.workflow_id,
        generation: generation
      }
    )

    ExecutionPubSub.broadcast_generation_completed(execution.id, generation)
  end
end

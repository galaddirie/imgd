defmodule Imgd.Workers.ExecutionWorker do
  @moduledoc """
  Oban worker for orchestrating workflow execution without checkpoints.

  Executes a workflow end-to-end in a single job: loads the workflow, plans input,
  runs each runnable step sequentially, and records completion or failure.
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 3,
    priority: 0

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionPubSub}
  alias Imgd.Engine.{DataFlow, Runner, StepExecutor}
  alias Imgd.Observability.{Telemetry, StructuredLogger}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"execution_id" => execution_id}}) do
    with {:ok, execution} <- load_execution(execution_id),
         :ok <- validate_execution(execution) do
      execution = Repo.preload(execution, :workflow)
      Telemetry.set_log_context(execution, execution.workflow)
      run_execution(execution)
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(10 * :math.pow(2, attempt - 1), 120) |> round()
  end

  @doc """
  Enqueues a job to start a new execution.
  """
  @spec enqueue_start(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_start(execution_id, opts \\ []) do
    %{"execution_id" => execution_id}
    |> new(build_job_opts(opts))
    |> Oban.insert()
  end

  defp run_execution(execution) do
    workflow_def = execution.workflow

    Telemetry.with_execution_span(execution, workflow_def, fn ->
      StructuredLogger.execution_started(execution, workflow_def)
      ExecutionPubSub.broadcast_execution_started(execution)

      with {:ok, state} <- Runner.prepare(execution, :start) do
        raw_input = DataFlow.unwrap(execution.input)
        state = Runner.plan_input(state, raw_input)

        process_runnables(persist_generation(state))
      else
        {:error, reason} ->
          handle_preparation_failure(execution, workflow_def, reason)
      end
    end)
  end

  defp process_runnables(state) do
    case Runner.get_runnables(state) do
      [] ->
        complete_execution(state)

      runnables ->
        StructuredLogger.runnables_found(state.execution, state.generation, runnables)

        ExecutionPubSub.broadcast_generation_started(
          state.execution.id,
          state.generation,
          length(runnables)
        )

        Enum.reduce_while(runnables, {:ok, state}, fn {node, fact}, {:ok, acc_state} ->
          opts = [
            timeout_ms: get_step_timeout(acc_state.execution, node),
            generation: acc_state.generation,
            attempt: 1
          ]

          case StepExecutor.execute(acc_state.execution, acc_state.workflow, node, fact, opts) do
            {:ok, updated_workflow, _events} ->
              {:ok, next_state} = Runner.advance(acc_state, updated_workflow)
              {:cont, {:ok, persist_generation(next_state)}}

            {:error, reason, _} ->
              {:halt, {:error, reason, acc_state}}
          end
        end)
        |> case do
          {:ok, next_state} ->
            process_runnables(next_state)

          {:error, reason, acc_state} ->
            handle_step_failure(acc_state, reason)
        end
    end
  end

  defp complete_execution(state) do
    %{execution: execution, workflow: workflow} = state
    duration_ms = calculate_duration(execution)

    StructuredLogger.execution_completed(execution, workflow, duration_ms)
    emit_generation_complete(execution, state.generation)

    result = Runner.complete(state)

    case result do
      {:ok, updated_execution} ->
        ExecutionPubSub.broadcast_execution_completed(updated_execution)
        {:ok, updated_execution}

      error ->
        error
    end
  end

  defp handle_step_failure(state, reason) do
    case Runner.fail(state, reason) do
      # todo: reviwe this
      {:ok, _failed_execution} -> {:ok, {:failed, reason}}
      other -> other
    end
  end

  defp handle_preparation_failure(execution, workflow, reason) do
    Logger.error(
      "Execution preparation failed",
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      reason: inspect(reason)
    )

    if workflow do
      StructuredLogger.execution_failed(execution, workflow, reason, 0)
    end

    scope = get_scope(execution)

    if scope do
      result = Workflows.fail_execution(scope, execution, normalize_error(reason))

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

  defp persist_generation(%{execution: execution, generation: generation} = state) do
    if execution.current_generation == generation do
      state
    else
      case Workflows.update_execution_generation(execution, generation) do
        {:ok, updated_execution} -> %{state | execution: updated_execution}
        {:error, _} -> state
      end
    end
  end

  defp load_execution(execution_id) do
    case Repo.get(Execution, execution_id) do
      nil -> {:error, :execution_not_found}
      execution -> {:ok, execution}
    end
  end

  defp validate_execution(%Execution{status: status}) do
    if status in [:pending, :running],
      do: :ok,
      else: {:error, {:invalid_status_for_start, status}}
  end

  defp build_job_opts(opts) do
    opts
    |> Keyword.take([:schedule_in, :priority, :tags, :unique])
    |> Keyword.reject(fn {_, v} -> is_nil(v) end)
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

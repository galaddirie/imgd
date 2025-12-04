defmodule Imgd.Engine.Runner do
  @moduledoc """
  Orchestrates workflow execution.

  The Runner is responsible for:
  - Loading and reconstructing Runic workflows from definitions or checkpoints
  - Managing the execution loop (plan → execute → checkpoint → continue)
  - Coordinating with Oban workers for distributed execution
  - Handling execution state transitions (start, pause, resume, complete, fail)

  ## Execution Modes

  - `:start` - Begin a new execution from the initial input
  - `:continue` - Continue an in-progress execution from its latest checkpoint
  - `:resume` - Resume a paused or failed execution

  ## Architecture

  The Runner operates in a pull-based model:

  1. `ExecutionWorker` calls `Runner.prepare/2` to load/reconstruct workflow state
  2. `Runner.get_runnables/1` returns the next batch of steps to execute
  3. `StepWorker` jobs are enqueued for each runnable
  4. When all steps complete, `ExecutionWorker` is re-triggered
  5. `Runner.advance/2` updates the workflow state after steps complete
  6. Loop continues until no more runnables or execution terminates
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionCheckpoint}
  alias Imgd.Engine.Checkpoint

  require Logger

  @type runner_state :: %{
          execution: Execution.t(),
          workflow: Runic.Workflow.t(),
          checkpoint: ExecutionCheckpoint.t() | nil,
          generation: non_neg_integer(),
          pending_runnables: [Imgd.Engine.runnable()]
        }

  @type prepare_result :: {:ok, runner_state()} | {:error, term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Prepares an execution for running.

  Loads the workflow definition and either:
  - Builds a fresh workflow for new executions
  - Restores from checkpoint for continued/resumed executions

  Returns `{:ok, runner_state}` or `{:error, reason}`.
  """
  @spec prepare(Execution.t(), Imgd.Engine.execution_mode()) :: prepare_result()
  def prepare(%Execution{} = execution, mode \\ :continue) do
    execution = Repo.preload(execution, :workflow)

    case mode do
      :start ->
        prepare_fresh(execution)

      :continue ->
        prepare_from_checkpoint(execution)

      :resume ->
        prepare_for_resume(execution)
    end
  end

  @doc """
  Plans initial input into the workflow.

  Call this after `prepare/2` when starting a new execution.
  """
  @spec plan_input(runner_state(), term()) :: runner_state()
  def plan_input(%{workflow: workflow} = state, input) do
    planned_workflow = Runic.Workflow.plan_eagerly(workflow, input)
    runnables = Runic.Workflow.next_runnables(planned_workflow)

    %{state | workflow: planned_workflow, pending_runnables: runnables}
  end

  @doc """
  Returns the list of runnables ready for execution.

  Each runnable is a `{node, fact}` tuple that can be executed by a StepWorker.
  """
  @spec get_runnables(runner_state()) :: [Imgd.Engine.runnable()]
  def get_runnables(%{pending_runnables: runnables}), do: runnables

  @doc """
  Checks if the execution has more work to do.
  """
  @spec has_runnables?(runner_state()) :: boolean()
  def has_runnables?(%{pending_runnables: runnables}), do: runnables != []

  @doc """
  Advances the workflow state after step execution.

  Merges results from completed steps into the workflow state,
  determines if a checkpoint should be created, and finds next runnables.

  Returns `{:ok, updated_state}` or `{:error, reason}`.
  """
  @spec advance(runner_state(), Runic.Workflow.t()) ::
          {:ok, runner_state()} | {:error, term()}
  def advance(%{execution: execution, generation: prev_gen} = state, updated_workflow) do
    new_gen = updated_workflow.generations

    Logger.debug("Runner.advance - workflow.generations value",
      execution_id: execution.id,
      prev_generation: prev_gen,
      new_generation: new_gen,
      new_generation_type: inspect(new_gen.__struct__),
      new_generation_inspect: inspect(new_gen, limit: 100)
    )

    runnables = Runic.Workflow.next_runnables(updated_workflow)

    new_state = %{
      state
      | workflow: updated_workflow,
        generation: new_gen,
        pending_runnables: runnables
    }

    # Check if we should checkpoint
    if Checkpoint.should_checkpoint?(execution, updated_workflow,
         last_checkpoint_generation: prev_gen
       ) do
      case create_checkpoint(new_state, :generation) do
        {:ok, checkpoint} ->
          # TODO: add observability
          {:ok, %{new_state | checkpoint: checkpoint}}

        {:error, reason} ->
          Logger.warning("Failed to create checkpoint: #{inspect(reason)}")
          {:ok, new_state}
      end
    else
      {:ok, new_state}
    end
  end

  @doc """
  Merges workflow state from multiple concurrent step executions.

  When steps run in parallel, their results need to be merged back into
  a consistent workflow state. This uses Runic's `merge/2` function.
  """
  @spec merge_results(runner_state(), [Runic.Workflow.t()]) :: runner_state()
  def merge_results(%{workflow: base_workflow} = state, step_workflows) do
    Logger.debug("Runner.merge_results - before merging",
      base_generations: base_workflow.generations,
      base_generations_type:
        if(is_struct(base_workflow.generations),
          do: inspect(base_workflow.generations.__struct__),
          else: "integer"
        ),
      step_workflows_count: length(step_workflows)
    )

    merged_workflow =
      Enum.reduce(step_workflows, base_workflow, fn step_workflow, acc ->
        Logger.debug("Runner.merge_results - merging step workflow",
          step_generations: step_workflow.generations,
          step_generations_type:
            if(is_struct(step_workflow.generations),
              do: inspect(step_workflow.generations.__struct__),
              else: "integer"
            ),
          acc_generations: acc.generations,
          acc_generations_type:
            if(is_struct(acc.generations),
              do: inspect(acc.generations.__struct__),
              else: "integer"
            )
        )

        Runic.Workflow.merge(acc, step_workflow)
      end)

    Logger.debug("Runner.merge_results - after merging",
      merged_generations: merged_workflow.generations,
      merged_generations_type:
        if(is_struct(merged_workflow.generations),
          do: inspect(merged_workflow.generations.__struct__),
          else: "integer"
        )
    )

    %{state | workflow: merged_workflow}
  end

  @doc """
  Completes an execution successfully.

  Extracts final productions and updates execution status.
  """
  @spec complete(runner_state()) :: {:ok, Execution.t()} | {:error, term()}
  def complete(%{execution: execution, workflow: workflow} = _state) do
    output = extract_final_output(workflow)

    # Get the scope to authorize the update
    scope = Imgd.Accounts.Scope.for_user(get_triggering_user(execution))

    case Workflows.complete_execution(scope, execution, output) do
      {:ok, execution} ->
        # TODO: add observability
        {:ok, execution}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Fails an execution with an error.
  """
  @spec fail(runner_state(), term()) :: {:ok, Execution.t()} | {:error, term()}
  def fail(%{execution: execution} = _state, error) do
    scope = Imgd.Accounts.Scope.for_user(get_triggering_user(execution))

    case Workflows.fail_execution(scope, execution, normalize_error(error)) do
      {:ok, execution} ->
        # TODO: add observability
        Imgd.Workflows.ExecutionPubSub.broadcast_execution_failed(execution, error)
        {:ok, execution}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates a checkpoint at the current state.
  """
  @spec create_checkpoint(runner_state(), Imgd.Engine.checkpoint_reason()) ::
          {:ok, ExecutionCheckpoint.t()} | {:error, term()}
  def create_checkpoint(%{execution: execution, workflow: workflow}, reason) do
    Checkpoint.create(execution, workflow, reason: reason)
  end

  @doc """
  Finds a runnable by its node and fact hashes.

  Used by StepWorker to locate the specific step to execute.
  """
  @spec find_runnable(runner_state(), integer(), integer()) ::
          {:ok, Imgd.Engine.runnable()} | {:error, :not_found}
  def find_runnable(%{workflow: workflow}, node_hash, fact_hash) do
    runnable =
      workflow
      |> Runic.Workflow.next_runnables()
      |> Enum.find(fn {node, fact} ->
        node.hash == node_hash and fact.hash == fact_hash
      end)

    case runnable do
      nil -> {:error, :not_found}
      found -> {:ok, found}
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp prepare_fresh(%Execution{workflow: workflow} = execution) do
    case Checkpoint.build_from_definition(workflow) do
      {:ok, runic_workflow} ->
        {:ok,
         %{
           execution: execution,
           workflow: runic_workflow,
           checkpoint: nil,
           generation: 0,
           pending_runnables: []
         }}

      {:error, _} = error ->
        error
    end
  end

  defp prepare_from_checkpoint(%Execution{} = execution) do
    case Checkpoint.restore_latest(execution) do
      {:ok, {checkpoint, workflow}} ->
        runnables = Runic.Workflow.next_runnables(workflow)

        {:ok,
         %{
           execution: execution,
           workflow: workflow,
           checkpoint: checkpoint,
           generation: checkpoint.generation,
           pending_runnables: runnables
         }}

      {:error, :no_checkpoint} ->
        # Fall back to fresh start
        prepare_fresh(execution)

      {:error, _} = error ->
        error
    end
  end

  defp prepare_for_resume(%Execution{status: status} = execution) do
    unless status in [:paused, :failed] do
      {:error, {:invalid_status, status}}
    else
      prepare_from_checkpoint(execution)
    end
  end

  defp extract_final_output(workflow) do
    productions = Runic.Workflow.raw_productions(workflow)
    productions_by_component = Runic.Workflow.raw_productions_by_component(workflow)

    %{
      productions: productions,
      productions_by_component: productions_by_component,
      generation: workflow.generations
    }
  end

  defp normalize_error(error) when is_map(error), do: error

  defp normalize_error({:exception, e, stacktrace}) do
    %{
      type: inspect(e.__struct__),
      message: Exception.message(e),
      stacktrace: Exception.format_stacktrace(stacktrace)
    }
  end

  defp normalize_error(error), do: %{message: inspect(error)}

  defp get_triggering_user(%Execution{triggered_by_user_id: nil}), do: nil

  defp get_triggering_user(%Execution{triggered_by_user_id: user_id}) do
    Imgd.Accounts.get_user!(user_id)
  rescue
    _ -> nil
  end
end

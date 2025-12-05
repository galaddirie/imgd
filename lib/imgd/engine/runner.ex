defmodule Imgd.Engine.Runner do
  @moduledoc """
  Orchestrates workflow execution.

  The Runner is responsible for:
  - Loading Runic workflows from definitions
  - Managing the execution loop (plan → execute → continue)
  - Handling execution state transitions (start, complete, fail)

  ## Execution Modes

  - `:start` - Begin a new execution from the initial input
  - `:continue` - Continue an in-progress execution from scratch (legacy compatibility)
  - `:resume` - Resume a paused or failed execution (legacy compatibility)

  ## Architecture

  The Runner operates in a pull-based model:

  1. `ExecutionWorker` calls `Runner.prepare/2` to load workflow state
  2. `Runner.get_runnables/1` returns the next batch of steps to execute
  3. `Runner.advance/2` updates the workflow state after steps complete
  4. Loop continues until no more runnables or execution terminates
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, Workflow}

  require Logger

  @type runner_state :: %{
          execution: Execution.t(),
          workflow: Runic.Workflow.t(),
          generation: non_neg_integer(),
          pending_runnables: [Imgd.Engine.runnable()]
        }

  @type prepare_result :: {:ok, runner_state()} | {:error, term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Prepares an execution for running.

  Loads the workflow definition for new executions.

  Returns `{:ok, runner_state}` or `{:error, reason}`.
  """
  @spec prepare(Execution.t(), Imgd.Engine.execution_mode()) :: prepare_result()
  def prepare(%Execution{} = execution, mode \\ :start) do
    execution = Repo.preload(execution, :workflow)

    case mode do
      :start -> prepare_fresh(execution)
      :continue -> prepare_fresh(execution)
      :resume -> prepare_fresh(execution)
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

    %{
      state
      | workflow: planned_workflow,
        generation: planned_workflow.generations,
        pending_runnables: runnables
    }
  end

  @doc """
  Returns the list of runnables ready for execution.

  Each runnable is a `{node, fact}` tuple that can be executed by the step executor.
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

  Merges results from completed steps into the workflow state and finds next runnables.

  Returns `{:ok, updated_state}`.
  """
  @spec advance(runner_state(), Runic.Workflow.t()) :: {:ok, runner_state()}
  def advance(%{execution: execution, generation: prev_gen} = state, updated_workflow) do
    new_gen = updated_workflow.generations

    Logger.debug("Runner.advance - workflow.generations value",
      execution_id: execution.id,
      prev_generation: prev_gen,
      new_generation: new_gen,
      new_generation_type:
        if(is_struct(new_gen), do: inspect(new_gen.__struct__), else: "integer"),
      new_generation_inspect: inspect(new_gen, limit: 100)
    )

    runnables = Runic.Workflow.next_runnables(updated_workflow)

    new_state = %{
      state
      | execution: %{execution | current_generation: new_gen},
        workflow: updated_workflow,
        generation: new_gen,
        pending_runnables: runnables
    }

    {:ok, new_state}
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

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp prepare_fresh(%Execution{workflow: workflow} = execution) do
    case build_from_definition(workflow) do
      {:ok, runic_workflow} ->
        {:ok,
         %{
           execution: execution,
           workflow: runic_workflow,
           generation: 0,
           pending_runnables: []
         }}

      {:error, _} = error ->
        error
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

  defp build_from_definition(%Workflow{definition: definition}) when not is_nil(definition) do
    try do
      workflow = Workflow.to_runic_workflow(%Workflow{definition: definition})
      {:ok, workflow}
    rescue
      e ->
        Logger.error("Failed to build workflow from definition: #{Exception.message(e)}")
        {:error, {:build_failed, Exception.message(e)}}
    end
  end

  defp build_from_definition(_), do: {:error, :no_definition}
end

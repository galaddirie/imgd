defmodule Imgd.Engine.Checkpoint do
  @moduledoc """
  Checkpoint management for workflow execution.

  Handles serialization and deserialization of Runic workflow state,
  enabling recovery from crashes, pauses, and resumption of executions.

  ## Checkpoint Strategy

  Checkpoints are created:
  - At the start of execution (generation 0)
  - After each generation completes
  - Before potentially expensive/external operations (optional)
  - On pause or error (for debugging/recovery)

  ## Serialization Format

  Workflow state is serialized using `:erlang.term_to_binary/2` with compression.
  This preserves all Elixir/Erlang terms including anonymous functions (with caveats
  about code changes between serialization and deserialization).
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.{Execution, ExecutionCheckpoint, Workflow}

  require Logger

  @type checkpoint_opts :: [
          reason: Imgd.Engine.checkpoint_reason(),
          metadata: map()
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a checkpoint from the current workflow state.

  Returns `{:ok, checkpoint}` or `{:error, changeset}`.
  """
  @spec create(Execution.t(), Runic.Workflow.t(), checkpoint_opts()) ::
          {:ok, ExecutionCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def create(%Execution{} = execution, workflow, opts \\ []) do
    Workflows.create_checkpoint(execution, workflow, opts)
  end

  @doc """
  Loads the latest checkpoint for an execution and restores the workflow.

  Returns `{:ok, {checkpoint, workflow}}` or `{:error, reason}`.
  """
  @spec restore_latest(Execution.t()) ::
          {:ok, {ExecutionCheckpoint.t(), Runic.Workflow.t()}}
          | {:error, :no_checkpoint | :restore_failed}
  def restore_latest(%Execution{} = execution) do
    case get_current_checkpoint(execution) do
      nil ->
        {:error, :no_checkpoint}

      checkpoint ->
        case restore_workflow(checkpoint) do
          {:ok, workflow} -> {:ok, {checkpoint, workflow}}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Restores a Runic workflow from a checkpoint.

  Returns `{:ok, workflow}` or `{:error, reason}`.
  """
  @spec restore_workflow(ExecutionCheckpoint.t()) ::
          {:ok, Runic.Workflow.t()} | {:error, term()}
  def restore_workflow(%ExecutionCheckpoint{} = checkpoint) do
    Workflows.restore_from_checkpoint(checkpoint)
  end

  @doc """
  Builds a fresh Runic workflow from a workflow definition.

  This is used when starting a new execution or when no checkpoint exists.
  """
  @spec build_from_definition(Workflow.t()) ::
          {:ok, Runic.Workflow.t()} | {:error, term()}
  def build_from_definition(%Workflow{definition: definition}) when not is_nil(definition) do
    try do
      workflow = Workflow.to_runic_workflow(%Workflow{definition: definition})
      {:ok, workflow}
    rescue
      e ->
        Logger.error("Failed to build workflow from definition: #{Exception.message(e)}")
        {:error, {:build_failed, Exception.message(e)}}
    end
  end

  def build_from_definition(_), do: {:error, :no_definition}

  @doc """
  Determines if a checkpoint should be created based on the strategy and current state.

  ## Strategies

  - `:generation` - Checkpoint after each generation (default)
  - `:step` - Checkpoint after each step
  - `:time` - Checkpoint at time intervals
  """
  @spec should_checkpoint?(Execution.t(), Runic.Workflow.t(), keyword()) :: boolean()
  def should_checkpoint?(%Execution{} = execution, workflow, opts \\ []) do
    strategy = get_checkpoint_strategy(execution)
    current_gen = workflow.generations
    last_checkpoint_gen = opts[:last_checkpoint_generation] || -1

    case strategy do
      :generation ->
        current_gen > last_checkpoint_gen

      :step ->
        # Always checkpoint after a step in this mode
        true

      :time ->
        interval_ms = get_in(execution.workflow.settings, [:checkpoint_interval_ms]) || 60_000
        last_checkpoint_at = opts[:last_checkpoint_at]

        is_nil(last_checkpoint_at) or
          DateTime.diff(DateTime.utc_now(), last_checkpoint_at, :millisecond) >= interval_ms

      _ ->
        # Default to generation-based
        current_gen > last_checkpoint_gen
    end
  end

  @doc """
  Extracts pending runnables from a workflow for storage in checkpoint.

  Returns a list of maps with node_hash and fact_hash for reconstruction.
  """
  @spec extract_pending_runnables(Runic.Workflow.t()) :: [map()]
  def extract_pending_runnables(workflow) do
    workflow
    |> Runic.Workflow.next_runnables()
    |> Enum.map(fn {node, fact} ->
      %{node_hash: node.hash, fact_hash: fact.hash}
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_current_checkpoint(%Execution{id: execution_id}) do
    Repo.one(
      ExecutionCheckpoint
      |> ExecutionCheckpoint.by_execution(execution_id)
      |> ExecutionCheckpoint.current()
      |> ExecutionCheckpoint.latest()
    )
  end

  defp get_checkpoint_strategy(%Execution{} = execution) do
    case get_in(execution, [Access.key(:settings), :checkpoint_strategy]) do
      nil -> :generation
      strategy when is_atom(strategy) -> strategy
      strategy when is_binary(strategy) -> String.to_existing_atom(strategy)
    end
  rescue
    _ -> :generation
  end
end

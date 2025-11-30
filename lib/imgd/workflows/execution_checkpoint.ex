defmodule Imgd.Workflows.ExecutionCheckpoint do
  @moduledoc """
  Execution checkpoint for durable workflow execution.

  Stores serialized workflow state at a point in time, enabling
  recovery from crashes, pauses, and resumption of long-running workflows.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Imgd.Workflows.Execution

  @type reason :: :generation | :step | :pause | :timeout | :error | :scheduled

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "execution_checkpoints" do
    field :generation, :integer

    # Full workflow state - binary for efficiency
    # Contains: :erlang.term_to_binary(%{build_log: [...], reaction_events: [...]})
    field :workflow_state, :binary

    # Pending runnables for quick resume without full rebuild
    # [{node_hash, fact_hash}, ...]
    field :pending_runnables, {:array, :map}, default: []

    # Accumulator/state machine snapshots
    # %{accumulator_hash => current_value}
    field :accumulator_states, :map, default: %{}

    # Set of completed step hashes for idempotency
    field :completed_step_hashes, {:array, :integer}, default: []

    # Why this checkpoint was created
    field :reason, Ecto.Enum,
      values: [:generation, :step, :pause, :timeout, :error, :scheduled],
      default: :generation

    # Is this the latest checkpoint for the execution?
    field :is_current, :boolean, default: true

    # Size tracking for cleanup policies
    field :size_bytes, :integer

    belongs_to :execution, Execution

    # Checkpoints are immutable
    timestamps(updated_at: false)
  end

  @required_fields [:execution_id, :generation, :workflow_state]
  @optional_fields [
    :pending_runnables,
    :accumulator_states,
    :completed_step_hashes,
    :reason,
    :is_current,
    :size_bytes
  ]

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> compute_size()
    |> foreign_key_constraint(:execution_id)
  end

  # Queries

  def by_execution(query \\ __MODULE__, execution_id) do
    from c in query,
      where: c.execution_id == ^execution_id,
      order_by: [desc: c.generation, desc: c.inserted_at]
  end

  def current(query \\ __MODULE__) do
    from c in query, where: c.is_current == true
  end

  def latest(query \\ __MODULE__) do
    from c in query,
      order_by: [desc: c.generation, desc: c.inserted_at],
      limit: 1
  end

  def at_generation(query \\ __MODULE__, generation) do
    from c in query, where: c.generation == ^generation
  end

  def by_reason(query \\ __MODULE__, reason) do
    from c in query, where: c.reason == ^reason
  end

  def older_than(query \\ __MODULE__, datetime) do
    from c in query, where: c.inserted_at < ^datetime
  end

  # Creation helpers

  @doc """
  Creates a checkpoint from current workflow state.
  """
  def from_workflow_state(execution_id, workflow, opts \\ []) do
    # Serialize the full workflow log for reconstruction
    workflow_state = serialize_workflow(workflow)

    # Extract pending runnables
    pending =
      workflow
      |> Runic.Workflow.next_runnables()
      |> Enum.map(fn {node, fact} ->
        %{node_hash: node.hash, fact_hash: fact.hash}
      end)

    # Extract accumulator states
    accumulator_states = extract_accumulator_states(workflow)

    # Get completed step hashes from the reaction events
    completed = extract_completed_steps(workflow)

    %__MODULE__{}
    |> changeset(%{
      execution_id: execution_id,
      generation: workflow.generations,
      workflow_state: workflow_state,
      pending_runnables: pending,
      accumulator_states: accumulator_states,
      completed_step_hashes: completed,
      reason: opts[:reason] || :generation
    })
  end

  @doc """
  Restores a Runic.Workflow from checkpoint.
  """
  def restore_workflow(%__MODULE__{workflow_state: state}) do
    deserialize_workflow(state)
  end

  @doc """
  Returns pending runnables as {node, fact} tuples for a given workflow.
  """
  def pending_runnables(%__MODULE__{pending_runnables: pending}, workflow) do
    Enum.map(pending, fn %{node_hash: nh, fact_hash: fh} ->
      node = Map.get(workflow.graph.vertices, nh)
      fact = Map.get(workflow.graph.vertices, fh)
      {node, fact}
    end)
    |> Enum.reject(fn {n, f} -> is_nil(n) or is_nil(f) end)
  end

  # Serialization

  defp serialize_workflow(workflow) do
    log = Runic.Workflow.log(workflow)
    :erlang.term_to_binary(log, [:compressed])
  end

  defp deserialize_workflow(binary) do
    log = :erlang.binary_to_term(binary)
    Runic.Workflow.from_log(log)
  end

  defp extract_accumulator_states(workflow) do
    # Find all accumulators and their current state
    workflow.graph
    |> Graph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Accumulator{}, &1))
    |> Enum.reduce(%{}, fn acc, states ->
      state_fact =
        workflow.graph
        |> Graph.out_edges(acc, by: :state_produced)
        |> List.last()

      case state_fact do
        %{v2: %{value: value}} -> Map.put(states, acc.hash, value)
        _ -> states
      end
    end)
  end

  defp extract_completed_steps(workflow) do
    workflow.graph
    |> Graph.edges(by: :ran)
    |> Enum.map(fn edge -> edge.v2.hash end)
    |> Enum.uniq()
  end

  defp compute_size(changeset) do
    case get_change(changeset, :workflow_state) do
      nil -> changeset
      state -> put_change(changeset, :size_bytes, byte_size(state))
    end
  end

  @doc """
  Marks all other checkpoints for this execution as not current.
  """
  def mark_previous_not_current(execution_id) do
    from(c in __MODULE__,
      where: c.execution_id == ^execution_id,
      where: c.is_current == true
    )
    |> Ecto.Query.update(set: [is_current: false])
  end
end

defmodule Imgd.Workflows.ExecutionStep do
  @moduledoc """
  Individual step execution record.

  Tracks the execution of each step within a workflow execution,
  including timing, inputs, outputs, errors, and logs.
  Used for debugging, observability, and waterfall visualization.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :step_hash,
             :step_name,
             :step_type,
             :generation,
             :status,
             :input_fact_hash,
             :output_fact_hash,
             :parent_step_hash,
             :input_snapshot,
             :output_snapshot,
             :error,
             :logs,
             :duration_ms,
             :started_at,
             :completed_at,
             :attempt,
             :max_attempts,
             :next_retry_at,
             :idempotency_key,
             :execution_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Workflows.Execution
  alias Imgd.Engine.DataFlow
  alias Imgd.Engine.DataFlow.Envelope

  @type status :: :pending | :running | :completed | :failed | :skipped | :retrying

  schema "execution_steps" do
    # Step identification
    field :step_hash, :integer
    field :step_name, :string
    # "Step", "Condition", "Accumulator", etc.
    field :step_type, :string
    field :generation, :integer

    # Status tracking
    field :status, Ecto.Enum,
      values: [:pending, :running, :completed, :failed, :skipped, :retrying],
      default: :pending

    # Fact lineage for dependency tracking
    field :input_fact_hash, :integer
    field :output_fact_hash, :integer
    # Step that produced the input fact
    field :parent_step_hash, :integer

    # Data snapshots for debugging
    field :input_snapshot, :map
    field :output_snapshot, :map

    # Error details
    field :error, :map
    # %{type: "RuntimeError", message: "...", stacktrace: "..."}

    # Captured logs/stdout from step execution
    field :logs, :string

    # Timing
    field :duration_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Retry tracking
    field :attempt, :integer, default: 1
    field :max_attempts, :integer, default: 1
    field :next_retry_at, :utc_datetime_usec

    # For idempotency
    field :idempotency_key, :string

    belongs_to :execution, Execution

    timestamps()
  end

  @required_fields [:execution_id, :step_hash, :step_name, :step_type, :generation]
  @optional_fields [
    :status,
    :input_fact_hash,
    :output_fact_hash,
    :parent_step_hash,
    :input_snapshot,
    :output_snapshot,
    :error,
    :logs,
    :duration_ms,
    :started_at,
    :completed_at,
    :attempt,
    :max_attempts,
    :next_retry_at,
    :idempotency_key
  ]

  def changeset(step, attrs) do
    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> truncate_snapshots()
    |> truncate_logs()
    |> foreign_key_constraint(:execution_id)
    |> unique_constraint([:execution_id, :step_hash, :input_fact_hash, :attempt])
  end

  def start_changeset(step) do
    step
    |> change(%{
      status: :running,
      started_at: DateTime.utc_now()
    })
  end

  def complete_changeset(step, output_fact, duration_ms, opts \\ []) do
    trace_id = opts[:trace_id] || default_trace_id(step.execution_id)
    output_snapshot = fact_snapshot(output_fact, trace_id, step.step_hash, step.step_name)

    step
    |> change(%{
      status: :completed,
      output_fact_hash: fact_hash(output_fact),
      output_snapshot: output_snapshot,
      duration_ms: duration_ms,
      completed_at: DateTime.utc_now()
    })
  end

  def fail_changeset(step, error, duration_ms) do
    step
    |> change(%{
      status: :failed,
      error: normalize_error(error),
      duration_ms: duration_ms,
      completed_at: DateTime.utc_now()
    })
  end

  def skip_changeset(step, reason \\ nil) do
    step
    |> change(%{
      status: :skipped,
      completed_at: DateTime.utc_now(),
      error: if(reason, do: %{type: "skipped", message: reason}, else: nil)
    })
  end

  def retry_changeset(step, next_retry_at) do
    step
    |> change(%{
      status: :retrying,
      next_retry_at: next_retry_at
    })
  end

  def increment_attempt_changeset(step) do
    change(step, attempt: step.attempt + 1)
  end

  def append_logs_changeset(step, new_logs) do
    current = step.logs || ""
    combined = current <> new_logs
    change(step, logs: combined)
  end

  # Queries

  def by_execution(query \\ __MODULE__, execution_id) do
    from s in query,
      where: s.execution_id == ^execution_id,
      order_by: [asc: s.generation, asc: s.started_at]
  end

  def by_generation(query \\ __MODULE__, generation) do
    from s in query, where: s.generation == ^generation
  end

  def by_status(query \\ __MODULE__, status) do
    from s in query, where: s.status == ^status
  end

  def failed(query \\ __MODULE__) do
    from s in query, where: s.status == :failed
  end

  def completed(query \\ __MODULE__) do
    from s in query, where: s.status == :completed
  end

  def pending_retry(query \\ __MODULE__) do
    now = DateTime.utc_now()

    from s in query,
      where: s.status == :retrying,
      where: s.next_retry_at <= ^now
  end

  def by_step_hash(query \\ __MODULE__, step_hash) do
    from s in query, where: s.step_hash == ^step_hash
  end

  def by_step_name(query \\ __MODULE__, step_name) do
    from s in query, where: s.step_name == ^step_name
  end

  def slowest(query \\ __MODULE__, limit \\ 10) do
    from s in query,
      where: not is_nil(s.duration_ms),
      order_by: [desc: s.duration_ms],
      limit: ^limit
  end

  def with_errors(query \\ __MODULE__) do
    from s in query, where: not is_nil(s.error)
  end

  # Creation helpers

  @doc """
  Creates a step record from a Runic node and fact.
  """
  def from_runnable(execution_id, node, fact, opts \\ []) do
    trace_id = opts[:trace_id] || default_trace_id(execution_id)

    parent_hash =
      case fact.ancestry do
        {parent, _} -> parent
        nil -> nil
      end

    %__MODULE__{}
    |> changeset(%{
      execution_id: execution_id,
      step_hash: node.hash,
      step_name: step_name(node),
      step_type: node.__struct__ |> Module.split() |> List.last(),
      generation: opts[:generation] || 0,
      input_fact_hash: fact_hash(fact),
      parent_step_hash: parent_hash,
      input_snapshot: fact_snapshot(fact, trace_id, node.hash, step_name(node)),
      max_attempts: get_max_attempts(node),
      idempotency_key: compute_idempotency_key(node, fact)
    })
  end

  # Helpers

  defp fact_snapshot(fact, trace_id, step_hash, step_name) do
    fact
    |> Envelope.from_fact(:step, trace_id, %{step_hash: step_hash, step_name: step_name})
    |> Envelope.to_map()
    |> DataFlow.snapshot()
  end

  defp truncate_snapshots(changeset) do
    changeset
    |> maybe_truncate_field(:input_snapshot, 10_000)
    |> maybe_truncate_field(:output_snapshot, 10_000)
  end

  defp truncate_logs(changeset) do
    case get_change(changeset, :logs) do
      nil ->
        changeset

      logs when byte_size(logs) > 100_000 ->
        truncated = String.slice(logs, -100_000, 100_000)
        put_change(changeset, :logs, "[truncated...]\n" <> truncated)

      _ ->
        changeset
    end
  end

  defp maybe_truncate_field(changeset, field, max_size) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        encoded = Jason.encode!(value)

        if byte_size(encoded) > max_size do
          put_change(changeset, field, %{_truncated: true, _size: byte_size(encoded)})
        else
          changeset
        end
    end
  end

  defp fact_hash(%Runic.Workflow.Fact{hash: hash}), do: hash
  defp fact_hash(%{hash: hash}), do: hash
  defp fact_hash(_), do: nil

  defp default_trace_id(nil), do: DataFlow.generate_trace_id()
  defp default_trace_id(execution_id), do: "exec-#{execution_id}"

  defp normalize_error(%{__exception__: true} = e) do
    %{
      type: e.__struct__ |> to_string(),
      message: Exception.message(e)
    }
  end

  defp normalize_error({kind, reason, stacktrace}) do
    %{
      type: to_string(kind),
      message: inspect(reason),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 5000)
    }
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}

  defp get_max_attempts(%{retry_policy: %{max_attempts: n}}), do: n
  defp get_max_attempts(_), do: 1

  @doc """
  Normalizes a step name to a string for persistence.
  """
  def step_name(%{name: name, hash: hash}) do
    base = name || "step_#{hash}"

    cond do
      is_binary(base) -> base
      is_atom(base) -> Atom.to_string(base)
      is_number(base) -> to_string(base)
      true -> inspect(base)
    end
  end

  defp compute_idempotency_key(node, fact) do
    # Deterministic key for detecting duplicate step executions
    :crypto.hash(:sha256, :erlang.term_to_binary({node.hash, fact.hash}))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end
end

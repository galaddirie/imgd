defmodule Imgd.Workflows.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, inputs, outputs, and error information.
  """
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Workflows.{Workflow, ExecutionCheckpoint, ExecutionStep}
  alias Imgd.Accounts.User

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event

  schema "executions" do
    field :workflow_version, :integer

    field :status, Ecto.Enum,
      values: [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout],
      default: :pending

    field :trigger_type, Ecto.Enum,
      values: [:manual, :schedule, :webhook, :event],
      default: :manual

    # Execution data
    field :input, :map
    # Final productions
    field :output, :map
    # Error details if failed
    field :error, :map

    # Current position in workflow
    field :current_generation, :integer, default: 0

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    # TTL for long-running cleanup
    field :expires_at, :utc_datetime_usec

    # Metadata for correlation, debugging
    field :metadata, :map, default: %{}
    # Example: %{
    #   trace_id: "...",
    #   correlation_id: "...",
    #   triggered_by: "user_id" | "schedule_id" | "webhook_request_id",
    #   parent_execution_id: "..." (for sub-workflows)
    # }

    # Statistics (updated as execution progresses)
    field :stats, :map,
      default: %{
        steps_completed: 0,
        steps_failed: 0,
        steps_skipped: 0,
        total_duration_ms: 0,
        retries: 0
      }

    belongs_to :workflow, Workflow
    belongs_to :triggered_by_user, User, foreign_key: :triggered_by_user_id
    has_many :checkpoints, ExecutionCheckpoint
    has_many :steps, ExecutionStep

    timestamps()
  end

  @required_fields [:workflow_id, :workflow_version]
  @optional_fields [
    :status,
    :trigger_type,
    :input,
    :output,
    :error,
    :current_generation,
    :started_at,
    :completed_at,
    :expires_at,
    :metadata,
    :stats,
    :triggered_by_user_id
  ]

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workflow_id)
  end

  def start_changeset(execution) do
    now = DateTime.utc_now()

    execution
    |> change(%{
      status: :running,
      started_at: now,
      # Default 24h TTL
      expires_at: DateTime.add(now, 24, :hour)
    })
  end

  def complete_changeset(execution, output) do
    execution
    |> change(%{
      status: :completed,
      output: normalize_output(output),
      completed_at: DateTime.utc_now()
    })
    |> compute_total_duration()
  end

  def fail_changeset(execution, error) do
    execution
    |> change(%{
      status: :failed,
      error: normalize_error(error),
      completed_at: DateTime.utc_now()
    })
    |> compute_total_duration()
  end

  def pause_changeset(execution) do
    change(execution, status: :paused)
  end

  def resume_changeset(execution) do
    change(execution, status: :running)
  end

  def cancel_changeset(execution) do
    execution
    |> change(%{
      status: :cancelled,
      completed_at: DateTime.utc_now()
    })
    |> compute_total_duration()
  end

  def timeout_changeset(execution) do
    execution
    |> change(%{
      status: :timeout,
      error: %{type: "timeout", message: "Execution exceeded time limit"},
      completed_at: DateTime.utc_now()
    })
    |> compute_total_duration()
  end

  def update_generation_changeset(execution, generation) do
    change(execution, current_generation: generation)
  end

  def update_stats_changeset(execution, stats_update) do
    new_stats = Map.merge(execution.stats || %{}, stats_update)
    change(execution, stats: new_stats)
  end

  # Queries

  def by_workflow(query \\ __MODULE__, workflow_id) do
    from e in query, where: e.workflow_id == ^workflow_id
  end

  def by_status(query \\ __MODULE__, statuses_or_status)

  def by_status(query, statuses_or_status) when is_atom(statuses_or_status) do
    from e in query, where: e.status == ^statuses_or_status
  end

  def by_status(query, statuses_or_status) when is_list(statuses_or_status) do
    from e in query, where: e.status in ^statuses_or_status
  end

  def active(query \\ __MODULE__) do
    from e in query, where: e.status in [:pending, :running, :paused]
  end

  def completed(query \\ __MODULE__) do
    from e in query, where: e.status in [:completed, :failed, :cancelled, :timeout]
  end

  def recent(query \\ __MODULE__, limit \\ 100) do
    from e in query, order_by: [desc: e.inserted_at], limit: ^limit
  end

  def expired(query \\ __MODULE__) do
    now = DateTime.utc_now()

    from e in query,
      where: e.status in [:pending, :running, :paused],
      where: e.expires_at < ^now
  end

  def with_checkpoints(query \\ __MODULE__) do
    from e in query, preload: [:checkpoints]
  end

  def with_steps(query \\ __MODULE__) do
    from e in query, preload: [:steps]
  end

  def with_workflow(query \\ __MODULE__) do
    from e in query, preload: [:workflow]
  end

  # Helpers

  defp normalize_output(output) when is_list(output) do
    %{productions: output}
  end

  defp normalize_output(output) when is_map(output), do: output
  defp normalize_output(output), do: %{value: output}

  defp normalize_error(%{__exception__: true} = error) do
    %{
      type: error.__struct__ |> to_string(),
      message: Exception.message(error),
      # Optionally include formatted stacktrace
      stacktrace: nil
    }
  end

  defp normalize_error({kind, reason, stacktrace}) do
    %{
      type: to_string(kind),
      message: inspect(reason),
      stacktrace: Exception.format_stacktrace(stacktrace)
    }
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}

  defp compute_total_duration(changeset) do
    case {changeset.data.started_at, get_change(changeset, :completed_at)} do
      {started, completed} when not is_nil(started) and not is_nil(completed) ->
        duration_ms = DateTime.diff(completed, started, :millisecond)
        stats = Map.put(changeset.data.stats || %{}, :total_duration_ms, duration_ms)
        put_change(changeset, :stats, stats)

      _ ->
        changeset
    end
  end

  @doc """
  Checks if execution can be resumed.
  """
  def resumable?(%__MODULE__{status: status}) do
    status in [:paused, :failed]
  end

  @doc """
  Checks if execution is in a terminal state.
  """
  def terminal?(%__MODULE__{status: status}) do
    status in [:completed, :failed, :cancelled, :timeout]
  end
end

defmodule Imgd.Executions.NodeExecution do
  @moduledoc """
  Tracks individual node execution within a workflow execution.

  Each time a node runs (including retries), a new NodeExecution record
  is created to capture input, output, timing, and any errors.
  """
  @derive {Jason.Encoder,
           except: [:__meta__, :execution]}
  use Imgd.Schema
  import Imgd.ChangesetHelpers

  alias Imgd.Executions.Execution

  @type status :: :pending | :queued | :running | :completed | :failed | :skipped

  @statuses [:pending, :queued, :running, :completed, :failed, :skipped]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          execution_id: Ecto.UUID.t(),
          node_id: String.t(),
          node_type_id: String.t(),
          status: status(),
          input_data: map() | nil,
          output_data: map() | nil,
          error: map() | nil,
          metadata: map(),
          queued_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          attempt: pos_integer(),
          retry_of_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "node_executions" do
    belongs_to :execution, Execution

    # Which node in the workflow definition
    field :node_id, :string
    field :node_type_id, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending

    # Data flowing through this node
    field :input_data, :map
    field :output_data, :map
    field :error, :map

    # Extensible metadata (retry backoff info, queue details, etc.)
    field :metadata, :map, default: %{}

    # Timing - when it was queued, started executing, and finished
    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Retry tracking
    field :attempt, :integer, default: 1
    field :retry_of_id, :binary_id

    timestamps()
  end

  def changeset(node_execution, attrs) do
    node_execution
    |> cast(attrs, [
      :execution_id,
      :node_id,
      :node_type_id,
      :status,
      :input_data,
      :output_data,
      :error,
      :metadata,
      :queued_at,
      :started_at,
      :completed_at,
      :attempt,
      :retry_of_id
    ])
    |> validate_required([:execution_id, :node_id, :node_type_id, :status])
    |> validate_number(:attempt, greater_than: 0)
    |> validate_map_field(:input_data, allow_nil: true)
    |> validate_map_field(:output_data, allow_nil: true)
    |> validate_map_field(:error, allow_nil: true)
    |> validate_map_field(:metadata)
  end

  # Convenience functions

  @doc "Checks if the node execution is in a terminal state."
  def terminal?(%__MODULE__{status: status}) when status in [:completed, :failed, :skipped], do: true
  def terminal?(%__MODULE__{}), do: false

  @doc "Checks if the node execution succeeded."
  def succeeded?(%__MODULE__{status: :completed}), do: true
  def succeeded?(%__MODULE__{}), do: false

  @doc "Computes execution duration in milliseconds."
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil
  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  @doc "Computes queue wait time in milliseconds."
  def queue_time_ms(%__MODULE__{queued_at: nil}), do: nil
  def queue_time_ms(%__MODULE__{started_at: nil}), do: nil
  def queue_time_ms(%__MODULE__{queued_at: queued, started_at: started}) do
    DateTime.diff(started, queued, :millisecond)
  end

  @doc "Returns true if this is a retry attempt."
  def retry?(%__MODULE__{attempt: attempt}) when attempt > 1, do: true
  def retry?(%__MODULE__{}), do: false
end

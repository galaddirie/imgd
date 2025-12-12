defmodule Imgd.Executions.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, context (accumulated node outputs), and error information.
  """
  @derive {Jason.Encoder,
           except: [
             :__meta__,
             :workflow,
             :workflow_version,
             :triggered_by_user,
             :node_executions
           ]}
  use Imgd.Schema
  import Imgd.ChangesetHelpers

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Accounts.User
  alias Imgd.Executions.NodeExecution

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event

  @statuses [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout]

  defmodule Trigger do
    @moduledoc "Embedded trigger data for an execution"
    use Ecto.Schema

    @type t :: %__MODULE__{
            type: Imgd.Executions.Execution.trigger_type(),
            data: map()
          }

    @primary_key false
    embedded_schema do
      field :type, Ecto.Enum, values: [:manual, :schedule, :webhook, :event]
      field :data, :map, default: %{}
    end
  end

  defmodule Metadata do
    @moduledoc "Embedded metadata for execution correlation and debugging"
    use Ecto.Schema
    @derive Jason.Encoder

    @type t :: %__MODULE__{
            trace_id: String.t() | nil,
            correlation_id: String.t() | nil,
            triggered_by: String.t() | nil,
            parent_execution_id: Ecto.UUID.t() | nil,
            tags: map(),
            extras: map()
          }

    @primary_key false
    embedded_schema do
      field :trace_id, :string
      field :correlation_id, :string
      field :triggered_by, :string
      field :parent_execution_id, :binary_id
      field :tags, :map, default: %{}
      field :extras, :map, default: %{}
    end
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_version_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          status: status(),
          trigger: Trigger.t(),
          runic_build_log: [map()],
          runic_reaction_log: [map()],
          context: map(),
          output: map() | nil,
          error: map() | nil,
          waiting_for: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: Metadata.t() | nil,
          triggered_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "executions" do
    belongs_to :workflow_version, WorkflowVersion
    belongs_to :workflow, Workflow

    field :status, Ecto.Enum, values: @statuses, default: :pending

    embeds_one :trigger, Trigger, on_replace: :update
    embeds_one :metadata, Metadata, on_replace: :update

    # Runic integration - event logs for rebuilding state
    field :runic_build_log, {:array, :map}, default: []
    field :runic_reaction_log, {:array, :map}, default: []

    # Accumulated outputs from all nodes: %{"node_id" => output_data}
    field :context, :map, default: %{}

    # Final declared output (from an output node)
    field :output, :map

    # Error details if failed
    field :error, :map

    # For waiting/paused executions (e.g., awaiting webhook callback)
    field :waiting_for, :map

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :triggered_by_user, User, foreign_key: :triggered_by_user_id
    has_many :node_executions, NodeExecution

    timestamps()
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :workflow_version_id,
      :workflow_id,
      :status,
      :runic_build_log,
      :runic_reaction_log,
      :context,
      :output,
      :error,
      :waiting_for,
      :started_at,
      :completed_at,
      :expires_at,
      :triggered_by_user_id
    ])
    |> cast_embed(:trigger, required: true, with: &trigger_changeset/2)
    |> cast_embed(:metadata, with: &metadata_changeset/2)
    |> validate_required([:workflow_version_id, :workflow_id, :status])
    |> validate_map_field(:context)
    |> validate_map_field(:output, allow_nil: true)
    |> validate_map_field(:error, allow_nil: true)
    |> validate_map_field(:waiting_for, allow_nil: true)
    |> validate_list_of_maps(:runic_build_log)
    |> validate_list_of_maps(:runic_reaction_log)
  end

  defp trigger_changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :data])
    |> validate_required([:type])
    |> validate_map_field(:data)
  end

  defp metadata_changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :trace_id,
      :correlation_id,
      :triggered_by,
      :parent_execution_id,
      :tags,
      :extras
    ])
    |> validate_map_field(:tags, allow_nil: true)
    |> validate_map_field(:extras, allow_nil: true)
  end

  # Convenience functions

  @doc "Returns the trigger type as an atom."
  def trigger_type(%__MODULE__{trigger: %Trigger{type: type}}), do: type
  def trigger_type(%__MODULE__{trigger: nil}), do: nil

  @doc "Returns the trigger input data."
  def trigger_data(%__MODULE__{trigger: %Trigger{data: data}}), do: data
  def trigger_data(%__MODULE__{trigger: nil}), do: %{}

  @doc "Checks if the execution is in a terminal state."
  def terminal?(%__MODULE__{status: status})
      when status in [:completed, :failed, :cancelled, :timeout],
      do: true

  def terminal?(%__MODULE__{}), do: false

  @doc "Checks if the execution is still running."
  def active?(%__MODULE__{status: status}) when status in [:pending, :running, :paused], do: true
  def active?(%__MODULE__{}), do: false

  @doc "Computes duration in milliseconds, or nil if not yet complete."
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end
end

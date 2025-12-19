defmodule Imgd.Executions.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, context (accumulated node outputs), and error information.

  ## Engine Logs

  The `engine_build_log` and `engine_execution_log` fields store engine-specific
  diagnostic information. The format depends on the configured execution engine:

  - For the Runic engine: Contains Runic's build and reaction logs
  - For custom engines: Format is engine-specific

  These logs are useful for debugging but should not be relied upon for
  business logic as they may change with engine versions.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :workflow_version_id,
             :workflow_snapshot_id,
             :workflow_id,
             :status,
             :execution_type,
             :trigger,
             :engine_build_log,
             :engine_execution_log,
             :context,
             :pinned_data,
             :output,
             :error,
             :waiting_for,
             :started_at,
             :completed_at,
             :expires_at,
             :metadata,
             :triggered_by_user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema
  import Imgd.ChangesetHelpers

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Accounts.User
  alias Imgd.Executions.NodeExecution

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event
  @type execution_type :: :production | :preview | :partial

  @statuses [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout]
  @execution_types [:production, :preview, :partial]

  defmodule Trigger do
    @moduledoc "Embedded trigger data for an execution"
    @derive Jason.Encoder
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
          workflow_version_id: Ecto.UUID.t() | nil,
          workflow_snapshot_id: Ecto.UUID.t() | nil,
          workflow_id: Ecto.UUID.t(),
          status: status(),
          execution_type: execution_type(),
          trigger: Trigger.t(),
          engine_build_log: [map()],
          engine_execution_log: [map()],
          context: map(),
          pinned_data: map(),
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
    belongs_to :workflow_snapshot, Imgd.Workflows.WorkflowSnapshot
    belongs_to :workflow, Workflow

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :execution_type, Ecto.Enum, values: @execution_types, default: :production

    embeds_one :trigger, Trigger, on_replace: :update
    embeds_one :metadata, Metadata, on_replace: :update

    # Engine-agnostic diagnostic logs
    # These store engine-specific build and execution logs for debugging
    field :engine_build_log, {:array, :map}, default: []
    field :engine_execution_log, {:array, :map}, default: []

    # Accumulated outputs from all nodes: %{"node_id" => output_data}
    field :context, :map, default: %{}

    # Snapshotted pinned data for partial/preview runs
    field :pinned_data, :map, default: %{}

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
      :workflow_snapshot_id,
      :workflow_id,
      :status,
      :execution_type,
      :engine_build_log,
      :engine_execution_log,
      :context,
      :pinned_data,
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
    |> validate_required([:workflow_id, :status, :execution_type])
    |> validate_immutable_source()
    |> validate_map_field(:context)
    |> validate_map_field(:pinned_data)
    |> validate_map_field(:output, allow_nil: true)
    |> validate_map_field(:error, allow_nil: true)
    |> validate_map_field(:waiting_for, allow_nil: true)
    |> validate_list_of_maps(:engine_build_log)
    |> validate_list_of_maps(:engine_execution_log)
  end

  defp validate_immutable_source(changeset) do
    version_id = get_field(changeset, :workflow_version_id)
    snapshot_id = get_field(changeset, :workflow_snapshot_id)

    cond do
      is_nil(version_id) and is_nil(snapshot_id) ->
        add_error(changeset, :base, "execution must reference a version or snapshot")

      not is_nil(version_id) and not is_nil(snapshot_id) ->
        add_error(changeset, :base, "execution cannot reference both version and snapshot")

      true ->
        changeset
    end
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

  @doc """
  Formats an execution error reason into a standard error map.
  """
  def format_error(reason) do
    case reason do
      %{"type" => _} = error ->
        error

      {:node_failed, node_id, node_reason} ->
        %{"type" => "node_failure", "node_id" => node_id, "reason" => inspect(node_reason)}

      {:workflow_build_failed, build_reason} ->
        %{"type" => "workflow_build_failed", "reason" => inspect(build_reason)}

      {:build_failed, message} ->
        %{"type" => "build_failure", "message" => message}

      {:cycle_detected, node_ids} ->
        %{"type" => "cycle_detected", "node_ids" => node_ids}

      {:invalid_connections, connections} ->
        %{
          "type" => "invalid_connections",
          "connections" =>
            Enum.map(connections, fn
              c when is_struct(c) -> Map.from_struct(c)
              c -> c
            end)
        }

      {:update_failed, %Ecto.Changeset{} = changeset} ->
        %{"type" => "update_failed", "errors" => inspect(changeset.errors)}

      {:unexpected_error, message} ->
        %{"type" => "unexpected_error", "message" => message}

      {:caught_error, kind, caught_reason} ->
        %{"type" => "caught_error", "kind" => inspect(kind), "reason" => inspect(caught_reason)}

      other ->
        %{"type" => "unknown", "reason" => inspect(other)}
    end
  end

  @doc "Computes duration in milliseconds, or nil if not yet complete."
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  @doc "Computes duration in microseconds, or nil if not yet complete."
  def duration_us(%__MODULE__{started_at: nil}), do: nil
  def duration_us(%__MODULE__{completed_at: nil}), do: nil

  def duration_us(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :microsecond)
  end

  # ===========================================================================
  # Engine Log Accessors (backward compatibility + convenience)
  # ===========================================================================

  @doc """
  Returns the engine build log.

  For the Runic engine, this contains workflow construction events.
  """
  def build_log(%__MODULE__{engine_build_log: log}), do: log

  @doc """
  Returns the engine execution log.

  For the Runic engine, this contains reaction/execution events.
  """
  def execution_log(%__MODULE__{engine_execution_log: log}), do: log
end

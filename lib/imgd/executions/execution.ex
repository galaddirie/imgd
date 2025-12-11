defmodule Imgd.Executions.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, and error information.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :workflow_version_id,
             :workflow_version_tag,
             :status,
             :trigger,
             :trigger_type,
             :output,
             :context,
             :error,
             :started_at,
             :completed_at,
             :expires_at,
             :metadata,
             :workflow_id,
             :triggered_by_user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Accounts.User
  alias Imgd.Executions.NodeExecution

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event

  @typedoc "Trigger metadata used to start executions"
  @type trigger :: %{
          required(:type) => trigger_type(),
          optional(:data) => map()
        }

  @type runic_log_entry :: map()

  @type metadata :: __MODULE__.Metadata.t() | map() | nil

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_version_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          status: status(),
          trigger_type: trigger_type() | String.t(),
          trigger: trigger(),
          runic_build_log: [runic_log_entry()],
          runic_reaction_log: [runic_log_entry()],
          workflow_version_tag: String.t() | nil,
          output: map(), # declared output payload from a output node
          context: map(),
          error: map() | nil,
          waiting_for: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: metadata(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          workflow_version: WorkflowVersion.t() | Ecto.Association.NotLoaded.t(),
          triggered_by_user: %User{} | Ecto.Association.NotLoaded.t(),
          triggered_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @trigger_types [:manual, :schedule, :webhook, :event]

  schema "executions" do
    belongs_to :workflow_version, WorkflowVersion

    field :status, Ecto.Enum,
      values: [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout],
      default: :pending

    field :trigger, :map,
      default: %{
        type: :manual,
        data: %{} # input data
      }

    # Runic integration - the event log for rebuilding state
    # ComponentAdded events
    field :runic_build_log, {:array, :map}, default: []
    # ReactionOccurred events
    field :runic_reaction_log, {:array, :map}, default: []

    # Execution context - accumulated outputs from all nodes
    field :context, :map, default: %{}

    # Final output of the execution
    field :output, :map

    field :error, :map

    # For waiting/paused executions
    field :waiting_for, :map

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    # TTL for long-running cleanup
    field :expires_at, :utc_datetime_usec

    # Metadata for correlation, debugging
    embeds_one :metadata, Metadata, on_replace: :update do
      @derive Jason.Encoder

      field :trace_id, :string
      field :correlation_id, :string
      field :triggered_by, :string
      field :parent_execution_id, :binary_id
      field :tags, :map, default: %{}
      # Arbitrary custom values callers want to persist
      field :extras, :map, default: %{}
    end

    belongs_to :workflow, Workflow
    belongs_to :triggered_by_user, User, foreign_key: :triggered_by_user_id
    has_many :node_executions, NodeExecution

    # Virtual fields used by the UI
    field :trigger_type, :string, virtual: true
    field :workflow_version_tag, :string, virtual: true

    timestamps()
  end

  def changeset(execution, attrs) do
    execution
    |> cast(
      attrs,
      [
        :workflow_version_id,
        :workflow_id,
        :status,
        :trigger,
        :runic_build_log,
        :runic_reaction_log,
        :context,
        :output,
        :error,
        :waiting_for,
        :started_at,
        :completed_at,
        :expires_at,
        :metadata,
        :triggered_by_user_id
      ],
      empty_values: []
    )
    |> normalize_trigger()
    |> validate_required([:workflow_version_id, :workflow_id, :status, :trigger])
    |> validate_trigger()
    |> validate_map_field(:context)
    |> validate_map_field(:output)
    |> validate_map_field(:waiting_for, allow_nil: true)
    |> validate_map_field(:error, allow_nil: true)
    |> validate_list_of_maps(:runic_build_log)
    |> validate_list_of_maps(:runic_reaction_log)
    |> cast_embed(:metadata, with: &metadata_changeset/2, required: false)
  end

  defp normalize_trigger(changeset) do
    case normalize_trigger_map(get_field(changeset, :trigger)) do
      {:ok, trigger} -> put_change(changeset, :trigger, trigger)
      _ -> changeset
    end
  end

  defp validate_trigger(changeset) do
    validate_change(changeset, :trigger, fn :trigger, trigger ->
      case normalize_trigger_map(trigger) do
        {:ok, _} ->
          []

        {:error, :missing} ->
          [trigger: "must include a trigger type"]

        {:error, :not_map} ->
          [trigger: "must be a map with type and data keys"]

        {:error, {:invalid_type, value}} ->
          [trigger: "unsupported trigger type #{inspect(value)}"]

        {:error, :invalid_data} ->
          [trigger: "trigger data must be a map"]
      end
    end)
  end

  defp normalize_trigger_map(nil), do: {:error, :missing}

  defp normalize_trigger_map(trigger) when is_map(trigger) do
    type_value = Map.get(trigger, :type) || Map.get(trigger, "type")
    data = Map.get(trigger, :data) || Map.get(trigger, "data") || %{}

    with {:ok, type} <- cast_trigger_type(type_value),
         true <- is_map(data) do
      {:ok, %{type: type, data: data}}
    else
      {:error, type_error} -> {:error, {:invalid_type, type_error}}
      false -> {:error, :invalid_data}
    end
  end

  defp normalize_trigger_map(_), do: {:error, :not_map}

  defp cast_trigger_type(type) when type in @trigger_types, do: {:ok, type}

  defp cast_trigger_type(type) when is_binary(type) do
    case type do
      "manual" -> {:ok, :manual}
      "schedule" -> {:ok, :schedule}
      "webhook" -> {:ok, :webhook}
      "event" -> {:ok, :event}
      _ -> {:error, type}
    end
  end

  defp cast_trigger_type(type), do: {:error, type}

  defp validate_map_field(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_map(value) -> []
        is_nil(value) and Keyword.get(opts, :allow_nil, false) -> []
        true -> [{field, "must be a map"}]
      end
    end)
  end

  defp validate_list_of_maps(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_list(value) and Enum.all?(value, &is_map/1) ->
          []

        is_list(value) ->
          [{field, "must only contain map entries"}]

        is_nil(value) ->
          []

        true ->
          [{field, "must be a list of maps"}]
      end
    end)
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
end

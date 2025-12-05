defmodule Imgd.Workflows.Workflow do
  @moduledoc """
  Workflow definition schema.

  Stores the design-time workflow configuration including
  the serialized Runic build log and trigger configuration.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :version,
             :status,
             :definition,
             :definition_hash,
             :trigger_config,
             :settings,
             :published_at,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Workflows.{WorkflowVersion, Execution}
  alias Imgd.Accounts.User

  @type status :: :draft | :published | :archived

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :version, :integer, default: 1
    field :status, Ecto.Enum, values: [:draft, :published, :archived], default: :draft

    # Serialized Runic build_log - the workflow definition
    field :definition, :map

    # Content hash for deduplication and change detection
    field :definition_hash, :integer

    # Trigger configuration
    # %{type: :manual | :schedule | :webhook | :event, config: %{...}}
    field :trigger_config, :map, default: %{type: :manual, config: %{}}

    # Runtime settings
    field :settings, :map,
      default: %{
        # 5 minutes default
        timeout_ms: 300_000,
        max_retries: 3
      }

    field :published_at, :utc_datetime_usec

    has_many :versions, WorkflowVersion
    has_many :executions, Execution

    belongs_to :user, User

    timestamps()
  end

  @required_fields [:name, :user_id]
  @optional_fields [:description, :status, :definition, :trigger_config, :settings]

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> maybe_compute_definition_hash()
    |> unique_constraint(:name)
  end

  def publish_changeset(workflow, attrs \\ %{}) do
    workflow
    |> cast(attrs, [:definition])
    |> validate_required([:definition])
    |> validate_definition()
    |> maybe_compute_definition_hash()
    |> put_change(:status, :published)
    |> put_change(:published_at, DateTime.utc_now())
    |> increment_version()
  end

  def archive_changeset(workflow) do
    workflow
    |> change(status: :archived)
  end

  # Queries

  def published(query \\ __MODULE__) do
    from w in query, where: w.status == :published
  end

  def active(query \\ __MODULE__) do
    from w in query, where: w.status in [:draft, :published]
  end

  def with_schedule(query \\ __MODULE__) do
    from w in query, preload: [:schedule]
  end

  def with_webhook(query \\ __MODULE__) do
    from w in query, preload: [:webhook_endpoint]
  end

  # Helpers

  defp maybe_compute_definition_hash(changeset) do
    case get_change(changeset, :definition) do
      nil -> changeset
      definition -> put_change(changeset, :definition_hash, :erlang.phash2(definition))
    end
  end

  defp validate_definition(changeset) do
    case get_change(changeset, :definition) do
      nil ->
        changeset

      definition ->
        case validate_runic_definition(definition) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :definition, reason)
        end
    end
  end

  defp validate_runic_definition(definition) do
    # Attempt to rebuild workflow from definition
    try do
      events = deserialize_definition(definition)
      _workflow = Runic.Workflow.from_log(events)
      :ok
    rescue
      e -> {:error, "Invalid workflow definition: #{Exception.message(e)}"}
    end
  end

  defp increment_version(changeset) do
    case changeset.data.version do
      nil -> put_change(changeset, :version, 1)
      v -> put_change(changeset, :version, v + 1)
    end
  end

  @doc """
  Serializes a Runic workflow build log for storage.
  """
  def serialize_definition(build_log) when is_list(build_log) do
    build_log
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  # TODO: may need to look at this again later
  @doc """
  Deserializes a stored workflow definition back to Runic events.
  """
  def deserialize_definition(%{"encoded" => encoded}) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  @doc """
  Rebuilds a Runic.Workflow from the stored definition.
  """
  def to_runic_workflow(%__MODULE__{definition: definition}) do
    events = deserialize_definition(definition)
    Runic.Workflow.from_log(events)
  end
end

defmodule Imgd.Workflows.WorkflowVersion do
  @moduledoc """
  Immutable workflow version snapshot.

  Created each time a workflow is published, preserving the exact
  definition for audit trails and execution reproducibility.
  """
  use Imgd.Schema

  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.User
  alias __MODULE__.{Node, Connection, Trigger}

  @type trigger_type :: Workflow.trigger_type()

  @typedoc "Node snapshot stored on a version"
  @type node :: %Node{
          id: String.t(),
          type_id: String.t(),
          name: String.t(),
          config: map(),
          position: map(),
          notes: String.t() | nil
        }

  @typedoc "Connection snapshot stored on a version"
  @type connection :: %Connection{
          id: String.t(),
          source_node_id: String.t(),
          source_output: String.t(),
          target_node_id: String.t(),
          target_input: String.t()
        }

  @typedoc "Trigger snapshot stored on a version"
  @type trigger :: %Trigger{type: trigger_type(), config: map()}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          version_tag: String.t(),
          source_hash: String.t(),
          nodes: [node()],
          connections: [connection()],
          triggers: [trigger()],
          changelog: String.t() | nil,
          published_at: DateTime.t() | nil,
          published_by: Ecto.UUID.t() | nil,
          workflow_id: Ecto.UUID.t(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          published_by_user: %User{} | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "workflow_versions" do
    # Human-friendly semver, e.g. "1.0.0", "1.2.0-beta.1"
    field :version_tag, :string

    # Content hash of nodes + connections + triggers
    field :source_hash, :string

    embeds_many :nodes, Node, on_replace: :delete do
      # Unique ID within workflow
      field :id, :string
      # References Node.Type.id
      field :type_id, :string
      # User-given name
      field :name, :string
      # Node-specific configuration
      field :config, :map, default: %{}
      # {x, y} for UI
      field :position, :map, default: %{}
      # User notes
      field :notes, :string
    end

    embeds_many :connections, Connection, on_replace: :delete do
      field :id, :string
      field :source_node_id, :string
      # Output port name
      field :source_output, :string, default: "main"
      field :target_node_id, :string
      # Input port name
      field :target_input, :string, default: "main"
    end

    embeds_many :triggers, Trigger, on_replace: :delete do
      field :type, Ecto.Enum, values: [:manual, :webhook, :schedule, :event]
      field :config, :map, default: %{}
    end

    field :changelog, :string

    field :published_at, :utc_datetime_usec
    field :published_by, :binary_id
    belongs_to :published_by_user, User, foreign_key: :published_by

    belongs_to :workflow, Workflow

    # Immutable - no updates
    timestamps(updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :version_tag,
      :changelog,
      :published_at,
      :published_by,
      :source_hash,
      :workflow_id
    ])
    |> cast_embed(:nodes, with: &node_changeset/2, required: true)
    |> cast_embed(:connections, with: &connection_changeset/2)
    |> cast_embed(:triggers, with: &trigger_changeset/2)
    |> validate_required([:version_tag, :workflow_id, :source_hash])
    |> validate_version_tag()
    |> validate_source_hash()
    |> unique_constraint([:workflow_id, :version_tag])
  end

  defp node_changeset(node, attrs) do
    node
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name])
  end

  defp connection_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:id, :source_node_id, :source_output, :target_node_id, :target_input])
    |> validate_required([:id, :source_node_id, :target_node_id])
  end

  defp trigger_changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :config])
    |> validate_required([:type])
  end

  defp validate_version_tag(changeset) do
    validate_change(changeset, :version_tag, fn :version_tag, tag ->
      case Version.parse(tag) do
        {:ok, _parsed} ->
          []

        :error ->
          [version_tag: "must be a valid semantic version, e.g. 1.2.0"]
      end
    end)
  end

  defp validate_source_hash(changeset) do
    validate_change(changeset, :source_hash, fn :source_hash, hash ->
      cond do
        is_binary(hash) and byte_size(hash) == 64 and String.match?(hash, ~r/^[0-9a-f]+$/) ->
          []

        is_binary(hash) ->
          [source_hash: "must be a 64-character lowercase hex string"]

        true ->
          [source_hash: "must be a binary hash"]
      end
    end)
  end
end

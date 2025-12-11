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
             :status,
             :nodes,
             :connections,
             :triggers,
             :current_version_tag,
             :published_version_id,
             :settings,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Workflows.{WorkflowVersion, Execution}
  alias Imgd.Accounts.User

  @type status :: :draft | :active | :archived

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft

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
    end

    embeds_many :connections, Connection, on_replace: :delete do
      field :id, :string
      field :target_node_id, :string
      field :target_input, :string, default: "main"

      field :source_node_id, :string
      field :source_output, :string, default: "main"
    end

    # Note: we can have multiple triggers
    embeds_many :triggers, Trigger, on_replace: :delete do
      field :type, Ecto.Enum, values: [:manual, :webhook, :schedule, :event]
      field :config, :map, default: %{}
    end

    # Runtime settings
    field :settings, :map,
      default: %{
        timeout_ms: 300_000,
        max_retries: 3
      }

    # Optional: what you're *calling* the current draft version.
    # Could be "1.3.0-dev", "next", etc.
    field :current_version_tag, :string

    # Pointer to currently published immutable version
    belongs_to :published_version, WorkflowVersion

    has_many :versions, WorkflowVersion
    has_many :executions, Execution

    belongs_to :user, User

    timestamps()
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :current_version_tag,
      :published_version_id,
      :user_id
    ])
    |> cast_embed(:nodes, with: &node_changeset/2)
    |> cast_embed(:connections, with: &connection_changeset/2)
    |> cast_embed(:triggers, with: &trigger_changeset/2)
    |> cast(:settings, empty_values: [])
    |> validate_required([:name, :user_id])
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
end

defmodule Imgd.Workflows.WorkflowVersion do
  @moduledoc """
  Immutable workflow version snapshot.

  Created each time a workflow is published, preserving the exact
  definition for audit trails and execution reproducibility.
  """
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.User

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

    field :published_at, :utc_datetime
    field :published_by, :integer

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
    |> validate_required([:version_tag, :workflow_id])
    |> validate_change(:version_tag, fn :version_tag, tag ->
      case Version.parse(tag) do
        {:ok, _parsed} ->
          []
        :error ->
          [version_tag: "must be a valid semantic version, e.g. 1.2.0"]
      end
    end)
    |> unique_constraint([:workflow_id, :version_tag])
  end
end

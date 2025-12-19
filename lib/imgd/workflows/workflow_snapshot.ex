defmodule Imgd.Workflows.WorkflowSnapshot do
  @moduledoc """
  Immutable snapshot of workflow state for preview/dev executions.
  """
  use Imgd.Schema

  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Workflows.Embeds.{Node, Connection, Trigger}
  alias Imgd.Accounts.User

  @type purpose :: :preview | :partial | :debug

  schema "workflow_snapshots" do
    belongs_to :workflow, Workflow
    belongs_to :created_by, User, foreign_key: :created_by_user_id

    field :source_hash, :string

    embeds_many :nodes, Node, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete
    embeds_many :triggers, Trigger, on_replace: :delete

    field :purpose, Ecto.Enum, values: [:preview, :partial, :debug], default: :preview
    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:workflow_id, :created_by_user_id, :source_hash, :purpose, :expires_at])
    |> cast_embed(:nodes)
    |> cast_embed(:connections)
    |> cast_embed(:triggers)
    |> validate_required([:workflow_id, :created_by_user_id, :source_hash, :purpose])
  end

  @doc "Computes source hash using same algorithm as WorkflowVersion"
  def compute_source_hash(nodes, connections, triggers) do
    WorkflowVersion.compute_source_hash(nodes, connections, triggers)
  end
end

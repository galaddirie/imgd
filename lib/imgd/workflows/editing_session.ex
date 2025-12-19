defmodule Imgd.Workflows.EditingSession do
  @moduledoc """
  User-scoped editing context for a workflow.
  """
  use Imgd.Schema

  alias Imgd.Workflows.{Workflow, PinnedOutput}
  alias Imgd.Accounts.User

  schema "editing_sessions" do
    belongs_to :workflow, Workflow
    belongs_to :user, User

    field :base_source_hash, :string
    field :status, Ecto.Enum, values: [:active, :closed, :expired], default: :active
    field :last_activity_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    field :local_nodes, {:array, :map}
    field :local_connections, {:array, :map}

    has_many :pinned_outputs, PinnedOutput

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :workflow_id,
      :user_id,
      :base_source_hash,
      :status,
      :last_activity_at,
      :expires_at,
      :local_nodes,
      :local_connections
    ])
    |> validate_required([:workflow_id, :user_id, :status, :last_activity_at])
  end
end

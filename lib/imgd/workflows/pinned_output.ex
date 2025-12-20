defmodule Imgd.Workflows.PinnedOutput do
  @moduledoc """
  User-owned pinned node output for development iteration.
  """
  use Imgd.Schema

  alias Imgd.Workflows.{WorkflowDraft, EditingSession}
  alias Imgd.Accounts.User

  schema "pinned_outputs" do
    belongs_to :editing_session, EditingSession

    belongs_to :workflow_draft, WorkflowDraft,
      foreign_key: :workflow_draft_id,
      references: :workflow_id

    belongs_to :user, User

    field :node_id, :string
    field :source_hash, :string
    field :node_config_hash, :string
    field :data, :map
    field :source_execution_id, :binary_id
    field :label, :string

    field :pinned_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [
      :editing_session_id,
      :workflow_draft_id,
      :user_id,
      :node_id,
      :source_hash,
      :node_config_hash,
      :data,
      :source_execution_id,
      :label,
      :pinned_at
    ])
    |> validate_required([
      :editing_session_id,
      :workflow_draft_id,
      :user_id,
      :node_id,
      :source_hash,
      :node_config_hash,
      :data,
      :pinned_at
    ])
  end

  @doc "Check if this pin is compatible with given graph hash"
  def compatible?(%__MODULE__{source_hash: pin_hash}, current_hash) do
    pin_hash == current_hash
  end

  @doc "Check if node config has changed since pinning"
  def node_config_stale?(%__MODULE__{node_config_hash: pin_config}, current_config_hash) do
    pin_config != current_config_hash
  end
end

defmodule Imgd.Workflows.Workflow do
  @moduledoc """
  Workflow schema.
  """
  use Imgd.Schema
  import Ecto.Changeset
  alias Imgd.Workflows.{WorkflowDraft, WorkflowVersion, WorkflowShare}

  defimpl LiveVue.Encoder, for: Ecto.Association.NotLoaded do
    def encode(_struct, _opts), do: nil
  end

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :public,
             :current_version_tag,
             :published_version_id,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :public,
             :current_version_tag,
             :published_version_id,
             :user_id,
             :inserted_at,
             :updated_at,
             :draft,
             :user,
             :published_version
           ]}

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft
    field :public, :boolean, default: false
    field :current_version_tag, :string

    belongs_to :published_version, WorkflowVersion
    belongs_to :user, Imgd.Accounts.User
    has_one :draft, WorkflowDraft
    has_many :versions, WorkflowVersion
    has_many :shares, WorkflowShare

    timestamps()
  end

  @doc """
  Builds a changeset for creating/updating a workflow.
  """
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :public,
      :current_version_tag,
      :published_version_id,
      :user_id
    ])
    |> validate_required([:name, :user_id])
  end
end

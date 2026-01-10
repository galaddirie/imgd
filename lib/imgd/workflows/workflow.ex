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

  # ============================================================================
  # Convenience Functions
  # ============================================================================
  # todo: primary trigger doesnt make sense for multiple triggers
  @doc "Returns the primary trigger step for the workflow, if any."
  def primary_trigger(%__MODULE__{} = workflow) do
    workflow = Imgd.Repo.preload(workflow, :draft)

    case workflow.draft do
      nil -> nil
      draft -> Enum.find(draft.steps || [], &is_trigger_step?/1)
    end
  end

  # TODO: SUPPORT MULTIPLE TRIGGERS
  @doc "Checks if the workflow has a specific trigger type."
  def has_trigger_type?(%__MODULE__{} = workflow, type) do
    workflow = Imgd.Repo.preload(workflow, :draft)
    trigger_type_id = trigger_type_to_step_type_id(type)

    case workflow.draft do
      nil -> false
      draft -> Enum.any?(draft.steps || [], &(&1.type_id == trigger_type_id))
    end
  end

  defp is_trigger_step?(%{type_id: type_id}) do
    type_id in ["webhook_trigger", "schedule_trigger", "manual_input", "event_trigger"]
  end

  defp trigger_type_to_step_type_id(:webhook), do: "webhook_trigger"
  defp trigger_type_to_step_type_id(:schedule), do: "schedule_trigger"
  defp trigger_type_to_step_type_id(:manual), do: "manual_input"
  defp trigger_type_to_step_type_id(:event), do: "event_trigger"
  defp trigger_type_to_step_type_id(type) when is_binary(type), do: type
end

defmodule Imgd.Workflows.Workflow do
  @moduledoc """
  Workflow definition schema.

  Stores the design-time workflow configuration including
  nodes, connections, and trigger configuration.

  This is the mutable "draft" state. When published, an immutable
  `WorkflowVersion` snapshot is created.

  The actual graph definition (nodes, connections, triggers) is stored in
  `Imgd.Workflows.WorkflowDraft`, which is kept private to the owner.
  """
  use Imgd.Schema

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.Execution
  alias Imgd.Accounts.User

  @type status :: :draft | :active | :archived
  @type trigger_type :: :manual | :webhook | :schedule | :event

  @typedoc "Runtime configuration applied to workflow executions"
  @type settings :: %{
          optional(:timeout_ms) => pos_integer(),
          optional(:max_retries) => non_neg_integer(),
          optional(atom() | String.t()) => any()
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          description: String.t() | nil,
          status: status(),
          current_version_tag: String.t() | nil,
          published_version_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :current_version_tag,
             :published_version_id,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft

    # What you're calling the current draft version (e.g., "1.3.0-dev", "next")
    field :current_version_tag, :string

    # Pointer to currently published immutable version
    belongs_to :published_version, WorkflowVersion

    has_one :draft, Imgd.Workflows.WorkflowDraft
    has_many :versions, WorkflowVersion
    has_many :editing_sessions, Imgd.Workflows.EditingSession
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
    |> validate_required([:name, :user_id, :status])
    |> validate_length(:name, max: 200)
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc "Returns the primary trigger for the workflow, if any."
  def primary_trigger(%__MODULE__{} = workflow) do
    workflow = Imgd.Repo.preload(workflow, :draft)

    case workflow.draft do
      nil -> nil
      draft -> List.first(draft.triggers || [])
    end
  end

  @doc "Checks if the workflow has a specific trigger type."
  def has_trigger_type?(%__MODULE__{} = workflow, type) do
    workflow = Imgd.Repo.preload(workflow, :draft)

    case workflow.draft do
      nil -> false
      draft -> Enum.any?(draft.triggers || [], &(&1.type == type))
    end
  end
end

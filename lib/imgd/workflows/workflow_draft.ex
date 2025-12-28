defmodule Imgd.Workflows.WorkflowDraft do
  @moduledoc """
  Private mutable draft state for a workflow.
  """
  use Imgd.Schema

  alias Imgd.Workflows.Workflow
  alias Imgd.Workflows.Embeds.{Step, Connection, Trigger}

  @type t :: %__MODULE__{
          workflow_id: Ecto.UUID.t(),
          steps: [Step.t()],
          connections: [Connection.t()],
          triggers: [Trigger.t()],
          settings: map(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {LiveVue.Encoder,
           only: [
             :workflow_id,
             :steps,
             :connections,
             :triggers,
             :settings,
             :inserted_at,
             :updated_at
           ]}
  @primary_key {:workflow_id, :binary_id, autogenerate: false}
  schema "workflow_drafts" do
    belongs_to :workflow, Workflow, define_field: false

    embeds_many :steps, Step, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete
    embeds_many :triggers, Trigger, on_replace: :delete

    field :settings, :map,
      default: %{
        timeout_ms: 300_000,
        max_retries: 3
      }

    timestamps()
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:workflow_id, :settings])
    |> cast_embed(:steps)
    |> cast_embed(:connections)
    |> cast_embed(:triggers)
    |> validate_required([:workflow_id])
  end
end

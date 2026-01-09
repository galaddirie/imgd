defmodule Imgd.Workflows.WorkflowDraft do
  @moduledoc """
  Private mutable draft state for a workflow.
  """
  use Imgd.Schema

  alias Imgd.Workflows.Workflow
  alias Imgd.Workflows.Embeds.{Step, Connection}

  @type t :: %__MODULE__{
          workflow_id: Ecto.UUID.t(),
          steps: [Step.t()] | nil,
          connections: [Connection.t()] | nil,
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
             :settings,
             :inserted_at,
             :updated_at
           ]}
  @primary_key {:workflow_id, :binary_id, autogenerate: false}
  schema "workflow_drafts" do
    belongs_to :workflow, Workflow, define_field: false

    embeds_many :steps, Step, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete

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
    |> validate_required([:workflow_id])
    |> ensure_embed_defaults()
  end

  defp ensure_embed_defaults(changeset) do
    changeset
    |> maybe_put_default_embed(:steps)
    |> maybe_put_default_embed(:connections)
  end

  defp maybe_put_default_embed(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, [])
      _ -> changeset
    end
  end
end

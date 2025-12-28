defmodule Imgd.Workflows.Embeds.Step do
  @moduledoc """
  Embedded schema for workflow steps.
  Shared between Workflow (mutable) and WorkflowVersion (immutable).
  """
  @derive Jason.Encoder
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :type_id,
             :name,
             :config,
             :position,
             :notes
           ]}
  use Ecto.Schema
  import Ecto.Changeset
  import Imgd.ChangesetHelpers

  @primary_key false

  @type t :: %__MODULE__{
          id: String.t(),
          type_id: String.t(),
          name: String.t(),
          config: map(),
          position: map(),
          notes: String.t() | nil
        }

  embedded_schema do
    field :id, :string
    field :type_id, :string
    field :name, :string
    field :config, :map, default: %{}
    field :position, :map, default: %{}
    field :notes, :string
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name])
    |> validate_map_field(:config)
    |> validate_map_field(:position)
  end
end

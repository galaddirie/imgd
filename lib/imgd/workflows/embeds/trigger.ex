defmodule Imgd.Workflows.Embeds.Trigger do
  @moduledoc """
  Embedded schema for workflow triggers.
  Shared between Workflow (mutable) and WorkflowVersion (immutable).
  """
  @derive Jason.Encoder
  use Ecto.Schema
  import Ecto.Changeset
  import Imgd.ChangesetHelpers

  @primary_key false

  @type trigger_type :: :manual | :webhook | :schedule | :event

  @type t :: %__MODULE__{
          type: trigger_type(),
          config: map()
        }

  embedded_schema do
    field :type, Ecto.Enum, values: [:manual, :webhook, :schedule, :event]
    field :config, :map, default: %{}
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :config])
    |> validate_required([:type])
    |> validate_map_field(:config)
  end
end

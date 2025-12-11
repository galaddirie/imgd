defmodule Imgd.Workflows.Embeds.Node do
  @moduledoc """
  Embedded schema for workflow nodes.
  Shared between Workflow (mutable) and WorkflowVersion (immutable).
  """
  use Ecto.Schema
  import Ecto.Changeset

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

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name])
    |> validate_map_field(:config)
    |> validate_map_field(:position)
  end

  defp validate_map_field(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end

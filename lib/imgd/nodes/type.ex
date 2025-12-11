defmodule Imgd.Nodes.Type do
  @moduledoc """
  A Node Type is a template/blueprint for nodes users can add to workflows.
  Think: "HTTP Request", "Transform", "Postgres Query", "If/Else", etc.

  Each type defines:
  - Configuration schema (what the user configures in the UI)
  - Input/Output schemas (for validation and UI hints)
  - An executor module that implements the actual logic
  """

  # TODO: should we add versioning to node types?
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          category: String.t(),
          description: String.t(),
          icon: String.t(),
          # JSON Schema for node configuration
          config_schema: map(),
          # Expected input shape
          input_schema: map(),
          # Produced output shape
          output_schema: map(),
          # Module implementing NodeExecutor behaviour
          executor: module(),
          # :action | :trigger | :control_flow | :transform
          node_kind: atom()
        }

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  embedded_schema do
    field :name, :string
    field :category, :string
    field :description, :string
    field :icon, :string
    field :config_schema, :map, default: %{}
    field :input_schema, :map, default: %{}
    field :output_schema, :map, default: %{}
    field :executor, :string # todo proper
    field :node_kind, Ecto.Enum, values: [:action, :trigger, :control_flow, :transform]
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(node_type, attrs) do
    node_type
    |> cast(attrs, [:name, :category, :description, :icon, :config_schema, :input_schema, :output_schema, :executor, :node_kind])
    |> validate_required([:name, :category, :description, :icon, :config_schema, :input_schema, :output_schema, :executor, :node_kind])
    |> validate_map_field(:config_schema)
    |> validate_map_field(:input_schema)
    |> validate_map_field(:output_schema)
    |> validate_map_field(:executor)
    |> validate_map_field(:node_kind)
  end

  defp validate_map_field(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value) do
        []
      else
        [{field, "must be a map"}]
      end
    end)
  end
end

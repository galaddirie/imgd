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
    config_schema: map(),      # JSON Schema for node configuration
    input_schema: map(),       # Expected input shape
    output_schema: map(),      # Produced output shape
    executor: module(),        # Module implementing NodeExecutor behaviour
    node_kind: atom()          # :action | :trigger | :control_flow | :transform
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
    field :executor, WorkflowEngine.EctoTypes.Module
    field :node_kind, Ecto.Enum, values: [:action, :trigger, :control_flow, :transform]
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

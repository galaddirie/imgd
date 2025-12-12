defmodule Imgd.Workflows.Embeds.Connection do
  @moduledoc """
  Embedded schema for workflow connections (edges between nodes).
  Shared between Workflow (mutable) and WorkflowVersion (immutable).
  """
  @derive Jason.Encoder

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          id: String.t(),
          source_node_id: String.t(),
          source_output: String.t(),
          target_node_id: String.t(),
          target_input: String.t()
        }

  embedded_schema do
    field :id, :string
    field :source_node_id, :string
    field :source_output, :string, default: "main"
    field :target_node_id, :string
    field :target_input, :string, default: "main"
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:id, :source_node_id, :source_output, :target_node_id, :target_input])
    |> validate_required([:id, :source_node_id, :target_node_id])
  end
end

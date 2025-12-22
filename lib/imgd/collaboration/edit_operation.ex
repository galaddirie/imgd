defmodule Imgd.Collaboration.EditOperation do
  @moduledoc """
  Persisted edit operation for audit trail and recovery.
  """
  use Imgd.Schema

  @type op_type ::
          :add_node
          | :remove_node
          | :update_node_config
          | :update_node_position
          | :update_node_metadata
          | :add_connection
          | :remove_connection
          | :pin_node_output
          | :unpin_node_output
          | :disable_node
          | :enable_node

  schema "edit_operations" do
    # Client-generated UUID
    field :operation_id, :string
    # Server-assigned sequence
    field :seq, :integer

    field :type, Ecto.Enum,
      values: [
        :add_node,
        :remove_node,
        :update_node_config,
        :update_node_position,
        :update_node_metadata,
        :add_connection,
        :remove_connection
      ]

    field :payload, :map
    field :user_id, :binary_id
    field :client_seq, :integer

    belongs_to :workflow, Imgd.Workflows.Workflow

    timestamps(updated_at: false)
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:operation_id, :seq, :type, :payload, :user_id, :client_seq, :workflow_id])
    |> validate_required([:operation_id, :type, :payload, :workflow_id])
    |> unique_constraint(:operation_id)
    |> unique_constraint([:workflow_id, :seq])
  end
end


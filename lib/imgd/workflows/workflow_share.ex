defmodule Imgd.Workflows.WorkflowShare do
  @moduledoc """
  Workflow sharing schema for managing access to workflows by other users.

  Workflows can be shared with specific users and assigned roles:
  - `:viewer` - Can view the workflow but not edit
  - `:editor` - Can view and edit the workflow
  - `:owner` - The original creator (automatically assigned)
  """
  use Imgd.Schema

  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.User

  @type role :: :viewer | :editor | :owner
  @valid_roles [:viewer, :editor, :owner]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          role: role(),
          user_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          user: User.t() | Ecto.Association.NotLoaded.t(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "workflow_shares" do
    field :role, Ecto.Enum, values: @valid_roles, default: :viewer

    belongs_to :user, User
    belongs_to :workflow, Workflow

    timestamps()
  end

  @doc """
  Changeset for creating or updating workflow shares.
  """
  def changeset(workflow_share, attrs) do
    workflow_share
    |> cast(attrs, [:role, :user_id, :workflow_id])
    |> validate_required([:role, :user_id, :workflow_id])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:user_id, :workflow_id], name: :workflow_shares_user_id_workflow_id_index)
  end

  @doc """
  Returns the valid roles for workflow sharing.
  """
  def valid_roles, do: @valid_roles
end

defmodule Imgd.Workflows.Sharing do
  @moduledoc """
  Context for managing workflow sharing functionality.

  Provides functions to share workflows with other users, manage sharing permissions,
  and check access rights.
  """

  import Ecto.Query, warn: false
  alias Imgd.Repo

  alias Imgd.Workflows.Workflow
  alias Imgd.Workflows.WorkflowShare
  alias Imgd.Accounts.User
  alias Imgd.Accounts.Scope

  @type share_role :: :viewer | :editor | :owner

  @doc """
  Shares a workflow with a user, granting them the specified role.

  Returns `{:ok, share}` if successful, `{:error, changeset}` otherwise.
  """
  @spec share_workflow(Workflow.t(), Scope.t(), share_role()) ::
          {:ok, WorkflowShare.t()} | {:error, Ecto.Changeset.t() | :cannot_share_with_owner}
  def share_workflow(%Workflow{} = workflow, %Scope{} = scope, role) do
    user = scope.user

    # Don't allow sharing with the owner themselves
    if workflow.user_id == user.id do
      {:error, :cannot_share_with_owner}
    else
      %WorkflowShare{}
      |> WorkflowShare.changeset(%{
        workflow_id: workflow.id,
        user_id: user.id,
        role: role
      })
      |> Repo.insert()
    end
  end

  @doc """
  Updates the role for an existing workflow share.

  Returns `{:ok, share}` if successful, `{:error, changeset}` otherwise.
  """
  @spec update_share_role(WorkflowShare.t(), share_role()) ::
          {:ok, WorkflowShare.t()} | {:error, Ecto.Changeset.t()}
  def update_share_role(%WorkflowShare{} = share, role) do
    share
    |> WorkflowShare.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Removes sharing access for a user from a workflow.

  Returns `{:ok, share}` if successful, `{:error, reason}` otherwise.
  """
  @spec unshare_workflow(Workflow.t(), Scope.t()) ::
          {:ok, WorkflowShare.t()} | {:error, :not_found}
  def unshare_workflow(%Workflow{} = workflow, %Scope{} = scope) do
    user = scope.user

    case Repo.get_by(WorkflowShare, workflow_id: workflow.id, user_id: user.id) do
      nil -> {:error, :not_found}
      share -> Repo.delete(share)
    end
  end

  @doc """
  Lists all users who have access to a workflow, including the owner.

  Returns a list of {user, role} tuples.
  """
  @spec list_workflow_users(Workflow.t()) :: [{User.t(), share_role()}]
  def list_workflow_users(%Workflow{} = workflow) do
    # Get the owner
    owner = Repo.get!(User, workflow.user_id)

    # Get all shares with their users
    shares_query =
      from s in WorkflowShare,
        where: s.workflow_id == ^workflow.id,
        join: u in assoc(s, :user),
        select: {u, s.role}

    shares = Repo.all(shares_query)

    [{owner, :owner} | shares]
  end

  @doc """
  Checks if a user has access to a workflow with at least the specified role.

  Returns true if the user has access, false otherwise.
  """
  @spec can_access?(Workflow.t(), Scope.t() | nil, share_role()) :: boolean()
  def can_access?(%Workflow{} = workflow, scope, required_role) do
    user = scope && scope.user

    cond do
      # Public workflows are viewable by anyone
      workflow.public and required_role == :viewer -> true
      # No user provided
      is_nil(user) -> false
      # Owner has full access
      workflow.user_id == user.id -> true
      # Check share permissions
      true -> check_share_permissions(workflow, user, required_role)
    end
  end

  @doc """
  Checks if a user can edit a workflow.

  Returns true if the user has editor or owner access.
  """
  @spec can_edit?(Workflow.t(), Scope.t() | nil) :: boolean()
  def can_edit?(%Workflow{} = workflow, scope) do
    can_access?(workflow, scope, :editor)
  end

  @doc """
  Checks if a user can view a workflow.

  Returns true if the user has viewer, editor, or owner access.
  """
  @spec can_view?(Workflow.t(), Scope.t() | nil) :: boolean()
  def can_view?(%Workflow{} = workflow, scope) do
    can_access?(workflow, scope, :viewer)
  end

  @doc """
  Makes a workflow public (viewable by anyone).

  Returns `{:ok, workflow}` if successful, `{:error, changeset}` otherwise.
  """
  @spec make_public(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def make_public(%Workflow{} = workflow) do
    workflow
    |> Workflow.changeset(%{public: true})
    |> Repo.update()
  end

  @doc """
  Makes a workflow private (only accessible by owner and explicitly shared users).

  Returns `{:ok, workflow}` if successful, `{:error, changeset}` otherwise.
  """
  @spec make_private(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def make_private(%Workflow{} = workflow) do
    workflow
    |> Workflow.changeset(%{public: false})
    |> Repo.update()
  end

  @doc """
  Lists workflows accessible to a user.

  Returns a list of workflows the user can access, including their own and shared ones.
  """
  @spec list_accessible_workflows(Scope.t() | nil) :: [Workflow.t()]
  def list_accessible_workflows(nil), do: list_public_workflows()

  def list_accessible_workflows(%Scope{} = scope) do
    user = scope.user

    # Get all workflows the user can access in a single query
    query =
      from w in Workflow,
        left_join: s in WorkflowShare,
        on: s.workflow_id == w.id and s.user_id == ^user.id,
        where: w.user_id == ^user.id or not is_nil(s.id) or w.public == true,
        distinct: true

    Repo.all(query)
  end

  @doc """
  Lists all public workflows.

  Returns a list of workflows that are marked as public.
  """
  @spec list_public_workflows() :: [Workflow.t()]
  def list_public_workflows do
    Repo.all(from w in Workflow, where: w.public == true)
  end

  @doc """
  Gets the role a user has for a workflow.

  Returns the role (:owner, :editor, :viewer) or nil if no access.
  """
  @spec get_user_role(Workflow.t(), Scope.t() | nil) :: share_role() | nil
  def get_user_role(%Workflow{} = workflow, nil), do: if(workflow.public, do: :viewer, else: nil)

  def get_user_role(%Workflow{} = workflow, %Scope{} = scope) do
    user = scope.user

    cond do
      workflow.user_id == user.id ->
        :owner

      workflow.public ->
        :viewer

      true ->
        case Repo.get_by(WorkflowShare, workflow_id: workflow.id, user_id: user.id) do
          nil -> nil
          share -> share.role
        end
    end
  end

  # Private functions

  defp check_share_permissions(workflow, %User{} = user, required_role) do
    case Repo.get_by(WorkflowShare, workflow_id: workflow.id, user_id: user.id) do
      nil -> false
      share -> role_allows?(share.role, required_role)
    end
  end

  defp role_allows?(:owner, _required), do: true
  defp role_allows?(:editor, :editor), do: true
  defp role_allows?(:editor, :viewer), do: true
  defp role_allows?(:viewer, :viewer), do: true
  defp role_allows?(_role, _required), do: false
end

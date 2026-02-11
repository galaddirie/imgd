defmodule Imgd.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Imgd.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  ## Authorization

  The Scope module provides authorization checks for various resources.
  Permission functions follow the pattern `can_<action>_<resource>?/2`:

      Scope.can_view_workflow?(scope, workflow)
      Scope.can_edit_workflow?(scope, workflow)

  ## PubSub Authorization

  Use the PubSub-specific modules for subscription authorization:

      Imgd.Executions.PubSub.subscribe_execution(scope, execution_id)
      Imgd.Collaboration.EditSession.PubSub.subscribe_session(scope, workflow_id)
      Imgd.Runtime.Events.subscribe(scope, execution_id)

  ## Usage

      # In context modules, accept scope as first argument
      def list_workflows(%Scope{} = scope) do
        if Scope.can_view_workflow?(scope, workflow) do
          # ...
        end
      end

  ## Extending

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements, such as adding roles, permissions,
  or tenant information for multi-tenant applications.
  """

  alias Imgd.Accounts.User

  @type t :: %__MODULE__{
          user: User.t() | nil
        }

  defstruct user: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(User.t()) :: t()
  @spec for_user(nil) :: nil
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Returns the user from the scope, or nil if no scope/user.
  """
  @spec user(t() | nil) :: User.t() | nil
  def user(%__MODULE__{user: user}), do: user
  def user(nil), do: nil

  @doc """
  Returns the user ID from the scope, or nil if no scope/user.
  """
  @spec user_id(t() | nil) :: Ecto.UUID.t() | nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(_), do: nil

  @doc """
  Checks if the scope has an authenticated user.
  """
  @spec authenticated?(t() | nil) :: boolean()
  def authenticated?(%__MODULE__{user: %User{}}), do: true
  def authenticated?(_), do: false

  # ============================================================================
  # Workflow Permissions
  # ============================================================================

  @doc """
  Checks if the scope can view the given workflow.

  A user can view a workflow if:
  - They own the workflow
  - The workflow is public
  - They have been granted access via a share (any role)
  """
  @spec can_view_workflow?(t() | nil, map()) :: boolean()
  def can_view_workflow?(%__MODULE__{user: %User{id: user_id}}, %{user_id: owner_id})
      when user_id == owner_id,
      do: true

  def can_view_workflow?(_scope, %{public: true}), do: true

  def can_view_workflow?(%__MODULE__{user: %User{id: user_id}}, %{id: workflow_id}) do
    has_workflow_share?(user_id, workflow_id)
  end

  def can_view_workflow?(nil, %{public: true}), do: true
  def can_view_workflow?(_, _), do: false

  @doc """
  Checks if the scope can edit the given workflow.

  A user can edit a workflow if:
  - They own the workflow
  - They have been granted editor or owner role via a share
  """
  @spec can_edit_workflow?(t() | nil, map()) :: boolean()
  def can_edit_workflow?(%__MODULE__{user: %User{id: user_id}}, %{user_id: owner_id})
      when user_id == owner_id,
      do: true

  def can_edit_workflow?(%__MODULE__{user: %User{id: user_id}}, %{id: workflow_id}) do
    has_workflow_share?(user_id, workflow_id, [:editor, :owner])
  end

  def can_edit_workflow?(_, _), do: false

  @doc """
  Checks if the scope owns the given workflow.
  """
  @spec owns_workflow?(t() | nil, map()) :: boolean()
  def owns_workflow?(%__MODULE__{user: %User{id: user_id}}, %{user_id: owner_id}),
    do: user_id == owner_id

  def owns_workflow?(_, _), do: false

  # ============================================================================
  # Execution Permissions
  # ============================================================================

  @doc """
  Checks if the scope can view the given execution.

  Execution visibility is derived from the associated workflow's visibility.
  """
  @spec can_view_execution?(t() | nil, map()) :: boolean()
  def can_view_execution?(scope, %{workflow: workflow}) when not is_nil(workflow) do
    can_view_workflow?(scope, workflow)
  end

  def can_view_execution?(scope, %{workflow_id: workflow_id}) do
    case Imgd.Repo.get(Imgd.Workflows.Workflow, workflow_id) do
      nil -> false
      workflow -> can_view_workflow?(scope, workflow)
    end
  end

  def can_view_execution?(_, _), do: false

  @doc """
  Checks if the scope can create an execution for the given workflow.

  For production executions, view access is sufficient.
  For preview/partial executions, edit access is required.
  """
  @spec can_create_execution?(t() | nil, map(), atom()) :: boolean()
  def can_create_execution?(scope, workflow, execution_type)
      when execution_type in [:preview, :partial] do
    can_edit_workflow?(scope, workflow)
  end

  def can_create_execution?(scope, workflow, _execution_type) do
    can_view_workflow?(scope, workflow)
  end

  # ============================================================================
  # Edit Session Permissions
  # ============================================================================

  @doc """
  Checks if the scope can join an edit session for the given workflow.

  Edit sessions require edit access since they involve modifying workflow state.
  """
  @spec can_join_edit_session?(t() | nil, map()) :: boolean()
  def can_join_edit_session?(scope, workflow) do
    can_edit_workflow?(scope, workflow)
  end

  @doc """
  Checks if the scope can observe an edit session (read-only).

  Observation only requires view access.
  """
  @spec can_observe_edit_session?(t() | nil, map()) :: boolean()
  def can_observe_edit_session?(scope, workflow) do
    can_view_workflow?(scope, workflow)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp has_workflow_share?(user_id, workflow_id, roles \\ nil) do
    import Ecto.Query
    alias Imgd.Workflows.WorkflowShare

    query =
      from s in WorkflowShare,
        where: s.user_id == ^user_id and s.workflow_id == ^workflow_id

    query =
      if roles do
        from s in query, where: s.role in ^roles
      else
        query
      end

    Imgd.Repo.exists?(query)
  end
end

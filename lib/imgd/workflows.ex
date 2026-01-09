defmodule Imgd.Workflows do
  @moduledoc """
  Context for managing workflows, versions, drafts, and related functionality.

  All functions that require authorization accept a `Scope` as the first argument
  following Phoenix conventions. Permission checks are performed through the
  `Imgd.Accounts.Scope` module.

  ## Authorization

  - Use `Scope.can_view_workflow?/2` to check view permissions
  - Use `Scope.can_edit_workflow?/2` to check edit permissions
  - Use `Scope.owns_workflow?/2` to check ownership

  ## Examples

      # List workflows accessible to the user
      Workflows.list_workflows(scope)

      # Get a workflow (returns error if not accessible)
      {:ok, workflow} = Workflows.get_workflow(scope, workflow_id)

      # Update a workflow (requires edit permission)
      {:ok, workflow} = Workflows.update_workflow(scope, workflow, attrs)
  """

  import Ecto.Query, warn: false
  alias Imgd.Repo

  alias Imgd.Workflows.{Workflow, WorkflowVersion, WorkflowDraft, WorkflowShare}
  alias Imgd.Executions.Execution
  alias Imgd.Accounts.Scope

  @type workflow_params :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:public) => boolean(),
          optional(:current_version_tag) => String.t()
        }

  @type workflow_version_params :: %{
          required(:version_tag) => String.t(),
          optional(:changelog) => String.t()
        }

  @doc """
  Lists workflows accessible to the given scope.

  Returns workflows the user owns or has been shared with, including public workflows.
  Preloads user (owner) and shares associations for display purposes.
  """
  @spec list_workflows(Scope.t() | nil) :: [Workflow.t()]
  def list_workflows(nil), do: list_public_workflows()

  def list_workflows(%Scope{} = scope) do
    user_id = scope.user.id

    # Get all workflows the user can access in a single query
    query =
      from w in Workflow,
        left_join: s in WorkflowShare,
        on: s.workflow_id == w.id and s.user_id == ^user_id,
        where: w.user_id == ^user_id or not is_nil(s.id) or w.public == true,
        distinct: true,
        order_by: [desc: w.updated_at]

    Repo.all(query) |> Repo.preload([:user, :shares])
  end

  @doc """
  Lists public workflows.

  Returns all workflows marked as public.
  """
  @spec list_public_workflows() :: [Workflow.t()]
  def list_public_workflows do
    Repo.all(from w in Workflow, where: w.public == true, order_by: [desc: w.updated_at])
  end

  @doc """
  Determines the access level/state for a workflow relative to a scope.

  Returns:
  - `:owner` - if the user owns the workflow
  - `:viewer`, `:editor`, `:owner` - if the user has a share with that role
  - `:public` - if the workflow is public and user doesn't own or have a share
  - `nil` - if no access
  """
  @spec workflow_access_state(Scope.t() | nil, Workflow.t()) ::
          :owner | :viewer | :editor | :public | nil
  def workflow_access_state(%Scope{} = scope, %Workflow{} = workflow) do
    user_id = scope.user.id

    cond do
      workflow.user_id == user_id ->
        :owner

      share = Enum.find(workflow.shares || [], &(&1.user_id == user_id)) ->
        share.role

      workflow.public ->
        :public

      true ->
        nil
    end
  end

  def workflow_access_state(nil, %Workflow{public: true}), do: :public
  def workflow_access_state(_scope, _workflow), do: nil

  @doc """
  Lists workflows owned by the user in the scope.
  """
  @spec list_owned_workflows(Scope.t()) :: [Workflow.t()]
  def list_owned_workflows(%Scope{} = scope) do
    user_id = scope.user.id
    Repo.all(from w in Workflow, where: w.user_id == ^user_id, order_by: [desc: w.updated_at])
  end

  @doc """
  Returns a query for active workflows.
  """
  def list_active_workflows_query do
    from w in Workflow, where: w.status == :active
  end

  # ============================================================================

  @doc """
  Gets a single workflow by ID, checking access permissions.

  Returns `{:ok, workflow}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  @spec get_workflow(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(%Scope{} = scope, id), do: do_get_workflow(id, scope)
  def get_workflow(id, scope), do: do_get_workflow(id, scope)

  @doc """
  Finds an active published workflow by its configured webhook path and method.
  """
  @spec get_active_workflow_by_webhook(String.t(), String.t()) :: Workflow.t() | nil
  def get_active_workflow_by_webhook(path, method) do
    # method should be uppercase for consistency
    method = String.upcase(method)

    query =
      from w in Workflow,
        join: v in assoc(w, :published_version),
        where: w.status == :active,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS t WHERE t->>'type' = 'webhook' AND t->'config'->>'path' = ? AND (t->'config'->>'http_method' = ? OR (t->'config'->>'http_method' IS NULL AND ? = 'POST'))) OR EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS s WHERE s->>'type_id' = 'webhook_trigger' AND COALESCE(s->'config'->>'path', s->>'id') = ? AND (s->'config'->>'http_method' = ? OR (s->'config'->>'http_method' IS NULL AND ? = 'POST')))",
            v.triggers,
            ^path,
            ^method,
            ^method,
            v.steps,
            ^path,
            ^method,
            ^method
          ),
        limit: 1

    Repo.one(query)
  end

  @doc """
  Finds a workflow by its DRAFT webhook path and method.
  Ignores status (allows drafts).
  """
  @spec get_workflow_by_webhook_draft_path(String.t(), String.t()) :: Workflow.t() | nil
  def get_workflow_by_webhook_draft_path(path, method) do
    method = String.upcase(method)

    query =
      from w in Workflow,
        join: d in assoc(w, :draft),
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS t WHERE t->>'type' = 'webhook' AND t->'config'->>'path' = ? AND (t->'config'->>'http_method' = ? OR (t->'config'->>'http_method' IS NULL AND ? = 'POST'))) OR EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS s WHERE s->>'type_id' = 'webhook_trigger' AND COALESCE(s->'config'->>'path', s->>'id') = ? AND (s->'config'->>'http_method' = ? OR (s->'config'->>'http_method' IS NULL AND ? = 'POST')))",
            d.triggers,
            ^path,
            ^method,
            ^method,
            d.steps,
            ^path,
            ^method,
            ^method
          ),
        limit: 1

    Repo.one(query)
  end

  defp do_get_workflow(id, scope) do
    case Repo.get(Workflow, id) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, workflow}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Gets a workflow with its draft preloaded.

  Returns `{:ok, workflow}` with draft loaded, or `{:error, :not_found}`.
  """
  @spec get_workflow_with_draft(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  @spec get_workflow_with_draft(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow_with_draft(%Scope{} = scope, id), do: do_get_workflow_with_draft(id, scope)
  def get_workflow_with_draft(id, scope), do: do_get_workflow_with_draft(id, scope)

  defp do_get_workflow_with_draft(id, scope) do
    case Repo.get(Workflow, id) |> Repo.preload(:draft) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, workflow}
        else
          {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # Create/Update/Delete Functions
  # ============================================================================

  @doc """
  Creates a new workflow for the user in the scope.

  Returns `{:ok, workflow}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_workflow(Scope.t(), workflow_params()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(%Scope{} = scope, attrs) do
    user_id = scope.user.id

    %Workflow{}
    |> Workflow.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Updates a workflow, checking edit permissions.

  Returns `{:ok, workflow}` if successful, `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec update_workflow(Scope.t(), Workflow.t(), workflow_params()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      workflow
      |> Workflow.changeset(attrs)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Deletes a workflow, checking ownership permissions.

  Only owners can delete workflows. Returns `{:ok, workflow}` if successful,
  `{:error, :not_found | :access_denied}` otherwise.
  """
  @spec delete_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found | :access_denied}
  def delete_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    if Scope.owns_workflow?(scope, workflow) do
      Repo.delete(workflow)
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Archives a workflow, checking ownership permissions.

  Only owners can archive workflows. Returns `{:ok, workflow}` if successful,
  `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec archive_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def archive_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    update_workflow(scope, workflow, %{status: :archived})
  end

  @doc """
  Duplicates a workflow for the current user.

  Returns `{:ok, workflow}` if successful, `{:error, reason}` otherwise.
  """
  @spec duplicate_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, :access_denied | term()}
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.transaction(fn ->
        workflow = Repo.preload(workflow, :draft)

        draft =
          workflow.draft ||
            %WorkflowDraft{steps: [], connections: [], triggers: [], settings: %{}}

        workflow_attrs = %{
          name: "Copy of #{workflow.name}",
          description: workflow.description,
          status: :draft,
          public: false,
          current_version_tag: nil,
          published_version_id: nil
        }

        {:ok, duplicated} = create_workflow(scope, workflow_attrs)

        draft_attrs = %{
          steps: Enum.map(draft.steps || [], &Map.from_struct/1),
          connections: Enum.map(draft.connections || [], &Map.from_struct/1),
          triggers: Enum.map(draft.triggers || [], &Map.from_struct/1),
          settings: draft.settings || %{}
        }

        {:ok, _draft} =
          %WorkflowDraft{workflow_id: duplicated.id}
          |> WorkflowDraft.changeset(draft_attrs)
          |> Repo.insert()

        duplicated
      end)
      |> case do
        {:ok, duplicated} -> {:ok, duplicated}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Publishing Functions
  # ============================================================================

  @doc """
  Publishes a workflow version, creating a new published version.

  Returns `{:ok, {workflow, version}}` if successful, `{:error, reason}` otherwise.
  """
  @spec publish_workflow(Scope.t(), Workflow.t(), workflow_version_params()) ::
          {:ok, {Workflow.t(), WorkflowVersion.t()}} | {:error, any()}
  def publish_workflow(%Scope{} = scope, %Workflow{} = workflow, version_attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      Repo.transaction(fn ->
        # Get the current draft
        draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

        # Create new version from draft
        version_attrs =
          version_attrs
          |> Map.put(:workflow_id, workflow.id)
          |> Map.put(:source_hash, compute_source_hash(draft))
          |> Map.put(:steps, Enum.map(draft.steps, &Map.from_struct/1))
          |> Map.put(:connections, Enum.map(draft.connections || [], &Map.from_struct/1))
          |> Map.put(:triggers, Enum.map(draft.triggers || [], &Map.from_struct/1))
          |> Map.put(:published_by, scope.user.id)

        {:ok, version} =
          %WorkflowVersion{}
          |> WorkflowVersion.changeset(version_attrs)
          |> Repo.insert()

        # Update workflow to point to published version
        {:ok, updated_workflow} =
          workflow
          |> Workflow.changeset(%{
            published_version_id: version.id,
            status: :active,
            current_version_tag: version.version_tag
          })
          |> Repo.update()

        {updated_workflow, version}
      end)
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Version Functions
  # ============================================================================

  @doc """
  Gets a workflow version by ID, checking access permissions.

  Returns `{:ok, version}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow_version(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, WorkflowVersion.t()} | {:error, :not_found}
  def get_workflow_version(scope, id) do
    case Repo.get(WorkflowVersion, id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :not_found}

      %WorkflowVersion{workflow: workflow} = version ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, version}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Lists versions for a workflow, checking access permissions.

  Returns a list of versions if the user has access, empty list otherwise.
  """
  @spec list_workflow_versions(Scope.t() | nil, Workflow.t()) :: [WorkflowVersion.t()]
  def list_workflow_versions(scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from v in WorkflowVersion,
          where: v.workflow_id == ^workflow.id,
          order_by: [desc: v.published_at]
      )
    else
      []
    end
  end

  # ============================================================================
  # Draft Functions
  # ============================================================================

  @doc """
  Gets a workflow draft by workflow ID.

  Returns `{:ok, draft}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_draft(String.t() | Ecto.UUID.t()) :: {:ok, WorkflowDraft.t()} | {:error, :not_found}
  def get_draft(workflow_id) do
    case Repo.get_by(WorkflowDraft, workflow_id: workflow_id) do
      nil -> {:error, :not_found}
      draft -> {:ok, draft}
    end
  end

  @doc """
  Updates a workflow draft, checking edit permissions.

  Returns `{:ok, draft}` if successful, `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec update_workflow_draft(Scope.t(), Workflow.t(), map()) ::
          {:ok, WorkflowDraft.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_workflow_draft(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      case Repo.get_by(WorkflowDraft, workflow_id: workflow.id) do
        nil ->
          # Create draft if it doesn't exist
          %WorkflowDraft{}
          |> WorkflowDraft.changeset(Map.put(attrs, :workflow_id, workflow.id))
          |> Repo.insert()

        draft ->
          draft
          |> WorkflowDraft.changeset(attrs)
          |> Repo.update()
      end
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Execution Functions
  # ============================================================================

  @doc """
  Gets executions for a workflow, checking access permissions.

  Returns a list of executions if the user has access, empty list otherwise.
  """
  @spec list_workflow_executions(Scope.t() | nil, Workflow.t()) :: [Execution.t()]
  def list_workflow_executions(scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from e in Execution,
          where: e.workflow_id == ^workflow.id,
          order_by: [desc: e.inserted_at],
          limit: 100
      )
    else
      []
    end
  end

  @doc """
  Counts executions for a workflow by status.

  Returns a map with status counts.
  """
  @spec count_workflow_executions(Workflow.t()) :: %{optional(atom()) => non_neg_integer()}
  def count_workflow_executions(%Workflow{} = workflow) do
    query =
      from e in Execution,
        where: e.workflow_id == ^workflow.id,
        select: {e.status, count(e.id)},
        group_by: e.status

    Repo.all(query) |> Map.new()
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp compute_source_hash(%WorkflowDraft{} = draft) do
    # Create a deterministic hash of the workflow structure
    data = %{
      steps: draft.steps,
      connections: draft.connections,
      triggers: draft.triggers,
      settings: draft.settings
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode16()
    |> String.downcase()
  end
end

defmodule Imgd.Workflows do
  @moduledoc """
  Context for managing workflows, versions, drafts, and related functionality.

  Provides functions to create, read, update, and delete workflows, manage their
  versions and drafts, and handle publishing workflows.
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
  """
  @spec list_workflows(Scope.t() | nil) :: [Workflow.t()]
  def list_workflows(nil), do: list_public_workflows()

  def list_workflows(%Scope{} = scope) do
    user = scope.user

    # Get all workflows the user can access in a single query
    query =
      from w in Workflow,
        left_join: s in WorkflowShare,
        on: s.workflow_id == w.id and s.user_id == ^user.id,
        where: w.user_id == ^user.id or not is_nil(s.id) or w.public == true,
        distinct: true,
        order_by: [desc: w.updated_at]

    Repo.all(query)
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
  Lists workflows owned by the given user.

  Returns all workflows owned by the user in the scope.
  """
  @spec list_owned_workflows(Scope.t()) :: [Workflow.t()]
  def list_owned_workflows(%Scope{} = scope) do
    user = scope.user

    Repo.all(from w in Workflow, where: w.user_id == ^user.id, order_by: [desc: w.updated_at])
  end

  @doc """
  Gets a single workflow by ID, checking access permissions.

  Returns `{:ok, workflow}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(id, scope) do
    case Repo.get(Workflow, id) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
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
  @spec get_workflow_with_draft(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow_with_draft(id, scope) do
    case Repo.get(Workflow, id) |> Repo.preload(:draft) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
          {:ok, workflow}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a new workflow for the user in the scope.

  Returns `{:ok, workflow}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_workflow(workflow_params(), Scope.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(attrs, %Scope{} = scope) do
    user = scope.user

    %Workflow{}
    |> Workflow.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  @doc """
  Updates a workflow, checking edit permissions.

  Returns `{:ok, workflow}` if successful, `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec update_workflow(Workflow.t(), workflow_params(), Scope.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_workflow(%Workflow{} = workflow, attrs, scope) do
    if Imgd.Workflows.Sharing.can_edit?(workflow, scope) do
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
  @spec delete_workflow(Workflow.t(), Scope.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found | :access_denied}
  def delete_workflow(%Workflow{} = workflow, %Scope{} = scope) do
    user = scope.user

    if workflow.user_id == user.id do
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
  @spec archive_workflow(Workflow.t(), Scope.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def archive_workflow(%Workflow{} = workflow, scope) do
    update_workflow(workflow, %{status: :archived}, scope)
  end

  @doc """
  Publishes a workflow version, creating a new published version.

  Returns `{:ok, {workflow, version}}` if successful, `{:error, reason}` otherwise.
  """
  @spec publish_workflow(Workflow.t(), workflow_version_params(), Scope.t()) ::
          {:ok, {Workflow.t(), WorkflowVersion.t()}} | {:error, any()}
  def publish_workflow(%Workflow{} = workflow, version_attrs, scope) do
    if Imgd.Workflows.Sharing.can_edit?(workflow, scope) do
      Repo.transaction(fn ->
        # Get the current draft
        draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

        # Create new version from draft
        version_attrs =
          version_attrs
          |> Map.put(:workflow_id, workflow.id)
          |> Map.put(:source_hash, compute_source_hash(draft))
          |> Map.put(:nodes, Enum.map(draft.nodes, &Map.from_struct/1))
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

  @doc """
  Gets a workflow version by ID, checking access permissions.

  Returns `{:ok, version}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow_version(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, WorkflowVersion.t()} | {:error, :not_found}
  def get_workflow_version(id, scope) do
    case Repo.get(WorkflowVersion, id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :not_found}

      %WorkflowVersion{workflow: workflow} = version ->
        if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
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
  @spec list_workflow_versions(Workflow.t(), Scope.t() | nil) :: [WorkflowVersion.t()]
  def list_workflow_versions(%Workflow{} = workflow, scope) do
    if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
      Repo.all(
        from v in WorkflowVersion,
          where: v.workflow_id == ^workflow.id,
          order_by: [desc: v.published_at]
      )
    else
      []
    end
  end

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
  @spec update_workflow_draft(Workflow.t(), map(), Scope.t()) ::
          {:ok, WorkflowDraft.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_workflow_draft(%Workflow{} = workflow, attrs, scope) do
    if Imgd.Workflows.Sharing.can_edit?(workflow, scope) do
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

  @doc """
  Gets executions for a workflow, checking access permissions.

  Returns a list of executions if the user has access, empty list otherwise.
  """
  @spec list_workflow_executions(Workflow.t(), Scope.t() | nil) :: [Execution.t()]
  def list_workflow_executions(%Workflow{} = workflow, scope) do
    if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
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

  # Private functions

  defp compute_source_hash(%WorkflowDraft{} = draft) do
    # Create a deterministic hash of the workflow structure
    data = %{
      nodes: draft.nodes,
      connections: draft.connections,
      triggers: draft.triggers,
      settings: draft.settings
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode16()
    |> String.downcase()
  end
end

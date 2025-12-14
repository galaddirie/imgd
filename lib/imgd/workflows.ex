defmodule Imgd.Workflows do
  @moduledoc """
  Domain context for workflows and workflow versions.

  All operations are scoped to the caller via `Imgd.Accounts.Scope`. Scope
  must include a user; otherwise an `ArgumentError` is raised.

  ## Return Value Conventions

  - Query functions scoped by user in the query itself return raw values
  - Functions that verify ownership of a passed struct return `{:ok, result} | {:error, reason}`
  - Write operations return `{:ok, struct} | {:error, changeset | reason}`
  """

  import Ecto.Query, warn: false
  import Imgd.ContextHelpers, only: [normalize_attrs: 1, scope_user_id!: 1]

  alias Imgd.Accounts.Scope
  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Repo

  @type scope :: %Scope{}

  # ============================================================================
  # Workflows
  # ============================================================================

  @doc """
  Lists workflows for the given scope.

  Supports optional filters:
    * `:status` - a status atom or list of statuses
    * `:limit` - max number of rows
    * `:offset` - number of rows to skip (for pagination)
    * `:preload` - preload associations
    * `:order` - one of `:desc_inserted` (default), `:asc_name`, `:desc_name`
  """
  def list_workflows(%Scope{} = scope, opts \\ []) do
    user_id = scope_user_id!(scope)

    Workflow
    |> where([w], w.user_id == ^user_id)
    |> maybe_filter_status(opts)
    |> maybe_order(opts)
    |> maybe_limit(opts)
    |> maybe_offset(opts)
    |> maybe_preload(opts)
    |> Repo.all()
  end

  @doc """
  Fetches a workflow belonging to the given scope or returns nil.
  """
  def get_workflow(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    Workflow
    |> where([w], w.user_id == ^user_id and w.id == ^id)
    |> maybe_preload(opts)
    |> Repo.one()
  end

  @doc """
  Fetches a workflow belonging to the given scope or raises.
  """
  def get_workflow!(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    Workflow
    |> where([w], w.user_id == ^user_id and w.id == ^id)
    |> maybe_preload(opts)
    |> Repo.one!()
  end

  @doc """
  Fetches a workflow by name belonging to the given scope or returns nil.
  If multiple workflows exist with the same name, returns the most recently inserted one.
  """
  def get_workflow_by_name(%Scope{} = scope, name, opts \\ []) do
    user_id = scope_user_id!(scope)

    Workflow
    |> where([w], w.user_id == ^user_id and w.name == ^name)
    |> order_by([w], desc: w.inserted_at)
    |> limit(1)
    |> maybe_preload(opts)
    |> Repo.one()
  end

  @doc """
  Returns a changeset for tracking workflow changes.
  """
  def change_workflow(%Workflow{} = workflow, attrs \\ %{}) do
    Workflow.changeset(workflow, attrs)
  end

  @doc """
  Creates a new workflow owned by the given scope's user.
  """
  def create_workflow(%Scope{} = scope, attrs \\ %{}) do
    user_id = scope_user_id!(scope)

    attrs =
      attrs
      |> normalize_attrs()
      |> Map.put(:user_id, user_id)
      |> Map.drop(["user_id"])

    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing workflow after confirming ownership.
  """
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- authorize_workflow(scope, workflow) do
      workflow
      |> Workflow.changeset(attrs |> normalize_attrs() |> drop_protected_keys())
      |> Repo.update()
    end
  end

  @doc """
  Archives the workflow (sets status to `:archived`).
  """
  def archive_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    update_workflow(scope, workflow, %{status: :archived})
  end

  @doc """
  Duplicates a workflow for the same owner.

  By default the name is suffixed with "(Copy)" unless overridden via attrs.
  The duplicated workflow is created as a draft without any published version.
  """
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow) do
      name = Map.get(attrs, :name) || Map.get(attrs, "name") || "#{workflow.name} (Copy)"

      clone_attrs =
        workflow
        |> Map.take([
          :description,
          :nodes,
          :connections,
          :triggers,
          :settings,
          :current_version_tag
        ])
        |> Map.merge(%{
          name: name,
          status: :draft,
          published_version_id: nil
        })
        |> Map.merge(drop_protected_keys(attrs))

      create_workflow(scope, clone_attrs)
    end
  end

  @doc """
  Checks if a workflow's content has changed compared to its published version.

  Returns true if the workflow needs to be updated and republished.
  """
  def workflow_content_changed?(%Workflow{} = workflow) do
    current_hash = compute_source_hash(workflow)
    published_hash = get_published_source_hash(workflow)

    current_hash != published_hash
  end

  @doc """
  Publishes a workflow by creating an immutable workflow version and marking the
  workflow as active.

  Options (attrs):
    * `:version_tag` - required if the workflow has no `current_version_tag`
    * `:changelog` - optional changelog text
    * `:status` - workflow status to set (defaults to `:active`)
  """
  def publish_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow),
         {:ok, version_tag} <- resolve_version_tag(workflow, attrs) do
      source_hash = compute_source_hash(workflow)

      Repo.transact(fn ->
        version_params = %{
          version_tag: version_tag,
          workflow_id: workflow.id,
          source_hash: source_hash,
          nodes: Enum.map(workflow.nodes || [], &Map.from_struct/1),
          connections: Enum.map(workflow.connections || [], &Map.from_struct/1),
          triggers: Enum.map(workflow.triggers || [], &Map.from_struct/1),
          changelog: Map.get(attrs, :changelog) || Map.get(attrs, "changelog"),
          published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          published_by: scope.user.id
        }

        with {:ok, version} <-
               %WorkflowVersion{}
               |> WorkflowVersion.changeset(version_params)
               |> Repo.insert(),
             {:ok, updated_workflow} <-
               workflow
               |> Workflow.changeset(%{
                 status: Map.get(attrs, :status) || Map.get(attrs, "status") || :active,
                 current_version_tag: version_tag,
                 published_version_id: version.id
               })
               |> Repo.update() do
          {:ok, %{workflow: updated_workflow, version: version}}
        end
      end)
    end
  end

  # ============================================================================
  # Workflow Versions
  # ============================================================================

  @doc """
  Lists workflow versions for a workflow owned by the scope.

  Returns `{:ok, versions}` or `{:error, :forbidden}`.
  """
  def list_workflow_versions(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow) do
      versions =
        WorkflowVersion
        |> where([v], v.workflow_id == ^workflow.id)
        |> order_by([v], desc: v.inserted_at)
        |> maybe_limit(opts)
        |> maybe_offset(opts)
        |> maybe_preload(opts)
        |> Repo.all()

      {:ok, versions}
    end
  end

  @doc """
  Fetches a specific workflow version by ID.

  Returns `{:ok, version}`, `{:ok, nil}`, or `{:error, :forbidden}`.
  """
  def get_workflow_version(%Scope{} = scope, %Workflow{} = workflow, version_id, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow) do
      version =
        WorkflowVersion
        |> where([v], v.workflow_id == ^workflow.id and v.id == ^version_id)
        |> maybe_preload(opts)
        |> Repo.one()

      {:ok, version}
    end
  end

  @doc """
  Fetches a specific workflow version by ID or raises.

  Returns `{:ok, version}` or `{:error, :forbidden}`.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_workflow_version!(%Scope{} = scope, %Workflow{} = workflow, version_id, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow) do
      version =
        WorkflowVersion
        |> where([v], v.workflow_id == ^workflow.id and v.id == ^version_id)
        |> maybe_preload(opts)
        |> Repo.one!()

      {:ok, version}
    end
  end

  @doc """
  Fetches a workflow version by version tag.

  Returns `{:ok, version}`, `{:ok, nil}`, or `{:error, :forbidden}`.
  """
  def get_workflow_version_by_tag(%Scope{} = scope, %Workflow{} = workflow, tag, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow) do
      version =
        WorkflowVersion
        |> where([v], v.workflow_id == ^workflow.id and v.version_tag == ^tag)
        |> maybe_preload(opts)
        |> Repo.one()

      {:ok, version}
    end
  end

  @doc """
  Returns a changeset for workflow versions.
  """
  def change_workflow_version(%WorkflowVersion{} = version, attrs \\ %{}) do
    WorkflowVersion.changeset(version, attrs)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp authorize_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    case workflow.user_id == scope_user_id!(scope) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp drop_protected_keys(attrs) when is_map(attrs) do
    Map.drop(attrs, [
      :user_id,
      "user_id",
      :published_version,
      "published_version",
      :published_version_id,
      "published_version_id"
    ])
  end

  defp drop_protected_keys(attrs), do: attrs

  defp maybe_filter_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      statuses when is_list(statuses) -> where(query, [w], w.status in ^statuses)
      status -> where(query, [w], w.status == ^status)
    end
  end

  defp maybe_limit(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      limit -> limit(query, ^limit)
    end
  end

  defp maybe_offset(query, opts) do
    case Keyword.get(opts, :offset) do
      nil -> query
      offset -> offset(query, ^offset)
    end
  end

  defp maybe_preload(query, opts) do
    case Keyword.get(opts, :preload, []) do
      [] -> query
      preloads -> preload(query, ^preloads)
    end
  end

  defp maybe_order(query, opts) do
    case Keyword.get(opts, :order, :desc_inserted) do
      :asc_name -> order_by(query, [w], asc: w.name)
      :desc_name -> order_by(query, [w], desc: w.name)
      _ -> order_by(query, [w], desc: w.inserted_at)
    end
  end

  defp resolve_version_tag(%Workflow{} = workflow, attrs) do
    tag =
      Map.get(attrs, :version_tag) ||
        Map.get(attrs, "version_tag") ||
        workflow.current_version_tag ||
        "1.0.0"

    if is_binary(tag) and tag != "" do
      {:ok, tag}
    else
      {:error, :missing_version_tag}
    end
  end

  def compute_source_hash(%Workflow{} = workflow) do
    payload = %{
      nodes: normalize_embeds(workflow.nodes),
      connections: normalize_embeds(workflow.connections),
      triggers: normalize_embeds(workflow.triggers),
      settings: workflow.settings || %{}
    }

    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_embeds(nil), do: []

  defp normalize_embeds(list) when is_list(list) do
    Enum.map(list, &normalize_embed/1)
  end

  defp normalize_embeds(other), do: other

  defp normalize_embed(%_struct{} = embed) do
    embed
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp normalize_embed(other), do: other

  def get_published_source_hash(%Workflow{} = workflow) do
    if workflow.published_version_id do
      case Repo.get(WorkflowVersion, workflow.published_version_id) do
        nil -> nil
        version -> version.source_hash
      end
    else
      nil
    end
  end
end

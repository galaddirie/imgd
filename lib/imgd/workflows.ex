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
  alias Imgd.Workflows.{Workflow, WorkflowVersion, WorkflowDraft}
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
    |> filter_preloads(opts)
    |> Repo.all()
  end

  defp filter_preloads(query, opts) do
    case Keyword.get(opts, :preload, []) do
      [] ->
        query

      preloads ->
        # Ensure :draft is only preloaded if explicitly requested,
        # but in list view we typically don't want it.
        preload(query, ^preloads)
    end
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
    |> filter_preloads(opts)
    |> Repo.one!()
  end

  @doc """
  Fetches a workflow and its private draft. Only accessible to owner.
  """
  def get_workflow_for_edit(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    Workflow
    |> where([w], w.user_id == ^user_id and w.id == ^id)
    |> preload([:draft])
    |> filter_preloads(opts)
    |> Repo.one()
    |> case do
      nil -> nil
      workflow -> {:ok, ensure_draft_exists(workflow)}
    end
  end

  defp ensure_draft_exists(workflow) do
    if workflow.draft do
      workflow
    else
      {:ok, draft} = create_draft(workflow)
      %{workflow | draft: draft}
    end
  end

  defp create_draft(%Workflow{id: id}) do
    %WorkflowDraft{}
    |> WorkflowDraft.changeset(%{workflow_id: id})
    |> Repo.insert()
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

    Repo.transact(fn ->
      with {:ok, workflow} <-
             %Workflow{}
             |> Workflow.changeset(attrs)
             |> Repo.insert(),
           {:ok, draft} <-
             %WorkflowDraft{}
             |> WorkflowDraft.changeset(Map.merge(attrs, %{workflow_id: workflow.id}))
             |> Repo.insert() do
        {:ok, %{workflow | draft: draft}}
      end
    end)
  end

  @doc """
  Updates an existing workflow after confirming ownership.
  """
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow) do
      Repo.transact(fn ->
        workflow_res =
          workflow
          |> Workflow.changeset(drop_protected_keys(attrs))
          |> Repo.update()

        # If draft-related fields are present, update the draft
        draft_res =
          if has_draft_attrs?(attrs) do
            update_draft(workflow, attrs)
          else
            {:ok, nil}
          end

        with {:ok, updated_workflow} <- workflow_res,
             {:ok, _} <- draft_res do
          {:ok, Repo.preload(updated_workflow, :draft, force: true)}
        end
      end)
    end
  end

  defp has_draft_attrs?(attrs) do
    Enum.any?(
      [
        :nodes,
        :connections,
        :triggers,
        :settings,
        "nodes",
        "connections",
        "triggers",
        "settings"
      ],
      &Map.has_key?(attrs, &1)
    )
  end

  defp update_draft(workflow, attrs) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{workflow_id: workflow.id}

    draft
    |> WorkflowDraft.changeset(attrs)
    |> Repo.insert_or_update()
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

      workflow = Repo.preload(workflow, :draft)
      draft = workflow.draft

      clone_attrs =
        workflow
        |> Map.take([:description, :current_version_tag])
        |> Map.merge(%{
          name: name,
          status: :draft,
          published_version_id: nil
        })
        |> Map.merge(drop_protected_keys(attrs))

      with {:ok, new_workflow} <- create_workflow(scope, clone_attrs) do
        # Copy draft content
        if draft do
          update_draft(
            new_workflow,
            Map.take(draft, [:nodes, :connections, :triggers, :settings])
          )
        end

        {:ok, new_workflow}
      end
    end
  end

  @doc """
  Checks if a workflow's content has changed compared to its published version.

  Returns true if the workflow needs to be updated and republished.
  """
  def workflow_content_changed?(%Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :draft)
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
      workflow = Repo.preload(workflow, :draft)
      draft = workflow.draft || %WorkflowDraft{}
      source_hash = compute_source_hash(workflow)

      Repo.transact(fn ->
        version_params = %{
          version_tag: version_tag,
          workflow_id: workflow.id,
          source_hash: source_hash,
          nodes: Enum.map(draft.nodes || [], &Map.from_struct/1),
          connections: Enum.map(draft.connections || [], &Map.from_struct/1),
          triggers: Enum.map(draft.triggers || [], &Map.from_struct/1),
          changelog: Map.get(attrs, :changelog) || Map.get(attrs, "changelog"),
          published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          published_by: scope.user.id
        }

        with {:ok, version} <-
               %WorkflowVersion{}
               |> WorkflowVersion.changeset(version_params)
               |> Repo.insert(),
             {:ok, _updated_workflow} <-
               workflow
               |> Workflow.changeset(%{
                 status: Map.get(attrs, :status) || Map.get(attrs, "status") || :active,
                 current_version_tag: version_tag,
                 published_version_id: version.id
               })
               |> Repo.update() do
          {:ok, version}
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
  # Pin Management (Delegated to EditingSessions)
  # ============================================================================

  @doc """
  Pins a node's output data for development-time caching.
  """
  def pin_node_output(%Scope{} = scope, %Workflow{} = workflow, node_id, output_data, opts \\ []) do
    with {:ok, pid} <- Imgd.Workflows.EditingSessions.get_or_start_session(scope, workflow),
         workflow <- Repo.preload(workflow, :draft),
         {:ok, node} <- find_node(workflow, node_id) do
      node_config_hash = compute_node_config_hash(node)
      source_hash = compute_source_hash(workflow)

      Imgd.Workflows.EditingSession.Server.pin_output(pid, %{
        node_id: node_id,
        source_hash: source_hash,
        node_config_hash: node_config_hash,
        data: output_data,
        source_execution_id: Keyword.get(opts, :execution_id),
        label: Keyword.get(opts, :label)
      })
    end
  end

  @doc """
  Removes a pinned output from a node.
  """
  def unpin_node_output(%Scope{} = scope, %Workflow{} = workflow, node_id) do
    with {:ok, pid} <- Imgd.Workflows.EditingSessions.get_or_start_session(scope, workflow) do
      Imgd.Workflows.EditingSession.Server.unpin_output(pid, node_id)
      {:ok, workflow}
    end
  end

  @doc """
  Removes all pinned outputs from a workflow for the current user.
  """
  def clear_all_pins(%Scope{} = scope, %Workflow{} = workflow) do
    with {:ok, pid} <- Imgd.Workflows.EditingSessions.get_or_start_session(scope, workflow) do
      Imgd.Workflows.EditingSession.Server.clear_pins(pid)
      {:ok, workflow}
    end
  end

  @doc """
  Extracts just the data from pinned outputs.
  Returns a map of %{node_id => data} suitable for seeding execution context.
  """
  def extract_pinned_data(pins) when is_list(pins) do
    pins
    |> Map.new(&{&1.node_id, &1.data})
  end

  def extract_pinned_data(pins) when is_map(pins) do
    # For backward compatibility if needed, but mostly for snapshotted data
    pins
  end

  # ============================================================================
  # Source Hash Computation
  # ============================================================================

  @doc """
  Computes a SHA-256 hash of the workflow's executable content.

  Used to detect changes between the draft workflow and its published version.
  """
  @spec compute_source_hash(Workflow.t()) :: String.t()
  def compute_source_hash(%Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{}

    compute_source_hash_from_attrs(
      draft.nodes || [],
      draft.connections || [],
      draft.triggers || []
    )
  end

  @doc """
  Computes a SHA-256 hash from raw attributes (nodes, connections, triggers).
  """
  def compute_source_hash_from_attrs(nodes, connections, triggers) do
    WorkflowVersion.compute_source_hash(nodes, connections, triggers)
  end

  @doc """
  Returns the source hash of the currently published version, or nil if unpublished.
  """
  @spec get_published_source_hash(Workflow.t()) :: String.t() | nil
  def get_published_source_hash(%Workflow{published_version_id: nil}), do: nil

  def get_published_source_hash(%Workflow{published_version_id: version_id}) do
    case Repo.get(WorkflowVersion, version_id) do
      nil -> nil
      version -> version.source_hash
    end
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

  # ============================================================================
  # Private Helpers for Pins
  # ============================================================================

  defp find_node(%Workflow{} = workflow, node_id) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{}

    case Enum.find(draft.nodes || [], &(&1.id == node_id)) do
      nil -> {:error, :node_not_found}
      node -> {:ok, node}
    end
  end

  @doc """
  Computes a hash of the node's configuration and type.
  Used to detect if a pin is stale.
  """
  def compute_node_config_hash(%{config: config, type_id: type_id}) do
    %{config: config, type_id: type_id}
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end

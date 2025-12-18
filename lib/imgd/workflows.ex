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

  # 1MB limit for pinned data
  @pin_max_size_bytes 1_048_576

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
  # Pin Management
  # ============================================================================

  @doc """
  Pins a node's output data for development-time caching.

  The pin includes a config hash to detect when the node's configuration
  has changed since pinning (potentially invalidating the pin).

  ## Options

  - `:execution_id` - Optional execution ID the data came from
  - `:label` - Optional user description for the pin

  ## Returns

  - `{:ok, updated_workflow}` - Pin saved successfully
  - `{:error, :forbidden}` - User doesn't own workflow
  - `{:error, :node_not_found}` - Node ID doesn't exist in workflow
  - `{:error, :pin_too_large}` - Pin data exceeds size limit
  """
  def pin_node_output(%Scope{} = scope, %Workflow{} = workflow, node_id, output_data, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, node} <- find_node(workflow, node_id),
         :ok <- validate_pin_size(output_data) do
      pin = %{
        "data" => output_data,
        "pinned_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "pinned_by" => scope.user.id,
        "config_hash" => compute_node_config_hash(node),
        "source_execution_id" => Keyword.get(opts, :execution_id),
        "label" => Keyword.get(opts, :label)
      }

      pinned_outputs = Map.put(workflow.pinned_outputs || %{}, node_id, pin)

      workflow
      |> Workflow.changeset(%{pinned_outputs: pinned_outputs})
      |> Repo.update()
    end
  end

  @doc """
  Updates an existing pin's data without changing metadata.

  Useful for quickly re-pinning from a new execution.
  """
  def update_pin_data(%Scope{} = scope, %Workflow{} = workflow, node_id, new_data, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, existing_pin} <- get_existing_pin(workflow, node_id),
         :ok <- validate_pin_size(new_data) do
      updated_pin =
        existing_pin
        |> Map.put("data", new_data)
        |> Map.put("pinned_at", DateTime.utc_now() |> DateTime.to_iso8601())
        |> maybe_update_label(Keyword.get(opts, :label))
        |> maybe_update_execution_id(Keyword.get(opts, :execution_id))

      pinned_outputs = Map.put(workflow.pinned_outputs, node_id, updated_pin)

      workflow
      |> Workflow.changeset(%{pinned_outputs: pinned_outputs})
      |> Repo.update()
    end
  end

  defp maybe_update_label(pin, nil), do: pin
  defp maybe_update_label(pin, label), do: Map.put(pin, "label", label)

  defp maybe_update_execution_id(pin, nil), do: pin
  defp maybe_update_execution_id(pin, id), do: Map.put(pin, "source_execution_id", id)

  @doc """
  Removes a pinned output from a node.
  """
  def unpin_node_output(%Scope{} = scope, %Workflow{} = workflow, node_id) do
    with :ok <- authorize_workflow(scope, workflow) do
      pinned_outputs = Map.delete(workflow.pinned_outputs || %{}, node_id)

      workflow
      |> Workflow.changeset(%{pinned_outputs: pinned_outputs})
      |> Repo.update()
    end
  end

  @doc """
  Removes all pinned outputs from a workflow.
  """
  def clear_all_pins(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      workflow
      |> Workflow.changeset(%{pinned_outputs: %{}})
      |> Repo.update()
    end
  end

  @doc """
  Returns pinned outputs with staleness and validity information.

  Each pin is annotated with:
  - `stale` - true if node config has changed since pinning
  - `node_exists` - true if the node still exists in the workflow
  - `age_seconds` - how long ago the pin was created

  ## Example

      %{
        "node_123" => %{
          "data" => %{...},
          "pinned_at" => "2024-01-15T...",
          "stale" => false,
          "node_exists" => true,
          "age_seconds" => 3600
        }
      }
  """
  def get_pinned_outputs_with_status(%Workflow{} = workflow) do
    node_map = Map.new(workflow.nodes || [], &{&1.id, &1})
    now = DateTime.utc_now()

    (workflow.pinned_outputs || %{})
    |> Enum.map(fn {node_id, pin} ->
      node = Map.get(node_map, node_id)
      current_hash = node && compute_node_config_hash(node)
      pin_hash = Map.get(pin, "config_hash") || Map.get(pin, :config_hash)
      stale? = current_hash != nil and pin_hash != current_hash

      pinned_at = parse_pin_datetime(pin)
      age_seconds = if pinned_at, do: DateTime.diff(now, pinned_at, :second), else: nil

      annotated_pin =
        pin
        |> Map.put("stale", stale?)
        |> Map.put("node_exists", node != nil)
        |> Map.put("age_seconds", age_seconds)

      {node_id, annotated_pin}
    end)
    |> Map.new()
  end

  @doc """
  Returns only stale pins (where node config has changed).
  """
  def get_stale_pins(%Workflow{} = workflow) do
    workflow
    |> get_pinned_outputs_with_status()
    |> Enum.filter(fn {_id, pin} -> pin["stale"] == true end)
    |> Map.new()
  end

  @doc """
  Returns orphaned pins (where node no longer exists).
  """
  def get_orphaned_pins(%Workflow{} = workflow) do
    workflow
    |> get_pinned_outputs_with_status()
    |> Enum.filter(fn {_id, pin} -> pin["node_exists"] == false end)
    |> Map.new()
  end

  @doc """
  Removes all orphaned pins (pins for nodes that no longer exist).
  """
  def cleanup_orphaned_pins(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      node_ids = MapSet.new(workflow.nodes || [], & &1.id)

      cleaned_pins =
        (workflow.pinned_outputs || %{})
        |> Enum.filter(fn {node_id, _} -> MapSet.member?(node_ids, node_id) end)
        |> Map.new()

      workflow
      |> Workflow.changeset(%{pinned_outputs: cleaned_pins})
      |> Repo.update()
    end
  end

  @doc """
  Extracts just the data from pinned outputs (for injection into execution context).

  Returns a map of `%{node_id => data}` suitable for seeding execution context.
  """
  def extract_pinned_data(%Workflow{pinned_outputs: pins}) do
    (pins || %{})
    |> Enum.map(fn {node_id, pin} ->
      data = Map.get(pin, "data") || Map.get(pin, :data)
      {node_id, data}
    end)
    |> Map.new()
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
    WorkflowVersion.compute_source_hash(
      workflow.nodes || [],
      workflow.connections || [],
      workflow.triggers || []
    )
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

  defp find_node(%Workflow{nodes: nodes}, node_id) do
    case Enum.find(nodes || [], &(&1.id == node_id)) do
      nil -> {:error, :node_not_found}
      node -> {:ok, node}
    end
  end

  defp get_existing_pin(%Workflow{pinned_outputs: pins}, node_id) do
    case Map.get(pins || %{}, node_id) do
      nil -> {:error, :not_pinned}
      pin -> {:ok, pin}
    end
  end

  defp compute_node_config_hash(%{config: config, type_id: type_id}) do
    %{config: config, type_id: type_id}
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp validate_pin_size(data) do
    case Jason.encode(data) do
      {:ok, json} when byte_size(json) <= @pin_max_size_bytes ->
        :ok

      {:ok, json} ->
        {:error, {:pin_too_large, byte_size(json), @pin_max_size_bytes}}

      {:error, _} ->
        {:error, :pin_not_serializable}
    end
  end

  defp parse_pin_datetime(pin) do
    raw = Map.get(pin, "pinned_at") || Map.get(pin, :pinned_at)

    case raw do
      nil ->
        nil

      %DateTime{} = dt ->
        dt

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end
end

defmodule Imgd.Executions do
  @moduledoc """
  Logic for workflow executions and node executions.

  All functions require an `Imgd.Accounts.Scope` with a user, ensuring callers
  only interact with their own workflows and executions.

  ## Return Value Conventions

  - Query functions scoped by user in the query itself return raw values
  - Functions that verify ownership of a passed struct return `{:ok, result} | {:error, reason}`
  - Write operations return `{:ok, struct} | {:error, changeset | reason}`
  """

  import Ecto.Query, warn: false
  import Imgd.ContextHelpers, only: [normalize_attrs: 1, scope_user_id!: 1]

  alias Imgd.Accounts.Scope
  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Workflows.{Workflow, WorkflowVersion, WorkflowDraft}
  alias Imgd.Repo
  require Logger

  @type scope :: %Scope{}

  # ============================================================================
  # Executions
  # ============================================================================

  @doc """
  Lists executions visible to the scope's user.

  Options:
    * `:workflow` - limit to a specific workflow struct
    * `:workflow_id` - limit to a workflow id
    * `:status` - status atom or list of statuses
    * `:limit` - max rows
    * `:offset` - rows to skip (for pagination)
    * `:before` - cursor-based pagination, executions before this datetime
    * `:after` - cursor-based pagination, executions after this datetime
    * `:preload` - list of associations to preload
    * `:order` - `:desc_started` (default) or `:desc_inserted`
  """
  def list_executions(%Scope{} = scope, opts \\ []) do
    user_id = scope_user_id!(scope)

    Execution
    |> join(:inner, [e], w in assoc(e, :workflow))
    |> where([_e, w], w.user_id == ^user_id)
    |> select([e, _w], e)
    |> maybe_filter_workflow(opts)
    |> maybe_filter_status(opts)
    |> maybe_filter_cursor(opts)
    |> maybe_order_executions(opts)
    |> maybe_limit(opts)
    |> maybe_offset(opts)
    |> maybe_preload(opts)
    |> Repo.all()
  end

  @doc """
  Fetches an execution owned by the scope's user or returns nil.
  """
  def get_execution(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    Execution
    |> join(:inner, [e], w in assoc(e, :workflow))
    |> where([e, w], e.id == ^id and w.user_id == ^user_id)
    |> select([e, _w], e)
    |> maybe_preload(opts)
    |> Repo.one()
  end

  @doc """
  Fetches an execution owned by the scope's user or raises.
  """
  def get_execution!(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    Execution
    |> join(:inner, [e], w in assoc(e, :workflow))
    |> where([e, w], e.id == ^id and w.user_id == ^user_id)
    |> select([e, _w], e)
    |> maybe_preload(opts)
    |> Repo.one!()
  end

  @doc """
  Returns a changeset for tracking execution changes.
  """
  def change_execution(%Execution{} = execution, attrs \\ %{}) do
    Execution.changeset(execution, attrs)
  end

  @doc """
  Starts a production execution against a published version.
  """
  def start_production_execution(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow),
         {:ok, version} <- resolve_version_for_execution(workflow, attrs) do
      params =
        attrs
        |> drop_protected_execution_keys()
        |> Map.put(:workflow_id, workflow.id)
        |> Map.put(:workflow_version_id, version.id)
        |> Map.put(:workflow_snapshot_id, nil)
        |> Map.put(:execution_type, :production)
        |> Map.put(:pinned_data, %{})
        |> Map.put_new(:triggered_by_user_id, scope.user.id)

      %Execution{}
      |> Execution.changeset(params)
      |> Repo.insert()
    end
  end

  @doc """
  Starts a preview execution with an automatic snapshot.
  """
  def start_preview_execution(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow),
         {:ok, pid} <- Imgd.Workflows.EditingSessions.get_or_start_session(scope, workflow) do
      source_hash = Imgd.Workflows.compute_source_hash(workflow)

      # For preview, we still want a snapshot for persistence, but we can potentially
      # optimize this by checking if snapshot already exists for the current source_hash
      {:ok, snapshot} =
        Imgd.Workflows.Snapshots.get_or_create_with_hash(
          scope,
          workflow,
          source_hash
        )

      pinned_data =
        Imgd.Workflows.EditingSession.Server.get_compatible_pins(pid, source_hash)

      params =
        attrs
        |> drop_protected_execution_keys()
        |> Map.put(:workflow_id, workflow.id)
        |> Map.put(:workflow_version_id, nil)
        |> Map.put(:workflow_snapshot_id, snapshot.id)
        |> Map.put(:execution_type, :preview)
        |> Map.put(:pinned_data, pinned_data)
        |> Map.put_new(:triggered_by_user_id, scope.user.id)

      %Execution{}
      |> Execution.changeset(params)
      |> Repo.insert()
    end
  end

  @doc """
  Immediate (fast-path) execution for previews, bypassing Oban.
  """
  def start_and_run_fast_path(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    with {:ok, execution} <- start_preview_execution(scope, workflow, attrs) do
      # Preload and start runtime directly
      execution = preload_for_execution(execution)

      case Imgd.Runtime.Execution.Supervisor.start_execution(execution.id) do
        {:ok, _pid} -> {:ok, %{execution: execution}}
        {:error, {:already_started, _pid}} -> {:ok, %{execution: execution}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Starts a partial execution to a target node.
  """
  def start_partial_execution(
        %Scope{} = scope,
        %Workflow{} = workflow,
        target_node_id,
        attrs \\ %{}
      ) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow),
         {:ok, _node} <- find_workflow_node(workflow, target_node_id),
         {:ok, pid} <- Imgd.Workflows.EditingSessions.get_or_start_session(scope, workflow) do
      source_hash = Imgd.Workflows.compute_source_hash(workflow)

      {:ok, snapshot} =
        Imgd.Workflows.Snapshots.get_or_create_with_hash(scope, workflow, source_hash)

      compatible_pins =
        Imgd.Workflows.EditingSession.Server.get_compatible_pins(pid, source_hash)

      metadata =
        attrs
        |> Map.get(:metadata, %{})
        |> normalize_attrs()
        |> Map.update(
          :extras,
          %{
            "partial" => true,
            "target_node" => target_node_id,
            "target_nodes" => [target_node_id],
            "pinned_nodes" => Map.keys(compatible_pins)
          },
          fn extras ->
            extras
            |> Map.put("partial", true)
            |> Map.put("target_node", target_node_id)
            |> Map.put("target_nodes", [target_node_id])
            |> Map.put("pinned_nodes", Map.keys(compatible_pins))
          end
        )

      params =
        attrs
        |> drop_protected_execution_keys()
        |> Map.put(:workflow_id, workflow.id)
        |> Map.put(:workflow_version_id, nil)
        |> Map.put(:workflow_snapshot_id, snapshot.id)
        |> Map.put(:execution_type, :partial)
        |> Map.put(:pinned_data, compatible_pins)
        |> Map.put(:metadata, metadata)
        |> Map.put_new(:triggered_by_user_id, scope.user.id)

      %Execution{}
      |> Execution.changeset(params)
      |> Repo.insert()
    end
  end

  @doc """
  Starts an execution for the given workflow.
  """
  def start_execution(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    version_id = Map.get(attrs, :workflow_version_id) || Map.get(attrs, "workflow_version_id")

    cond do
      version_id == "draft" or (is_nil(version_id) and is_nil(workflow.published_version_id)) ->
        start_preview_execution(scope, workflow, attrs)

      true ->
        # Production execution against specific version or published default
        start_production_execution(scope, workflow, attrs)
    end
  end

  @doc """
  Updates an execution after confirming ownership.
  """
  def update_execution(%Scope{} = scope, %Execution{} = execution, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_execution(scope, execution) do
      execution
      |> Execution.changeset(drop_protected_execution_keys(attrs))
      |> Repo.update()
    end
  end

  # ============================================================================
  # Execution Scheduling (Oban)
  # ============================================================================

  @doc """
  Enqueues an execution for processing via Oban.

  This inserts an Oban job that will pick up the execution and run it
  via the WorkflowRunner. Includes OpenTelemetry trace context propagation.

  ## Options

  - `:scheduled_at` - Schedule the job for a future time
  - `:priority` - Job priority (0-3, lower is higher priority)

  Returns `{:ok, job}` or `{:error, reason}`.
  """
  def enqueue_execution(%Scope{} = scope, %Execution{} = execution, opts \\ []) do
    with :ok <- authorize_execution(scope, execution) do
      Imgd.Workers.ExecutionWorker.enqueue(execution.id, opts)
    end
  end

  @doc """
  Starts and enqueues an execution in a single operation.

  Creates the execution record and immediately enqueues it for processing.
  This is the primary way to trigger a workflow execution.

  ## Options

  All options from `start_execution/3` plus:
  - `:scheduled_at` - Schedule the job for a future time
  - `:priority` - Job priority (0-3, lower is higher priority)

  Returns `{:ok, %{execution: execution, job: job}}` or `{:error, reason}`.
  """
  def start_and_enqueue_execution(
        %Scope{} = scope,
        %Workflow{} = workflow,
        attrs \\ %{},
        opts \\ []
      ) do
    with {:ok, execution} <- start_execution(scope, workflow, attrs),
         {:ok, job} <- enqueue_execution(scope, execution, opts) do
      {:ok, %{execution: execution, job: job}}
    end
  end

  @doc """
  Cancels a pending or running execution.

  Updates the execution status to `:cancelled` and attempts to cancel
  any associated Oban job.

  Returns `{:ok, execution}` or `{:error, reason}`.
  """
  def cancel_execution(%Scope{} = scope, %Execution{} = execution) do
    with :ok <- authorize_execution(scope, execution),
         :ok <- validate_cancellable(execution) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # Cancel any pending Oban jobs for this execution
      cancel_oban_job(execution.id)

      execution
      |> Execution.changeset(%{
        status: :cancelled,
        completed_at: now
      })
      |> Repo.update()
    end
  end

  defp validate_cancellable(%Execution{status: status}) do
    if status in [:pending, :running, :paused] do
      :ok
    else
      {:error, {:not_cancellable, status}}
    end
  end

  defp cancel_oban_job(execution_id) do
    Oban.Job
    |> where([j], j.queue == "executions")
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("?->>'execution_id' = ?", j.args, ^execution_id))
    |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    :ok
  end

  # ============================================================================
  # Node Executions
  # ============================================================================

  @doc """
  Lists node executions for a given execution.

  Returns `{:ok, node_executions}` or `{:error, :forbidden}`.
  """
  def list_node_executions(%Scope{} = scope, %Execution{} = execution, opts \\ []) do
    with :ok <- authorize_execution(scope, execution) do
      node_executions =
        NodeExecution
        |> where([n], n.execution_id == ^execution.id)
        |> order_by([n], asc: n.inserted_at)
        |> maybe_preload(opts)
        |> maybe_limit(opts)
        |> maybe_offset(opts)
        |> Repo.all()

      {:ok, node_executions}
    end
  end

  @doc """
  Fetches a node execution by ID, verifying ownership through the execution chain.

  Returns the node execution or nil.
  """
  def get_node_execution(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    NodeExecution
    |> join(:inner, [n], e in assoc(n, :execution))
    |> join(:inner, [_n, e], w in assoc(e, :workflow))
    |> where([n, _e, w], n.id == ^id and w.user_id == ^user_id)
    |> select([n, _e, _w], n)
    |> maybe_preload(opts)
    |> Repo.one()
  end

  @doc """
  Fetches a node execution by ID or raises.
  """
  def get_node_execution!(%Scope{} = scope, id, opts \\ []) do
    user_id = scope_user_id!(scope)

    NodeExecution
    |> join(:inner, [n], e in assoc(n, :execution))
    |> join(:inner, [_n, e], w in assoc(e, :workflow))
    |> where([n, _e, w], n.id == ^id and w.user_id == ^user_id)
    |> select([n, _e, _w], n)
    |> maybe_preload(opts)
    |> Repo.one!()
  end

  @doc """
  Creates a node execution for the given execution.

  Returns `{:ok, node_execution}` or `{:error, reason}`.
  """
  def create_node_execution(%Scope{} = scope, %Execution{} = execution, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_execution(scope, execution) do
      attrs =
        attrs
        |> drop_protected_node_keys()
        |> Map.put(:execution_id, execution.id)

      %NodeExecution{}
      |> NodeExecution.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a node execution after confirming ownership.

  Returns `{:ok, node_execution}` or `{:error, reason}`.
  """
  def update_node_execution(%Scope{} = scope, %NodeExecution{} = node_execution, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_node_execution(scope, node_execution) do
      node_execution
      |> NodeExecution.changeset(drop_protected_node_keys(attrs))
      |> Repo.update()
    end
  end

  @doc """
  Returns a changeset for node executions.
  """
  def change_node_execution(%NodeExecution{} = node_execution, attrs \\ %{}) do
    NodeExecution.changeset(node_execution, attrs)
  end

  # ============================================================================
  # Partial Execution API
  # ============================================================================

  @doc """
  Executes a single node and its required upstream dependencies.

  This is the "Execute to Here" / "Run to Node" feature. It computes
  which nodes need to run to produce the target node's output, respecting
  any pinned outputs on the workflow.

  ## Options

  - `:trigger_data` - Initial trigger data (default: `%{}`)
  - `:async` - Run asynchronously (default: `true`)
  - `:subscribe_fun` - Optional function to call with execution_id for PubSub subscription

  ## Returns

  - `{:ok, execution}` - Execution created (check status after completion if async)
  - `{:error, :forbidden}` - User doesn't own workflow
  - `{:error, :node_not_found}` - Target node doesn't exist
  - `{:error, :no_executable_version}` - No published or draft version available
  - `{:error, reason}` - Other execution errors
  """
  def execute_node(%Scope{} = scope, %Workflow{} = workflow, node_id, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, _node} <- find_workflow_node(workflow, node_id) do
      trigger_data = Keyword.get(opts, :trigger_data, %{})

      attrs = %{
        trigger: %{type: :manual, data: trigger_data},
        metadata: Keyword.get(opts, :metadata, %{})
      }

      with {:ok, execution} <- start_partial_execution(scope, workflow, node_id, attrs) do
        execution = preload_for_execution(execution)
        maybe_subscribe(execution, opts)

        # Mode args are no longer needed as pins are already in execution
        run_with_mode(execution, :partial, %{}, opts)
      end
    end
  end

  # ============================================================================
  # Private: Partial Execution Implementation
  # ============================================================================

  defp run_with_mode(execution, mode, mode_args, opts) do
    async = Keyword.get(opts, :async, true)

    if async do
      run_async(execution, mode, mode_args, opts)
    else
      run_sync(execution, mode, mode_args)
    end
  end

  defp run_async(execution, mode, mode_args, opts) do
    # Convert mode_args to use string keys for Oban serialization
    string_mode_args =
      mode_args
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.into(%{})
      |> Map.put("partial", mode == :partial)

    opts = Keyword.put(opts, :metadata, string_mode_args)
    Imgd.Workers.ExecutionWorker.enqueue(execution.id, opts)
    {:ok, execution}
  end

  defp run_sync(execution, :partial, _mode_args) do
    # Start execution via Supervisor
    case Imgd.Runtime.Execution.Supervisor.start_execution(execution.id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, :normal} ->
            # Reload execution to return fresh state
            {:ok, Repo.get!(Execution, execution.id)}

          {:DOWN, ^ref, :process, _pid, reason} ->
            {:error, reason}
        end

      {:error, {:already_started, pid}} ->
        # Just monitor existing
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _} ->
            {:ok, Repo.get!(Execution, execution.id)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_subscribe(%Execution{id: execution_id}, opts) do
    case Keyword.get(opts, :subscribe_fun) do
      fun when is_function(fun, 1) -> fun.(execution_id)
      _ -> :ok
    end
  end

  defp preload_for_execution(execution) do
    # Only preload workflow (metadata) and version (snapshot).
    # Draft is NEVER loaded here as it might be a shared execution.
    Repo.preload(execution, [:workflow, workflow_version: [:workflow]])
  end

  # ============================================================================
  # Private: Validation Helpers
  # ============================================================================

  defp find_workflow_node(%Workflow{} = workflow, node_id) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{}

    case Enum.find(draft.nodes || [], &(&1.id == node_id)) do
      nil -> {:error, :node_not_found}
      node -> {:ok, node}
    end
  end

  # ============================================================================
  # Authorization Helpers
  # ============================================================================

  defp authorize_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    case workflow.user_id == scope_user_id!(scope) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp authorize_execution(%Scope{} = scope, %Execution{} = execution) do
    user_id = scope_user_id!(scope)

    authorized =
      Repo.exists?(
        from e in Execution,
          join: w in assoc(e, :workflow),
          where: e.id == ^execution.id and w.user_id == ^user_id
      )

    if authorized, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_node_execution(%Scope{} = scope, %NodeExecution{} = node_execution) do
    user_id = scope_user_id!(scope)

    authorized =
      Repo.exists?(
        from n in NodeExecution,
          join: e in assoc(n, :execution),
          join: w in assoc(e, :workflow),
          where: n.id == ^node_execution.id and w.user_id == ^user_id
      )

    if authorized, do: :ok, else: {:error, :forbidden}
  end

  # ============================================================================
  # Version Resolution
  # ============================================================================

  defp resolve_version_for_execution(%Workflow{} = workflow, attrs) do
    provided_version = Map.get(attrs, :workflow_version) || Map.get(attrs, "workflow_version")

    provided_version_id =
      Map.get(attrs, :workflow_version_id) || Map.get(attrs, "workflow_version_id")

    cond do
      provided_version_id == "draft" ->
        {:ok, nil}

      match?(%WorkflowVersion{}, provided_version) ->
        validate_version_belongs(workflow, provided_version)

      is_binary(provided_version_id) ->
        load_and_validate_version(workflow, provided_version_id)

      not is_nil(provided_version_id) ->
        {:error, :invalid_version_id}

      match?(%WorkflowVersion{}, workflow.published_version) ->
        validate_version_belongs(workflow, workflow.published_version)

      is_binary(workflow.published_version_id) ->
        load_and_validate_version(workflow, workflow.published_version_id)

      true ->
        {:error, :not_published}
    end
  end

  defp load_and_validate_version(%Workflow{} = workflow, version_id) do
    case Repo.get(WorkflowVersion, version_id) do
      nil -> {:error, :version_not_found}
      version -> validate_version_belongs(workflow, version)
    end
  end

  defp validate_version_belongs(
         %Workflow{id: workflow_id},
         %WorkflowVersion{workflow_id: workflow_id} = version
       ) do
    {:ok, version}
  end

  defp validate_version_belongs(_workflow, %WorkflowVersion{}), do: {:error, :version_mismatch}

  # ============================================================================
  # Query Helpers
  # ============================================================================

  defp maybe_filter_workflow(query, opts) do
    cond do
      match?(%Workflow{id: id} when not is_nil(id), Keyword.get(opts, :workflow)) ->
        workflow = Keyword.get(opts, :workflow)
        where(query, [e], e.workflow_id == ^workflow.id)

      Keyword.has_key?(opts, :workflow_id) ->
        where(query, [e], e.workflow_id == ^Keyword.get(opts, :workflow_id))

      true ->
        query
    end
  end

  defp maybe_filter_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      statuses when is_list(statuses) -> where(query, [e], e.status in ^statuses)
      status -> where(query, [e], e.status == ^status)
    end
  end

  defp maybe_filter_cursor(query, opts) do
    query
    |> maybe_filter_before(Keyword.get(opts, :before))
    |> maybe_filter_after(Keyword.get(opts, :after))
  end

  defp maybe_filter_before(query, nil), do: query
  defp maybe_filter_before(query, before), do: where(query, [e], e.started_at < ^before)

  defp maybe_filter_after(query, nil), do: query
  defp maybe_filter_after(query, after_dt), do: where(query, [e], e.started_at > ^after_dt)

  defp maybe_order_executions(query, opts) do
    case Keyword.get(opts, :order, :desc_started) do
      :desc_inserted -> order_by(query, [e], desc: e.inserted_at)
      _ -> order_by(query, [e], desc: e.started_at, desc: e.inserted_at)
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

  # ============================================================================
  # Key Filtering
  # ============================================================================

  defp drop_protected_execution_keys(attrs) when is_map(attrs) do
    Map.drop(attrs, [
      :workflow_id,
      "workflow_id",
      :workflow_version_id,
      "workflow_version_id",
      :triggered_by_user_id,
      "triggered_by_user_id",
      :id,
      "id",
      :inserted_at,
      "inserted_at",
      :updated_at,
      "updated_at"
    ])
  end

  defp drop_protected_execution_keys(attrs), do: attrs

  defp drop_protected_node_keys(attrs) when is_map(attrs) do
    Map.drop(attrs, [
      :execution_id,
      "execution_id",
      :id,
      "id",
      :inserted_at,
      "inserted_at",
      :updated_at,
      "updated_at"
    ])
  end

  defp drop_protected_node_keys(attrs), do: attrs
end

defmodule Imgd.Executions do
  @moduledoc """
  Context for workflow executions and node executions.

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
  alias Imgd.Executions.{Execution, NodeExecution, Context}
  alias Imgd.Workflows.{Workflow, WorkflowVersion, DagUtils}
  alias Imgd.Runtime.{WorkflowBuilder, ExecutionState}
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
  Starts an execution for the given workflow.

  By default the published version is used. You can override by providing
  `:workflow_version` or `:workflow_version_id` in attrs. The current user is
  stored on `triggered_by_user_id`.
  """
  def start_execution(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_workflow(scope, workflow),
         {:ok, version} <- resolve_version_for_execution(workflow, attrs) do
      params =
        attrs
        |> drop_protected_execution_keys()
        |> Map.put(:workflow_id, workflow.id)
        |> Map.put(:workflow_version_id, version.id)
        |> Map.put_new(:triggered_by_user_id, scope.user.id)

      %Execution{}
      |> Execution.changeset(params)
      |> Repo.insert()
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
    import Ecto.Query

    # Find and cancel any pending jobs for this execution
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
  - `:async` - Run asynchronously via Oban (default: `false` for interactive use)

  ## Returns

  - `{:ok, execution}` - Execution completed (check `execution.status`)
  - `{:error, :forbidden}` - User doesn't own workflow
  - `{:error, :node_not_found}` - Target node doesn't exist
  - `{:error, :no_executable_version}` - No published or draft version available
  - `{:error, reason}` - Other execution errors

  ## Example

      # Execute node "transform_1" and everything it depends on
      {:ok, execution} = Executions.execute_node(scope, workflow, "transform_1")

      # The execution.context will contain outputs for all executed nodes
      transform_output = execution.context["transform_1"]
  """
  def execute_node(%Scope{} = scope, %Workflow{} = workflow, node_id, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, _node} <- find_workflow_node(workflow, node_id),
         {:ok, version} <- resolve_execution_version(workflow) do
      pinned_outputs = Imgd.Workflows.extract_pinned_data(workflow)
      trigger_data = Keyword.get(opts, :trigger_data, %{})

      attrs = %{
        trigger: %{type: :manual, data: trigger_data},
        metadata: %{
          extras: %{
            "execution_mode" => "partial_to_node",
            "target_node" => node_id,
            "pinned_nodes" => Map.keys(pinned_outputs)
          }
        }
      }

      execute_partial(scope, workflow, version, [node_id], pinned_outputs, attrs, opts)
    end
  end

  @doc """
  Executes all downstream nodes from a pinned node.

  This is the "Execute from Here" / "Run Downstream" feature. The source
  node must have pinned output, which becomes the starting point for
  executing all nodes that depend on it.

  ## Options

  - `:async` - Run asynchronously via Oban (default: `false`)

  ## Returns

  Same as `execute_node/4`.

  ## Example

      # First, pin the HTTP request node's output
      {:ok, workflow} = Workflows.pin_node_output(scope, workflow, "http_request", response_data)

      # Then execute everything downstream
      {:ok, execution} = Executions.execute_downstream(scope, workflow, "http_request")
  """
  def execute_downstream(%Scope{} = scope, %Workflow{} = workflow, from_node_id, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, version} <- resolve_execution_version(workflow),
         :ok <- validate_node_pinned(workflow, from_node_id) do
      downstream_ids =
        DagUtils.downstream_closure(
          from_node_id,
          workflow.nodes,
          workflow.connections
        )

      if downstream_ids == [] do
        {:error, :no_downstream_nodes}
      else
        pinned_outputs = Imgd.Workflows.extract_pinned_data(workflow)

        # Use the pinned node's output as part of trigger data for logging
        source_data = Map.get(pinned_outputs, from_node_id, %{})

        attrs = %{
          trigger: %{type: :manual, data: source_data},
          metadata: %{
            extras: %{
              "execution_mode" => "partial_downstream",
              "from_node" => from_node_id,
              "downstream_nodes" => downstream_ids,
              "pinned_nodes" => Map.keys(pinned_outputs)
            }
          }
        }

        execute_partial(scope, workflow, version, downstream_ids, pinned_outputs, attrs, opts)
      end
    end
  end

  @doc """
  Executes a specific subset of nodes.

  Lower-level function for custom partial execution scenarios.
  Nodes are executed in topological order, with pinned outputs injected.

  ## Options

  - `:trigger_data` - Initial trigger data
  - `:async` - Run asynchronously
  - `:include_upstream` - Auto-include upstream dependencies (default: `true`)

  """
  def execute_subset(%Scope{} = scope, %Workflow{} = workflow, node_ids, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, version} <- resolve_execution_version(workflow),
         :ok <- validate_nodes_exist(workflow, node_ids) do
      pinned_outputs = Imgd.Workflows.extract_pinned_data(workflow)
      trigger_data = Keyword.get(opts, :trigger_data, %{})

      include_upstream = Keyword.get(opts, :include_upstream, true)

      # Optionally expand to include upstream
      target_ids =
        if include_upstream do
          node_ids
          |> Enum.flat_map(fn id ->
            [id | DagUtils.upstream_closure(id, workflow.nodes, workflow.connections)]
          end)
          |> Enum.uniq()
        else
          node_ids
        end

      attrs = %{
        trigger: %{type: :manual, data: trigger_data},
        metadata: %{
          extras: %{
            "execution_mode" => "partial_subset",
            "target_nodes" => target_ids,
            "pinned_nodes" => Map.keys(pinned_outputs)
          }
        }
      }

      execute_partial(scope, workflow, version, target_ids, pinned_outputs, attrs, opts)
    end
  end

  @doc """
  Re-executes a single node using provided input data.

  Useful for debugging a specific node with custom input.
  Does not execute any upstream nodes.

  ## Options

  - `:async` - Run asynchronously (default: `false`)

  """
  def execute_single_node(%Scope{} = scope, %Workflow{} = workflow, node_id, input_data, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         {:ok, _node} <- find_workflow_node(workflow, node_id),
         {:ok, version} <- resolve_execution_version(workflow) do
      attrs = %{
        trigger: %{type: :manual, data: input_data},
        metadata: %{
          extras: %{
            "execution_mode" => "single_node",
            "target_node" => node_id
          }
        }
      }

      with {:ok, execution} <- start_execution(scope, workflow, attrs) do
        if Keyword.get(opts, :async, false) do
          enqueue_single_node_execution(scope, execution, node_id, input_data, opts)
        else
          run_single_node_sync(execution, version, node_id, input_data)
        end
      end
    end
  end

  # ============================================================================
  # Private: Partial Execution Helpers
  # ============================================================================

defp execute_partial(scope, workflow, version, target_nodes, pinned_outputs, attrs, opts) do
  with {:ok, execution} <- start_execution(scope, workflow, attrs) do
    maybe_subscribe(execution, opts)

    if Keyword.get(opts, :async, true) do
      run_partial_async(execution, version, target_nodes, pinned_outputs)
      {:ok, execution}
    else
      run_partial_sync(execution, version, target_nodes, pinned_outputs)
    end
  end
end

  defp run_partial_sync(execution, version, target_nodes, pinned_outputs) do
    # Load execution with preloads
    execution =
      Repo.preload(execution, [:workflow, workflow_version: [:workflow]])

    context = Context.new(execution)

    case WorkflowBuilder.build_partial(version, context, execution,
           target_nodes: target_nodes,
           pinned_outputs: pinned_outputs) do
      {:ok, runic_workflow} ->
        # Use a modified runner that handles partial execution
        run_partial_workflow(execution, runic_workflow, context, pinned_outputs)

      {:error, reason} ->
        mark_execution_failed(execution, {:build_failed, reason})
    end
  end

  defp run_partial_workflow(execution, runic_workflow, context, pinned_outputs) do
    # Similar to WorkflowRunner.run but for partial execution
    alias Runic.Workflow
    alias Imgd.Runtime.ExecutionState

    try do
      # Initialize execution state
      ExecutionState.start(execution.id)

      # Pre-seed with pinned outputs
      for {node_id, output} <- pinned_outputs do
        ExecutionState.record_output(execution.id, node_id, output)
      end

      # Mark as running
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      {:ok, execution} = Repo.update(Execution.changeset(execution, %{status: :running, started_at: now}))
      Imgd.Executions.PubSub.broadcast_execution_started(execution)

      # Get trigger data for initial input
      trigger_data = Execution.trigger_data(execution)

      # Run the workflow
      executed_workflow = Workflow.react_until_satisfied(runic_workflow, trigger_data)

      # Gather results
      productions = Workflow.raw_productions(executed_workflow)
      node_outputs = ExecutionState.outputs(execution.id)
      final_context = %{context | node_outputs: Map.merge(context.node_outputs, node_outputs)}

      # Determine output
      output =
        case productions do
          [] -> %{"partial" => true, "nodes_executed" => Map.keys(node_outputs)}
          [single] -> %{"result" => single, "partial" => true}
          multiple -> %{"results" => multiple, "partial" => true}
        end

      # Mark completed
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      {:ok, execution} =
        Repo.update(
          Execution.changeset(execution, %{
            status: :completed,
            completed_at: now,
            output: sanitize_for_json(output),
            context: sanitize_for_json(final_context.node_outputs)
          })
        )

      Imgd.Executions.PubSub.broadcast_execution_completed(execution)
      ExecutionState.cleanup(execution.id)

      {:ok, execution}

    rescue
      e ->
        ExecutionState.cleanup(execution.id)
        mark_execution_failed(execution, {:execution_error, Exception.message(e)})
    end
  end

  defp run_single_node_sync(execution, version, node_id, input_data) do
    execution = Repo.preload(execution, [:workflow, workflow_version: [:workflow]])
    context = Context.new(execution)

    case WorkflowBuilder.build_single_node(version, context, execution, node_id, input_data) do
      {:ok, runic_workflow} ->
        run_partial_workflow(execution, runic_workflow, context, %{})

      {:error, reason} ->
        mark_execution_failed(execution, {:build_failed, reason})
    end
  end

  defp enqueue_partial_execution(_scope, execution, target_nodes, pinned_outputs, opts) do
    # For async partial execution, we'd need to store the partial params
    # This is a simplified version - full implementation would use Oban job args
    args = %{
      "execution_id" => execution.id,
      "mode" => "partial",
      "target_nodes" => target_nodes,
      "pinned_outputs" => pinned_outputs
    }

    job_opts = Keyword.take(opts, [:scheduled_at, :priority])

    case Imgd.Workers.ExecutionWorker.new(args, job_opts) |> Oban.insert() do
      {:ok, _job} -> {:ok, execution}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

defp maybe_subscribe(%Execution{id: execution_id}, opts) do
  case Keyword.get(opts, :subscribe_fun) do
    fun when is_function(fun, 1) -> fun.(execution_id)
    _ -> :ok
  end
end

defp run_partial_async(execution, version, target_nodes, pinned_outputs) do
  Task.start(fn ->
    try do
      _ = run_partial_sync(execution, version, target_nodes, pinned_outputs)
      :ok
    rescue
      e ->
        Logger.error("Partial execution crashed", error: inspect(e), execution_id: execution.id)
        :ok
    end
  end)
end

  defp enqueue_single_node_execution(_scope, execution, node_id, input_data, opts) do
    args = %{
      "execution_id" => execution.id,
      "mode" => "single_node",
      "target_node" => node_id,
      "input_data" => input_data
    }

    job_opts = Keyword.take(opts, [:scheduled_at, :priority])

    case Imgd.Workers.ExecutionWorker.new(args, job_opts) |> Oban.insert() do
      {:ok, _job} -> {:ok, execution}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  # ============================================================================
  # Private: Validation Helpers
  # ============================================================================

  defp find_workflow_node(%Workflow{nodes: nodes}, node_id) do
    case Enum.find(nodes || [], &(&1.id == node_id)) do
      nil -> {:error, :node_not_found}
      node -> {:ok, node}
    end
  end

  defp validate_node_pinned(workflow, node_id) do
    if Map.has_key?(workflow.pinned_outputs || %{}, node_id) do
      :ok
    else
      {:error, {:node_not_pinned, node_id}}
    end
  end

  defp validate_nodes_exist(workflow, node_ids) do
    existing_ids = MapSet.new(workflow.nodes || [], & &1.id)
    missing = Enum.reject(node_ids, &MapSet.member?(existing_ids, &1))

    if missing == [] do
      :ok
    else
      {:error, {:nodes_not_found, missing}}
    end
  end

  defp resolve_execution_version(%Workflow{} = workflow) do
    cond do
      # Prefer published version for production-like execution
      workflow.published_version_id ->
        case Repo.get(WorkflowVersion, workflow.published_version_id) do
          nil -> {:error, :version_not_found}
          v -> {:ok, v}
        end

      # Fall back to draft nodes for testing unpublished changes
      length(workflow.nodes || []) > 0 ->
        {:ok,
         %WorkflowVersion{
           id: Ecto.UUID.generate(),
           workflow_id: workflow.id,
           nodes: workflow.nodes,
           connections: workflow.connections,
           triggers: workflow.triggers,
           version_tag: "draft",
           source_hash: "draft"
         }}

      true ->
        {:error, :no_executable_version}
    end
  end

  defp mark_execution_failed(execution, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    error =
      case reason do
        {:build_failed, r} -> %{"type" => "build_failed", "reason" => inspect(r)}
        {:execution_error, msg} -> %{"type" => "execution_error", "message" => msg}
        other -> %{"type" => "unknown", "reason" => inspect(other)}
      end

    case Repo.update(
           Execution.changeset(execution, %{status: :failed, completed_at: now, error: error})
         ) do
      {:ok, execution} ->
        Imgd.Executions.PubSub.broadcast_execution_failed(execution, error)
        {:error, reason}

      {:error, _changeset} ->
        {:error, reason}
    end
  end

  defp sanitize_for_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(value) when is_list(value), do: Enum.map(value, &sanitize_for_json/1)
  defp sanitize_for_json(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: to_string(value)
  defp sanitize_for_json(value) when is_struct(value), do: value |> Map.from_struct() |> sanitize_for_json()
  defp sanitize_for_json(value), do: value

  # ============================================================================
  # Authorization Helpers
  # ============================================================================

  defp authorize_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    case workflow.user_id == scope_user_id!(scope) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  @doc false
  # Single-query authorization for executions.
  # Always performs a DB check to avoid issues with partially-loaded structs.
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

  @doc false
  # Single-query authorization for node executions.
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

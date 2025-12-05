defmodule Imgd.Workflows do
  @moduledoc """
  The Workflows context.

  Provides the public API for managing workflow definitions, executions,
  and execution steps.
  """
  # TODO: BREAK OUT INTO SEPARATE MODULES
  import Ecto.Query, warn: false
  alias Imgd.Repo

  alias Imgd.Accounts.Scope
  alias Imgd.Engine.DataFlow
  alias Imgd.Engine.DataFlow.{Envelope, ValidationError}
  alias Imgd.Workflows.{Workflow, WorkflowVersion, Execution, ExecutionPubSub, ExecutionStep}

  require Logger

  # ============================================================================
  # Workflows
  # ============================================================================

  @doc """
  Returns the list of workflows for the given scope.

  ## Options

    * `:status` - Filter by status (:draft, :published, :archived)
    * `:limit` - Limit number of results
    * `:preload` - List of associations to preload

  ## Examples

      iex> list_workflows(scope)
      [%Workflow{}, ...]

      iex> list_workflows(scope, status: :published)
      [%Workflow{}, ...]

  """
  def list_workflows(%Scope{} = scope, opts \\ []) do
    Workflow
    |> where(user_id: ^scope.user.id)
    |> maybe_filter_status(opts[:status])
    |> maybe_limit(opts[:limit])
    |> order_by(desc: :updated_at)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single workflow owned by the scoped user.

  Raises `Ecto.NoResultsError` if the Workflow does not exist or doesn't belong to the user.

  ## Examples

      iex> get_workflow!(scope, "some-uuid")
      %Workflow{}

      iex> get_workflow!(scope, "nonexistent")
      ** (Ecto.NoResultsError)

  """
  def get_workflow!(%Scope{} = scope, id) do
    Workflow
    |> where(id: ^id, user_id: ^scope.user.id)
    |> Repo.one!()
  end

  @doc """
  Gets a workflow by id, returning nil if not found or not owned by user.
  """
  def get_workflow(%Scope{} = scope, id) do
    Workflow
    |> where(id: ^id, user_id: ^scope.user.id)
    |> Repo.one()
  end

  @doc """
  Gets a workflow with preloaded associations.
  """
  def get_workflow_with_preloads!(%Scope{} = scope, id, preloads) do
    Workflow
    |> where(id: ^id, user_id: ^scope.user.id)
    |> preload(^preloads)
    |> Repo.one!()
  end

  @doc """
  Creates a workflow for the scoped user.

  ## Examples

      iex> create_workflow(scope, %{name: "My Workflow"})
      {:ok, %Workflow{}}

      iex> create_workflow(scope, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_workflow(%Scope{} = scope, attrs) do
    # Normalize all keys to strings for Ecto compatibility
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %Workflow{}
    |> Workflow.changeset(Map.put(attrs, "user_id", scope.user.id))
    |> Repo.insert()
  end

  @doc """
  Updates a workflow.

  ## Examples

      iex> update_workflow(scope, workflow, %{name: "New Name"})
      {:ok, %Workflow{}}

      iex> update_workflow(scope, workflow, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- authorize_workflow(scope, workflow) do
      workflow
      |> Workflow.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Publishes a workflow, creating a new version snapshot.

  ## Examples

      iex> publish_workflow(scope, workflow, %{definition: %{...}})
      {:ok, %Workflow{}}

  """
  def publish_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs \\ %{}) do
    with :ok <- authorize_workflow(scope, workflow) do
      Repo.transact(fn ->
        with {:ok, workflow} <- workflow |> Workflow.publish_changeset(attrs) |> Repo.update() do
          version_changeset = WorkflowVersion.from_workflow(workflow, published_by: scope.user.id)

          case Repo.insert(version_changeset) do
            {:ok, _version} -> {:ok, workflow}
            {:error, changeset} -> {:error, changeset}
          end
        end
      end)
    end
  end

  @doc """
  Archives a workflow.
  """
  def archive_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      workflow
      |> Workflow.archive_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Creates a duplicate of a workflow with a new name.

  The duplicated workflow will be a draft with "- Copy" appended to the name.
  """
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      attrs = %{
        name: "#{workflow.name} Copy",
        description: workflow.description,
        definition: workflow.definition,
        trigger_config: workflow.trigger_config,
        settings: workflow.settings,
        user_id: scope.user.id
      }

      %Workflow{}
      |> Workflow.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Deletes a workflow and all associated data.

  Only allowed for draft workflows with no executions.
  """
  def delete_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow),
         :ok <- validate_deletable(workflow) do
      Repo.delete(workflow)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking workflow changes.

  ## Examples

      iex> change_workflow(workflow)
      %Ecto.Changeset{data: %Workflow{}}

  """
  def change_workflow(%Workflow{} = workflow, attrs \\ %{}) do
    Workflow.changeset(workflow, attrs)
  end

  # ============================================================================
  # Workflow Versions
  # ============================================================================

  @doc """
  Lists all versions for a workflow.
  """
  def list_workflow_versions(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      WorkflowVersion
      |> WorkflowVersion.by_workflow(workflow.id)
      |> Repo.all()
    end
  end

  @doc """
  Gets a specific version of a workflow.
  """
  def get_workflow_version!(%Scope{} = scope, %Workflow{} = workflow, version_number) do
    with :ok <- authorize_workflow(scope, workflow) do
      WorkflowVersion
      |> WorkflowVersion.by_workflow(workflow.id)
      |> WorkflowVersion.at_version(version_number)
      |> Repo.one!()
    end
  end

  @doc """
  Gets the latest version of a workflow.
  """
  def get_latest_workflow_version(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      WorkflowVersion
      |> WorkflowVersion.by_workflow(workflow.id)
      |> WorkflowVersion.latest()
      |> Repo.one()
    end
  end

  # ============================================================================
  # Executions
  # ============================================================================

  @doc """
  Lists executions for a workflow.

  ## Options

    * `:status` - Filter by status or list of statuses
    * `:limit` - Limit number of results (default 100)
    * `:preload` - Associations to preload

  """
  def list_executions(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow) do
      limit = opts[:limit] || 100

      Execution
      |> Execution.by_workflow(workflow.id)
      |> maybe_filter_execution_status(opts[:status])
      |> Execution.recent(limit)
      |> maybe_preload(opts[:preload])
      |> Repo.all()
    end
  end

  @doc """
  Lists recent executions across all workflows for the scoped user.
  """
  def list_recent_executions(%Scope{} = scope, opts \\ []) do
    limit = opts[:limit] || 50

    Execution
    |> join(:inner, [e], w in Workflow, on: e.workflow_id == w.id)
    |> where([e, w], w.user_id == ^scope.user.id)
    |> maybe_filter_execution_status(opts[:status])
    |> Execution.recent(limit)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single execution.

  Raises if the execution doesn't exist or user doesn't have access.
  """
  def get_execution!(%Scope{} = scope, id) do
    execution =
      Execution
      |> Execution.with_workflow()
      |> Repo.get!(id)

    with :ok <- authorize_workflow(scope, execution.workflow) do
      execution
    else
      {:error, :unauthorized} -> raise Ecto.NoResultsError, queryable: Execution
    end
  end

  @doc """
  Gets an execution with preloaded associations.
  """
  def get_execution_with_preloads!(%Scope{} = scope, id, preloads) do
    execution =
      Execution
      |> preload(^[:workflow | preloads])
      |> Repo.get!(id)

    with :ok <- authorize_workflow(scope, execution.workflow) do
      execution
    else
      {:error, :unauthorized} -> raise Ecto.NoResultsError, queryable: Execution
    end
  end

  @doc """
  Starts a new workflow execution.

  ## Options

    * `:input` - Input data for the workflow
    * `:trigger_type` - How the execution was triggered (default :manual)
    * `:metadata` - Additional metadata to store

  """
  def start_execution(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    with :ok <- authorize_workflow(scope, workflow),
         :ok <- validate_executable(workflow),
         {:ok, envelope} <-
           DataFlow.prepare_input(opts[:input],
             schema: workflow_input_schema(workflow),
             metadata: %{workflow_id: workflow.id}
           ) do
      trace_id = envelope.metadata.trace_id

      attrs = %{
        workflow_id: workflow.id,
        workflow_version: workflow.version,
        triggered_by_user_id: scope.user.id,
        trigger_type: opts[:trigger_type] || :manual,
        input: Envelope.to_map(envelope),
        metadata: build_execution_metadata(opts[:metadata], trace_id)
      }

      Repo.transact(fn ->
        with {:ok, execution} <- %Execution{} |> Execution.changeset(attrs) |> Repo.insert(),
             {:ok, execution} <- execution |> Execution.start_changeset() |> Repo.update() do
          {:ok, execution}
        end
      end)
    else
      {:error, %ValidationError{} = error} ->
        {:error, {:invalid_input, error}}

      other ->
        other
    end
  end

  @doc """
  Marks an execution as completed with output.
  """
  def complete_execution(%Scope{} = scope, %Execution{} = execution, output) do
    with :ok <- authorize_execution(scope, execution) do
      execution
      |> Execution.complete_changeset(output)
      |> Repo.update()
    end
  end

  @doc """
  Marks an execution as failed with error details.
  """
  def fail_execution(%Scope{} = scope, %Execution{} = execution, error) do
    with :ok <- authorize_execution(scope, execution) do
      execution
      |> Execution.fail_changeset(error)
      |> Repo.update()
    end
  end

  @doc """
  Pauses a running execution.
  """
  def pause_execution(%Scope{} = scope, %Execution{} = execution) do
    with :ok <- authorize_execution(scope, execution),
         :ok <- validate_pausable(execution) do
      execution
      |> Execution.pause_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Resumes a paused or failed execution.
  """
  def resume_execution(%Scope{} = scope, %Execution{} = execution) do
    with :ok <- authorize_execution(scope, execution),
         :ok <- validate_resumable(execution) do
      execution
      |> Execution.resume_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Cancels an execution.
  """
  def cancel_execution(%Scope{} = scope, %Execution{} = execution) do
    with :ok <- authorize_execution(scope, execution),
         :ok <- validate_cancellable(execution) do
      execution
      |> Execution.cancel_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Updates the current generation of an execution.
  """
  def update_execution_generation(%Execution{} = execution, generation) do
    execution
    |> Execution.update_generation_changeset(generation)
    |> Repo.update()
  end

  @doc """
  Finds and marks expired executions as timed out.
  Returns the count of affected executions.
  """
  def timeout_expired_executions do
    {count, _} =
      Execution
      |> Execution.expired()
      |> Repo.update_all(
        set: [
          status: :timeout,
          completed_at: DateTime.utc_now(),
          error: %{type: "timeout", message: "Execution exceeded time limit"}
        ]
      )

    {:ok, count}
  end

  # ============================================================================
  # Execution Steps
  # ============================================================================

  @doc """
  Lists steps for an execution.

  ## Options

    * `:status` - Filter by status
    * `:generation` - Filter by generation
    * `:limit` - Limit results

  """
  def list_execution_steps(%Scope{} = scope, %Execution{} = execution, opts \\ []) do
    with :ok <- authorize_execution(scope, execution) do
      ExecutionStep
      |> ExecutionStep.by_execution(execution.id)
      |> maybe_filter_step_status(opts[:status])
      |> maybe_filter_generation(opts[:generation])
      |> maybe_limit(opts[:limit])
      |> Repo.all()
    end
  end

  @doc """
  Gets a single execution step.
  """
  def get_execution_step!(%Scope{} = scope, %Execution{} = execution, step_id) do
    with :ok <- authorize_execution(scope, execution) do
      ExecutionStep
      |> where(id: ^step_id, execution_id: ^execution.id)
      |> Repo.one!()
    end
  end

  @doc """
  Creates a step record from a runnable node and fact.
  """
  def create_execution_step(%Execution{} = execution, node, fact, opts \\ []) do
    ExecutionStep.from_runnable(execution.id, node, fact, opts)
    |> Repo.insert()
  end

  @doc """
  Marks a step as started.
  """
  def start_step(%ExecutionStep{} = step) do
    step
    |> ExecutionStep.start_changeset()
    |> Repo.update()
    |> case do
      {:ok, started_step} = result ->
        ExecutionPubSub.broadcast_step_started(started_step.execution_id, started_step)
        result

      error ->
        error
    end
  end

  @doc """
  Marks a step as completed with output.
  """
  def complete_step(%ExecutionStep{} = step, output_fact, duration_ms, opts \\ []) do
    step
    |> ExecutionStep.complete_changeset(output_fact, duration_ms, opts)
    |> Repo.update()
    |> case do
      {:ok, completed_step} = result ->
        ExecutionPubSub.broadcast_step_completed(completed_step.execution_id, completed_step)
        result

      error ->
        error
    end
  end

  @doc """
  Marks a step as failed with error details.
  """
  def fail_step(%ExecutionStep{} = step, error, duration_ms) do
    step
    |> ExecutionStep.fail_changeset(error, duration_ms)
    |> Repo.update()
    |> case do
      {:ok, failed_step} = result ->
        ExecutionPubSub.broadcast_step_failed(
          failed_step.execution_id,
          failed_step,
          failed_step.error
        )

        result

      error ->
        error
    end
  end

  @doc """
  Marks a step as skipped.
  """
  def skip_step(%ExecutionStep{} = step, reason \\ nil) do
    step
    |> ExecutionStep.skip_changeset(reason)
    |> Repo.update()
  end

  @doc """
  Schedules a step for retry.
  """
  def schedule_step_retry(%ExecutionStep{} = step, next_retry_at) do
    step
    |> ExecutionStep.retry_changeset(next_retry_at)
    |> Repo.update()
  end

  @doc """
  Appends logs to a step.
  """
  def append_step_logs(%ExecutionStep{} = step, logs) do
    step
    |> ExecutionStep.append_logs_changeset(logs)
    |> Repo.update()
  end

  @doc """
  Gets failed steps for an execution.
  """
  def get_failed_steps(%Execution{} = execution) do
    ExecutionStep
    |> ExecutionStep.by_execution(execution.id)
    |> ExecutionStep.failed()
    |> Repo.all()
  end

  @doc """
  Gets the slowest steps for an execution.
  """
  def get_slowest_steps(%Execution{} = execution, limit \\ 10) do
    ExecutionStep
    |> ExecutionStep.by_execution(execution.id)
    |> ExecutionStep.slowest(limit)
    |> Repo.all()
    |> Enum.sort_by(&(&1.duration_ms || 0), :desc)
  end

  # ============================================================================
  # Statistics & Queries
  # ============================================================================

  @doc """
  Gets execution statistics for a workflow.
  """
  def get_workflow_stats(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- authorize_workflow(scope, workflow) do
      stats =
        from(e in Execution,
          where: e.workflow_id == ^workflow.id,
          select: %{
            total: count(e.id),
            completed: count(fragment("CASE WHEN ? = 'completed' THEN 1 END", e.status)),
            failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", e.status)),
            running: count(fragment("CASE WHEN ? = 'running' THEN 1 END", e.status)),
            avg_duration_ms:
              avg(
                fragment(
                  "CASE WHEN ? IS NOT NULL THEN EXTRACT(EPOCH FROM (? - ?)) * 1000 END",
                  e.completed_at,
                  e.completed_at,
                  e.started_at
                )
              )
          }
        )
        |> Repo.one()

      {:ok, stats}
    end
  end

  @doc """
  Gets active execution count for the scoped user.
  """
  def count_active_executions(%Scope{} = scope) do
    Execution
    |> join(:inner, [e], w in Workflow, on: e.workflow_id == w.id)
    |> where([e, w], w.user_id == ^scope.user.id)
    |> Execution.active()
    |> Repo.aggregate(:count)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp authorize_workflow(%Scope{user: user}, %Workflow{user_id: user_id}) do
    if user.id == user_id, do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_execution(%Scope{} = scope, %Execution{} = execution) do
    execution = Repo.preload(execution, :workflow)
    authorize_workflow(scope, execution.workflow)
  end

  defp validate_deletable(%Workflow{status: :draft} = workflow) do
    case Repo.aggregate(Execution.by_workflow(workflow.id), :count) do
      0 -> :ok
      _ -> {:error, :has_executions}
    end
  end

  defp validate_deletable(_workflow), do: {:error, :not_draft}

  defp validate_executable(%Workflow{status: :published}), do: :ok
  defp validate_executable(_), do: {:error, :not_published}

  defp workflow_input_schema(%Workflow{settings: settings}) when is_map(settings) do
    settings[:input_schema] || settings["input_schema"]
  end

  defp workflow_input_schema(_), do: nil

  defp build_execution_metadata(nil, trace_id), do: %{"trace_id" => trace_id}

  defp build_execution_metadata(metadata, trace_id) when is_map(metadata) do
    Map.put(metadata, "trace_id", trace_id)
  end

  defp build_execution_metadata(_metadata, trace_id), do: %{"trace_id" => trace_id}

  defp validate_pausable(%Execution{status: :running}), do: :ok
  defp validate_pausable(_), do: {:error, :not_running}

  defp validate_resumable(%Execution{} = execution) do
    if Execution.resumable?(execution), do: :ok, else: {:error, :not_resumable}
  end

  defp validate_cancellable(%Execution{} = execution) do
    if Execution.terminal?(execution), do: {:error, :already_terminal}, else: :ok
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_execution_status(query, nil), do: query

  defp maybe_filter_execution_status(query, statuses) when is_list(statuses) do
    Execution.by_status(query, statuses)
  end

  defp maybe_filter_execution_status(query, status), do: Execution.by_status(query, status)

  defp maybe_filter_step_status(query, nil), do: query
  defp maybe_filter_step_status(query, status), do: ExecutionStep.by_status(query, status)

  defp maybe_filter_generation(query, nil), do: query
  defp maybe_filter_generation(query, gen), do: ExecutionStep.by_generation(query, gen)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end

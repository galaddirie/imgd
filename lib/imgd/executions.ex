defmodule Imgd.Executions do
  @moduledoc """
  Context for managing workflow executions and step executions.

  Provides functions to create, read, update, and manage executions,
  track execution status, and handle step-level execution details.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Imgd.Repo

  alias Imgd.Executions.{Execution, StepExecution}
  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.Scope
  alias Imgd.Runtime.Serializer

  @active_step_statuses [:pending, :queued, :running]

  @type execution_params :: %{
          required(:workflow_id) => Ecto.UUID.t(),
          required(:trigger) => map(),
          optional(:execution_type) => Execution.execution_type(),
          optional(:metadata) => map(),
          optional(:triggered_by_user_id) => Ecto.UUID.t()
        }

  @type step_execution_params :: %{
          required(:execution_id) => Ecto.UUID.t(),
          required(:step_id) => String.t(),
          required(:step_type_id) => String.t(),
          optional(:input_data) => map(),
          optional(:metadata) => map()
        }

  @doc """
  Lists executions accessible to the given scope.

  Returns executions for workflows the user can access.
  """
  @spec list_executions(Scope.t() | nil) :: [Execution.t()]
  def list_executions(nil), do: []

  def list_executions(%Scope{} = scope) do
    user = scope.user

    # Get executions for workflows the user can access
    query =
      from e in Execution,
        join: w in Workflow,
        on: e.workflow_id == w.id,
        left_join: s in Imgd.Workflows.WorkflowShare,
        on: s.workflow_id == w.id and s.user_id == ^user.id,
        where: w.user_id == ^user.id or not is_nil(s.id) or w.public == true,
        distinct: true,
        order_by: [desc: e.inserted_at],
        limit: 100

    Repo.all(query)
  end

  @doc """
  Lists executions for a specific workflow, checking access permissions.

  Returns executions if the user has access to the workflow, empty list otherwise.
  """
  @spec list_workflow_executions(Scope.t() | nil, Workflow.t(), keyword()) :: [Execution.t()]
  def list_workflow_executions(scope, %Workflow{} = workflow, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from e in Execution,
          where: e.workflow_id == ^workflow.id,
          order_by: [desc: e.inserted_at],
          limit: ^limit,
          offset: ^offset
      )
    else
      []
    end
  end

  @doc """
  Gets a single execution by ID, checking access permissions.

  Returns `{:ok, execution}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_execution(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution(scope, id) do
    case Repo.get(Execution, id) |> Repo.preload([:workflow, :triggered_by_user]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Gets an execution with its step executions preloaded.

  Returns `{:ok, execution}` with step executions loaded, or `{:error, :not_found}`.
  """
  @spec get_execution_with_steps(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution_with_steps(scope, id) do
    case Repo.get(Execution, id)
         |> Repo.preload([:workflow, :triggered_by_user, :step_executions]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a new execution for a workflow.

  Returns `{:ok, execution}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_execution(Scope.t() | nil, execution_params()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t()}
  def create_execution(scope, attrs) do
    # Check if user can view the workflow
    workflow_id = attrs[:workflow_id]
    execution_type = Map.get(attrs, :execution_type, :production)

    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :workflow_not_found}

      workflow ->
        can_create = Scope.can_create_execution?(scope, workflow, execution_type)

        cond do
          not can_create ->
            {:error, :access_denied}

          true ->
            # Get the published version for production executions
            published_version_id = workflow.published_version_id

            cond do
              not is_nil(published_version_id) ->
                attrs =
                  attrs
                  |> maybe_put_triggered_by_user(scope)

                %Execution{}
                |> Execution.changeset(attrs)
                |> Repo.insert()

              execution_type in [:preview, :partial] ->
                attrs = maybe_put_triggered_by_user(attrs, scope)

                %Execution{}
                |> Execution.changeset(attrs)
                |> Repo.insert()

              true ->
                {:error, :workflow_not_published}
            end
        end
    end
  end

  defp maybe_put_triggered_by_user(attrs, scope) do
    if scope && scope.user do
      Map.put(attrs, :triggered_by_user_id, scope.user.id)
    else
      attrs
    end
  end

  @doc """
  Updates an execution status.

  Returns `{:ok, execution}` if successful, `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec update_execution_status(Scope.t() | nil, Execution.t(), Execution.status(), keyword()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_execution_status(scope, %Execution{} = execution, status, opts \\ []) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      updates = %{status: status}

      # Add timestamps based on status
      updates =
        case status do
          :running ->
            Map.put(updates, :started_at, DateTime.utc_now())

          s when s in [:completed, :failed, :cancelled, :timeout] ->
            Map.put(updates, :completed_at, DateTime.utc_now())

          _ ->
            updates
        end

      # Add error information if provided
      updates =
        if error = Keyword.get(opts, :error) do
          Map.put(updates, :error, Execution.format_error(error))
        else
          updates
        end

      # Add output if provided
      updates =
        if output = Keyword.get(opts, :output) do
          Map.put(updates, :output, output)
        else
          updates
        end

      execution
      |> Execution.changeset(updates)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Cancels an execution.

  Returns `{:ok, execution}` if successful, `{:error, reason}` otherwise.
  """
  @spec cancel_execution(Scope.t() | nil, Execution.t()) ::
          {:ok, Execution.t()} | {:error, :not_found | :access_denied | :already_terminal}
  def cancel_execution(scope, %Execution{} = execution) do
    if Execution.terminal?(execution) do
      {:error, :already_terminal}
    else
      case update_execution_status(scope, execution, :cancelled) do
        {:ok, updated_execution} ->
          # Broadcast cancellation
          Imgd.Executions.PubSub.broadcast_execution_cancelled(updated_execution)

          # Emit execution cancelled event
          Imgd.Runtime.Events.emit(:execution_cancelled, updated_execution.id)

          # Cancel active steps
          cancel_active_step_executions(updated_execution.id)

          {:ok, updated_execution}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Cancels all active step executions for an execution.

  An active step is one with status :pending, :queued, or :running.
  All matched steps will be transitioned to :cancelled.
  """
  @spec cancel_active_step_executions(Ecto.UUID.t()) :: {integer(), nil | [term()]}
  def cancel_active_step_executions(execution_id) do
    now = DateTime.utc_now()

    query =
      from se in StepExecution,
        where: se.execution_id == ^execution_id and se.status in ^@active_step_statuses

    # We use update_all for efficiency, but we need to broadcast events.
    # In a high-scale system, we might just broadcast one "execution_cancelled" event
    # and let the UI handle it, but for granularity, we'll fetch and broadcast.
    active_steps = Repo.all(query)

    result =
      Repo.update_all(query,
        set: [
          status: :cancelled,
          completed_at: now,
          updated_at: now
        ]
      )

    Task.start(fn ->
      Enum.each(active_steps, fn step ->
        payload = %{
          execution_id: execution_id,
          step_id: step.step_id,
          status: :cancelled,
          completed_at: now,
          step_type_id: step.step_type_id
        }

        Imgd.Executions.PubSub.broadcast_step(:step_cancelled, execution_id, nil, payload)
        Imgd.Runtime.Events.emit(:step_cancelled, execution_id, payload)
      end)
    end)

    result
  end

  @doc """
  Lists step executions for an execution.

  Returns step executions ordered by insertion time.
  """
  @spec list_step_executions(Scope.t() | nil, Execution.t()) :: [StepExecution.t()]
  def list_step_executions(scope, %Execution{} = execution) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      Repo.all(
        from se in StepExecution,
          where: se.execution_id == ^execution.id,
          order_by: [asc: se.started_at, asc: se.inserted_at]
      )
    else
      []
    end
  end

  @doc """
  Gets a step execution by ID, checking access permissions.

  Returns `{:ok, step_execution}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_step_execution(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, StepExecution.t()} | {:error, :not_found}
  def get_step_execution(scope, id) do
    case Repo.get(StepExecution, id) |> Repo.preload(execution: :workflow) do
      nil ->
        {:error, :not_found}

      %StepExecution{execution: execution} = step_execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, step_execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a step execution.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_step_execution(Scope.t() | nil, step_execution_params()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def create_step_execution(scope, attrs) do
    execution_id = attrs[:execution_id]

    case Repo.get(Execution, execution_id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :execution_not_found}

      execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          %StepExecution{}
          |> StepExecution.changeset(attrs)
          |> Repo.insert()
        else
          {:error, :access_denied}
        end
    end
  end

  @doc """
  Updates a step execution status.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_step_execution_status(
          Scope.t() | nil,
          StepExecution.t(),
          StepExecution.status(),
          keyword()
        ) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def update_step_execution_status(scope, %StepExecution{} = step_execution, status, opts \\ []) do
    # Check access via the execution's workflow
    execution = Repo.get!(Execution, step_execution.execution_id) |> Repo.preload(:workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      updates = %{status: status}

      # Add timestamps based on status
      updates =
        case status do
          :running ->
            Map.put(updates, :started_at, DateTime.utc_now())

          :queued ->
            Map.put(updates, :queued_at, DateTime.utc_now())

          s when s in [:completed, :failed, :skipped] ->
            Map.put(updates, :completed_at, DateTime.utc_now())

          _ ->
            updates
        end

      # Add output data if provided
      updates =
        if output_data = Keyword.get(opts, :output_data) do
          Map.put(updates, :output_data, output_data)
        else
          updates
        end

      # Add error if provided
      updates =
        if error = Keyword.get(opts, :error) do
          Map.put(updates, :error, error)
        else
          updates
        end

      # Add output_item_count if provided
      updates =
        if count = Keyword.get(opts, :output_item_count) do
          Map.put(updates, :output_item_count, count)
        else
          updates
        end

      step_execution
      |> StepExecution.changeset(updates)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Creates a retry step execution.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec retry_step_execution(Scope.t() | nil, StepExecution.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def retry_step_execution(scope, %StepExecution{} = original) do
    # Check access via the execution's workflow
    execution = Repo.get!(Execution, original.execution_id) |> Repo.preload(:workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      %StepExecution{}
      |> StepExecution.changeset(%{
        execution_id: original.execution_id,
        step_id: original.step_id,
        step_type_id: original.step_type_id,
        input_data: original.input_data,
        metadata: original.metadata,
        attempt: original.attempt + 1,
        retry_of_id: original.id
      })
      |> Repo.insert()
    else
      {:error, :access_denied}
    end
  end

  @doc false
  @spec record_step_execution_started(Ecto.UUID.t(), String.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | term()}
  def record_step_execution_started(execution_id, step_id, step_type_id, input_data) do
    attrs = %{
      execution_id: execution_id,
      step_id: step_id,
      step_type_id: step_type_id,
      status: :running,
      input_data: Serializer.wrap_for_db(input_data),
      started_at: DateTime.utc_now()
    }

    safe_repo(fn ->
      %StepExecution{}
      |> StepExecution.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc false
  @spec record_step_execution_completed_by_id(Ecto.UUID.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_completed_by_id(step_execution_id, output_data, opts \\ []) do
    case Repo.get(StepExecution, step_execution_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :completed,
          output_data: Serializer.wrap_for_db(output_data),
          output_item_count: Keyword.get(opts, :output_item_count),
          completed_at: DateTime.utc_now()
        }

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        end)
    end
  end

  @doc false
  @spec record_step_execution_completed_by_step(Ecto.UUID.t(), String.t(), term(), keyword()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_completed_by_step(execution_id, step_id, output_data, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = Keyword.get(opts, :error)
    output_item_count = Keyword.get(opts, :output_item_count)

    updates = [
      status: :completed,
      output_data: Serializer.wrap_for_db(output_data),
      output_item_count: output_item_count,
      completed_at: now,
      updated_at: now
    ]

    updates = if error, do: Keyword.put(updates, :error, error), else: updates

    query =
      from(se in StepExecution,
        where:
          se.execution_id == ^execution_id and se.step_id == ^step_id and
            se.status in ^@active_step_statuses
      )

    safe_repo(fn ->
      case Repo.update_all(query, [set: updates], returning: true) do
        {0, _} ->
          {:error, :not_found}

        {1, [step]} ->
          {:ok, step}

        {n, steps} ->
          Logger.warning("Updated multiple step executions (#{n}) for completion",
            execution_id: execution_id,
            step_id: step_id
          )

          {:ok, List.last(steps)}
      end
    end)
  end

  @doc false
  @spec record_step_execution_failed_by_step(Ecto.UUID.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_failed_by_step(execution_id, step_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = Execution.format_error({:step_failed, step_id, reason})

    updates = [
      status: :failed,
      error: error,
      completed_at: now,
      updated_at: now
    ]

    query =
      from(se in StepExecution,
        where:
          se.execution_id == ^execution_id and se.step_id == ^step_id and
            se.status in ^@active_step_statuses
      )

    safe_repo(fn ->
      case Repo.update_all(query, [set: updates], returning: true) do
        {0, _} ->
          {:error, :not_found}

        {1, [step]} ->
          {:ok, step}

        {n, steps} ->
          Logger.warning("Updated multiple step executions (#{n}) for failure",
            execution_id: execution_id,
            step_id: step_id
          )

          {:ok, List.last(steps)}
      end
    end)
  end

  @doc false
  @spec record_step_execution_skipped_by_step(Ecto.UUID.t(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_skipped_by_step(execution_id, step_id) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :skipped,
          completed_at: DateTime.utc_now()
        }

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        end)
    end
  end

  @doc false
  @spec update_step_execution_metadata(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, StepExecution.t()} | {:error, term()}

  def update_step_execution_metadata(execution_id, step_id, metadata) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        new_metadata = Map.merge(step_execution.metadata || %{}, metadata)

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(%{metadata: new_metadata})
          |> Repo.update()
        end)
    end
  end

  @doc """
  Records multiple step executions in a single batch.
  Matches against existing active steps by step_id and execution_id if they exist,
  otherwise inserts new records.

  Note: insert_all does not run timestamps/changeset validations,
  so we handle UUID and timestamp generation manually.
  """
  @spec record_step_executions_batch([map()]) :: {:ok, integer()} | {:error, term()}
  def record_step_executions_batch(batches) when is_list(batches) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Process batches into raw maps for insert_all
    # We group by execution_id + step_id to merge started/completed events
    # If a step has both started and completed in the same execution (common for simple steps),
    # we merge them into a single completed record.
    rows =
      batches
      |> Enum.group_by(fn b -> {b.execution_id, b.step_id} end)
      |> Enum.map(fn {{exec_id, step_id}, entries} ->
        # Merge all entries for this specific step run
        merged =
          Enum.reduce(entries, %{}, fn entry, acc ->
            Map.merge(acc, entry)
          end)

        # Build raw DB row
        %{
          id: Ecto.UUID.generate(),
          execution_id: exec_id,
          step_id: step_id,
          step_type_id: merged[:step_type_id] || "unknown",
          status: merged[:status] || :completed,
          input_data: Serializer.wrap_for_db(merged[:input_data]),
          output_data: Serializer.wrap_for_db(merged[:output_data]),
          output_item_count: merged[:output_item_count],
          error: merged[:error],
          started_at: merged[:started_at] || now,
          completed_at: merged[:completed_at] || now,
          metadata: merged[:metadata] || %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      {:ok, 0}
    else
      safe_repo(fn ->
        {count, _} = Repo.insert_all(StepExecution, rows)
        {:ok, count}
      end)
    end
  end

  defp fetch_latest_active_step_execution(nil, _step_id), do: nil

  defp fetch_latest_active_step_execution(execution_id, step_id) do
    case Ecto.UUID.cast(execution_id) do
      {:ok, uuid} ->
        from(se in StepExecution,
          where:
            se.execution_id == ^uuid and se.step_id == ^step_id and
              se.status in ^@active_step_statuses,
          order_by: [desc: se.inserted_at],
          limit: 1
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp safe_repo(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      {:error, error}
  end

  @doc """
  Counts executions by status for the given scope.

  Returns a map with status counts.
  """
  @spec count_executions_by_status(Scope.t() | nil) :: %{optional(atom()) => non_neg_integer()}
  def count_executions_by_status(scope) do
    user = scope && scope.user

    # Base query for accessible executions
    base_query =
      if user do
        from e in Execution,
          join: w in Workflow,
          on: e.workflow_id == w.id,
          left_join: s in Imgd.Workflows.WorkflowShare,
          on: s.workflow_id == w.id and s.user_id == ^user.id,
          where: w.user_id == ^user.id or not is_nil(s.id) or w.public == true
      else
        from e in Execution,
          join: w in Workflow,
          on: e.workflow_id == w.id,
          where: w.public == true
      end

    query =
      from [e, w, s] in base_query,
        select: {e.status, count(e.id)},
        group_by: e.status

    Repo.all(query) |> Map.new()
  end

  @doc """
  Gets execution statistics for the last N days.

  Returns a list of daily execution counts.
  """
  @spec get_execution_stats(Scope.t() | nil, pos_integer()) :: [
          %{date: Date.t(), count: non_neg_integer()}
        ]
  def get_execution_stats(scope, days \\ 30) do
    user = scope && scope.user
    start_date = Date.add(Date.utc_today(), -days)

    # Base query for accessible executions
    base_query =
      if user do
        from e in Execution,
          join: w in Workflow,
          on: e.workflow_id == w.id,
          left_join: s in Imgd.Workflows.WorkflowShare,
          on: s.workflow_id == w.id and s.user_id == ^user.id,
          where: w.user_id == ^user.id or not is_nil(s.id) or w.public == true,
          where: fragment("date(?) >= ?", e.inserted_at, ^start_date)
      else
        from e in Execution,
          join: w in Workflow,
          on: e.workflow_id == w.id,
          where: w.public == true,
          where: fragment("date(?) >= ?", e.inserted_at, ^start_date)
      end

    query =
      from [e, w, s] in base_query,
        select: %{
          date: fragment("date(?)", e.inserted_at),
          count: count(e.id)
        },
        group_by: fragment("date(?)", e.inserted_at),
        order_by: fragment("date(?)", e.inserted_at)

    Repo.all(query)
  end
end

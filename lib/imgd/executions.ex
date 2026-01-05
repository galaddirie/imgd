defmodule Imgd.Executions do
  @moduledoc """
  Context for managing workflow executions and step executions.

  Provides functions to create, read, update, and manage executions,
  track execution status, and handle step-level execution details.
  """

  import Ecto.Query, warn: false
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
        can_view = Scope.can_view_workflow?(scope, workflow)
        can_edit = Scope.can_edit_workflow?(scope, workflow)

        cond do
          execution_type in [:preview, :partial] and not can_edit ->
            {:error, :access_denied}

          not can_view ->
            {:error, :access_denied}

          true ->
            # Get the published version for production executions
            published_version_id = workflow.published_version_id

            cond do
              not is_nil(published_version_id) ->
                attrs =
                  attrs
                  |> maybe_put_triggered_by_user(scope)
                  |> Map.put(:workflow_version_id, published_version_id)

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
  Stores a Runic snapshot for an execution.

  Returns `{:ok, execution}` if successful, `{:error, :access_denied}` otherwise.
  """
  @spec put_execution_snapshot(Scope.t() | nil, Execution.t(), binary()) ::
          {:ok, Execution.t()} | {:error, :access_denied}
  def put_execution_snapshot(scope, %Execution{} = execution, snapshot)
      when is_binary(snapshot) do
    execution = Repo.preload(execution, :workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      execution
      |> Execution.changeset(%{runic_snapshot: snapshot})
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
      update_execution_status(scope, execution, :cancelled)
    end
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
          order_by: [asc: se.inserted_at]
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
  def record_step_execution_completed_by_id(step_execution_id, output_data) do
    case Repo.get(StepExecution, step_execution_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :completed,
          output_data: Serializer.wrap_for_db(output_data),
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
  @spec record_step_execution_completed_by_step(Ecto.UUID.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_completed_by_step(execution_id, step_id, output_data) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :completed,
          output_data: Serializer.wrap_for_db(output_data),
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
  @spec record_step_execution_failed_by_step(Ecto.UUID.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_failed_by_step(execution_id, step_id, reason) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        error = Execution.format_error({:step_failed, step_id, reason})

        updates = %{
          status: :failed,
          error: error,
          completed_at: DateTime.utc_now()
        }

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        end)
    end
  end

  defp fetch_latest_active_step_execution(execution_id, step_id) do
    from(se in StepExecution,
      where:
        se.execution_id == ^execution_id and se.step_id == ^step_id and
          se.status in ^@active_step_statuses,
      order_by: [desc: se.inserted_at],
      limit: 1
    )
    |> Repo.one()
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

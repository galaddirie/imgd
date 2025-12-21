defmodule Imgd.Executions do
  @moduledoc """
  Context for managing workflow executions and node executions.

  Provides functions to create, read, update, and manage executions,
  track execution status, and handle node-level execution details.
  """

  import Ecto.Query, warn: false
  alias Imgd.Repo

  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.Scope

  @type execution_params :: %{
          required(:workflow_id) => Ecto.UUID.t(),
          required(:trigger) => map(),
          optional(:execution_type) => Execution.execution_type(),
          optional(:metadata) => map(),
          optional(:triggered_by_user_id) => Ecto.UUID.t()
        }

  @type node_execution_params :: %{
          required(:execution_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:node_type_id) => String.t(),
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
  @spec list_workflow_executions(Workflow.t(), Scope.t() | nil, keyword()) :: [Execution.t()]
  def list_workflow_executions(%Workflow{} = workflow, scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
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
  @spec get_execution(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution(id, scope) do
    case Repo.get(Execution, id) |> Repo.preload([:workflow, :triggered_by_user]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
          {:ok, execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Gets an execution with its node executions preloaded.

  Returns `{:ok, execution}` with node executions loaded, or `{:error, :not_found}`.
  """
  @spec get_execution_with_nodes(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution_with_nodes(id, scope) do
    case Repo.get(Execution, id)
         |> Repo.preload([:workflow, :triggered_by_user, :node_executions]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
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
  @spec create_execution(execution_params(), Scope.t() | nil) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t()}
  def create_execution(attrs, scope) do
    # Check if user can view the workflow
    workflow_id = attrs[:workflow_id]

    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :workflow_not_found}

      workflow ->
        if Imgd.Workflows.Sharing.can_view?(workflow, scope) do
          # Get the published version for execution
          published_version_id = workflow.published_version_id

          if is_nil(published_version_id) do
            {:error, :workflow_not_published}
          else
            # Add triggered_by_user_id if scope has user
            attrs =
              if scope && scope.user do
                Map.put(attrs, :triggered_by_user_id, scope.user.id)
              else
                attrs
              end

            # Add workflow_version_id
            attrs = Map.put(attrs, :workflow_version_id, published_version_id)

            %Execution{}
            |> Execution.changeset(attrs)
            |> Repo.insert()
          end
        else
          {:error, :access_denied}
        end
    end
  end

  @doc """
  Updates an execution status.

  Returns `{:ok, execution}` if successful, `{:error, changeset | :not_found | :access_denied}` otherwise.
  """
  @spec update_execution_status(Execution.t(), Execution.status(), Scope.t() | nil, keyword()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_execution_status(%Execution{} = execution, status, scope, opts \\ []) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
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
  @spec cancel_execution(Execution.t(), Scope.t() | nil) ::
          {:ok, Execution.t()} | {:error, :not_found | :access_denied | :already_terminal}
  def cancel_execution(%Execution{} = execution, scope) do
    if Execution.terminal?(execution) do
      {:error, :already_terminal}
    else
      update_execution_status(execution, :cancelled, scope)
    end
  end

  @doc """
  Lists node executions for an execution.

  Returns node executions ordered by insertion time.
  """
  @spec list_node_executions(Execution.t(), Scope.t() | nil) :: [NodeExecution.t()]
  def list_node_executions(%Execution{} = execution, scope) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
      Repo.all(
        from ne in NodeExecution,
          where: ne.execution_id == ^execution.id,
          order_by: [asc: ne.inserted_at]
      )
    else
      []
    end
  end

  @doc """
  Gets a node execution by ID, checking access permissions.

  Returns `{:ok, node_execution}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_node_execution(String.t() | Ecto.UUID.t(), Scope.t() | nil) ::
          {:ok, NodeExecution.t()} | {:error, :not_found}
  def get_node_execution(id, scope) do
    case Repo.get(NodeExecution, id) |> Repo.preload(execution: :workflow) do
      nil ->
        {:error, :not_found}

      %NodeExecution{execution: execution} = node_execution ->
        if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
          {:ok, node_execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a node execution.

  Returns `{:ok, node_execution}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_node_execution(node_execution_params(), Scope.t() | nil) ::
          {:ok, NodeExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def create_node_execution(attrs, scope) do
    execution_id = attrs[:execution_id]

    case Repo.get(Execution, execution_id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :execution_not_found}

      execution ->
        if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
          %NodeExecution{}
          |> NodeExecution.changeset(attrs)
          |> Repo.insert()
        else
          {:error, :access_denied}
        end
    end
  end

  @doc """
  Updates a node execution status.

  Returns `{:ok, node_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_node_execution_status(
          NodeExecution.t(),
          NodeExecution.status(),
          Scope.t() | nil,
          keyword()
        ) ::
          {:ok, NodeExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def update_node_execution_status(%NodeExecution{} = node_execution, status, scope, opts \\ []) do
    # Check access via the execution's workflow
    execution = Repo.get!(Execution, node_execution.execution_id) |> Repo.preload(:workflow)

    if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
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

      node_execution
      |> NodeExecution.changeset(updates)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Creates a retry node execution.

  Returns `{:ok, node_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec retry_node_execution(NodeExecution.t(), Scope.t() | nil) ::
          {:ok, NodeExecution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def retry_node_execution(%NodeExecution{} = original, scope) do
    # Check access via the execution's workflow
    execution = Repo.get!(Execution, original.execution_id) |> Repo.preload(:workflow)

    if Imgd.Workflows.Sharing.can_view?(execution.workflow, scope) do
      %NodeExecution{}
      |> NodeExecution.changeset(%{
        execution_id: original.execution_id,
        node_id: original.node_id,
        node_type_id: original.node_type_id,
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

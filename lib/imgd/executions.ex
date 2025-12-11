defmodule Imgd.Executions do
  @moduledoc """
  Context for workflow executions and node executions.

  All functions require an `Imgd.Accounts.Scope` with a user, ensuring callers
  only interact with their own workflows and executions.
  """

  import Ecto.Query, warn: false

  alias Imgd.Accounts.Scope
  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Repo

  @type scope :: %Scope{}

  @doc """
  Lists executions visible to the scope's user.

  Options:
    * `:workflow` - limit to a specific workflow struct
    * `:workflow_id` - limit to a workflow id
    * `:status` - status atom or list of statuses
    * `:limit` - max rows
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
    |> maybe_order_executions(opts)
    |> maybe_limit(opts)
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
        |> drop_forbidden_execution_keys()
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

    with :ok <- ensure_execution_in_scope(scope, execution) do
      execution
      |> Execution.changeset(drop_forbidden_execution_keys(attrs))
      |> Repo.update()
    end
  end

  @doc """
  Lists node executions for a given execution.
  """
  def list_node_executions(%Scope{} = scope, %Execution{} = execution, opts \\ []) do
    with :ok <- ensure_execution_in_scope(scope, execution) do
      NodeExecution
      |> where([n], n.execution_id == ^execution.id)
      |> order_by([n], asc: n.inserted_at)
      |> maybe_preload(opts)
      |> maybe_limit(opts)
      |> Repo.all()
    end
  end

  @doc """
  Creates a node execution for the given execution.
  """
  def create_node_execution(%Scope{} = scope, %Execution{} = execution, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with :ok <- ensure_execution_in_scope(scope, execution) do
      attrs =
        attrs
        |> drop_forbidden_node_keys()
        |> Map.put(:execution_id, execution.id)

      %NodeExecution{}
      |> NodeExecution.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a node execution after confirming ownership.
  """
  def update_node_execution(%Scope{} = scope, %NodeExecution{} = node_execution, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- ensure_node_execution_in_scope(scope, node_execution) do
      node_execution
      |> NodeExecution.changeset(drop_forbidden_node_keys(attrs))
      |> Repo.update()
    end
  end

  @doc """
  Returns a changeset for node executions.
  """
  def change_node_execution(%NodeExecution{} = node_execution, attrs \\ %{}) do
    NodeExecution.changeset(node_execution, attrs)
  end

  # Helpers

  defp scope_user_id!(%Scope{user: %{id: user_id}}) when not is_nil(user_id), do: user_id
  defp scope_user_id!(_), do: raise(ArgumentError, "current_scope with user is required")

  defp authorize_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    case workflow.user_id == scope_user_id!(scope) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp ensure_execution_in_scope(%Scope{} = scope, %Execution{} = execution) do
    user_id = scope_user_id!(scope)

    cond do
      match?(%Workflow{user_id: ^user_id}, execution.workflow) ->
        :ok

      not is_nil(execution.workflow_id) and
          Repo.exists?(
            from w in Workflow, where: w.id == ^execution.workflow_id and w.user_id == ^user_id
          ) ->
        :ok

      not is_nil(execution.id) and
          Repo.exists?(
            from e in Execution,
              join: w in assoc(e, :workflow),
              where: e.id == ^execution.id and w.user_id == ^user_id
          ) ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp ensure_node_execution_in_scope(%Scope{} = scope, %NodeExecution{} = node_execution) do
    user_id = scope_user_id!(scope)

    case Repo.exists?(
           from n in NodeExecution,
             join: e in assoc(n, :execution),
             join: w in assoc(e, :workflow),
             where: n.id == ^node_execution.id and w.user_id == ^user_id
         ) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  defp resolve_version_for_execution(%Workflow{} = workflow, attrs) do
    provided_version = Map.get(attrs, :workflow_version) || Map.get(attrs, "workflow_version")

    cond do
      match?(%WorkflowVersion{}, provided_version) ->
        validate_version_belongs(workflow, provided_version)

      Map.has_key?(attrs, :workflow_version_id) ->
        load_version(workflow, Map.get(attrs, :workflow_version_id))

      Map.has_key?(attrs, "workflow_version_id") ->
        load_version(workflow, Map.get(attrs, "workflow_version_id"))

      match?(%WorkflowVersion{}, workflow.published_version) ->
        validate_version_belongs(workflow, workflow.published_version)

      not is_nil(workflow.published_version_id) ->
        load_version(workflow, workflow.published_version_id)

      true ->
        {:error, :not_published}
    end
  end

  defp load_version(%Workflow{} = workflow, version_id) when is_binary(version_id) do
    version = Repo.get(WorkflowVersion, version_id)
    validate_version_belongs(workflow, version)
  end

  defp load_version(%Workflow{}, _), do: {:error, :not_published}

  defp validate_version_belongs(
         %Workflow{id: workflow_id},
         %WorkflowVersion{workflow_id: workflow_id} = version
       ) do
    {:ok, version}
  end

  defp validate_version_belongs(_workflow, %WorkflowVersion{}), do: {:error, :version_mismatch}
  defp validate_version_belongs(_workflow, _nil_version), do: {:error, :not_published}

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
      nil ->
        query

      statuses when is_list(statuses) ->
        where(query, [e], e.status in ^statuses)

      status ->
        where(query, [e], e.status == ^status)
    end
  end

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

  defp maybe_preload(query, opts) do
    case Keyword.get(opts, :preload, []) do
      [] -> query
      preloads -> preload(query, ^preloads)
    end
  end

  defp drop_forbidden_execution_keys(attrs) when is_map(attrs) do
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

  defp drop_forbidden_execution_keys(attrs), do: attrs

  defp drop_forbidden_node_keys(attrs) when is_map(attrs) do
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

  defp drop_forbidden_node_keys(attrs), do: attrs

  defp normalize_attrs(nil), do: %{}
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(attrs), do: attrs
end

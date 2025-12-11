defmodule Imgd.Executions do
  @moduledoc """
  Context entrypoint for workflow executions and their node steps.

  Provides scoped helpers for creating, listing, and fetching executions so callers
  don't have to reach directly for schemas.
  """

  import Ecto.Query, warn: false

  alias Imgd.Accounts.Scope
  alias Imgd.Executions.{Execution, NodeExecution}
  alias Imgd.Repo
  alias Imgd.Workflows.Workflow
  alias Imgd.Workflows.WorkflowVersion

  @type scope :: Scope.t()

  @doc """
  Returns executions for a workflow, ordered by newest first.

  Results are scoped to the workflow passed in and decorated with virtual fields
  such as `:trigger_type`, `:workflow_version_tag`, and `:input` for UI use.
  """
  @spec list_executions(scope(), Workflow.t(), keyword()) :: [Execution.t()]
  def list_executions(%Scope{} = _scope, %Workflow{} = workflow, opts \\ []) do
    Execution
    |> where([e], e.workflow_id == ^workflow.id)
    |> order_by([e], desc: e.inserted_at)
    |> limit_opt(opts)
    |> Repo.all()
    |> Repo.preload(:workflow_version)
    |> Enum.map(&decorate_execution/1)
  end

  @doc """
  Fetches an execution by ID scoped to the current user.
  """
  @spec get_execution!(scope(), Ecto.UUID.t()) :: Execution.t()
  def get_execution!(%Scope{} = scope, id) do
    scope
    |> execution_query()
    |> Repo.get!(id)
    |> Repo.preload([:workflow, :workflow_version])
    |> decorate_execution()
  end

  @doc """
  Creates a new execution for the given workflow.

  Stores the provided input in execution metadata and defaults the trigger to manual
  when none is supplied.
  """
  @spec create_execution(scope(), Workflow.t(), map()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t()}
  def create_execution(%Scope{} = scope, %Workflow{} = workflow, attrs) when is_map(attrs) do
    params = build_execution_attrs(scope, workflow, attrs)

    %Execution{}
    |> Execution.changeset(params)
    |> Repo.insert()
    |> case do
      {:ok, execution} -> {:ok, decorate_execution(execution)}
      other -> other
    end
  end

  @doc """
  Lists node execution steps for an execution ordered by insertion.

  The returned maps expose the shape expected by LiveViews (input/output snapshots,
  duration, attempt, etc.).
  """
  @spec list_execution_steps(scope(), Execution.t()) :: [map()]
  def list_execution_steps(%Scope{} = _scope, %Execution{} = execution) do
    NodeExecution
    |> where([ne], ne.execution_id == ^execution.id)
    |> order_by([ne], asc: ne.inserted_at)
    |> Repo.all()
    |> Enum.map(&format_step/1)
  end

  defp execution_query(%Scope{user: nil}), do: Execution

  defp execution_query(%Scope{user: user}) do
    from e in Execution,
      join: w in assoc(e, :workflow),
      where: w.user_id == ^user.id,
      preload: [workflow: w]
  end

  defp build_execution_attrs(scope, workflow, attrs) do
    trigger = Map.get(attrs, :trigger) || Map.get(attrs, "trigger") || %{type: :manual, data: %{}}
    input = Map.get(attrs, :input) || Map.get(attrs, "input")

    metadata =
      (Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{})
      |> normalize_metadata()
      |> maybe_put_input(input)
      |> maybe_put_triggered_by(scope)

    %{
      workflow_id: workflow.id,
      workflow_version_id:
        Map.get(attrs, :workflow_version_id) ||
          Map.get(attrs, "workflow_version_id") ||
          workflow.published_version_id ||
          workflow.id,
      status: Map.get(attrs, :status) || Map.get(attrs, "status") || :pending,
      trigger: trigger,
      metadata: metadata,
      context: Map.get(attrs, :context) || Map.get(attrs, "context") || %{},
      started_at:
        Map.get(attrs, :started_at) || Map.get(attrs, "started_at") || DateTime.utc_now(),
      triggered_by_user_id: maybe_user_id(scope)
    }
  end

  defp limit_opt(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      limit when is_integer(limit) and limit > 0 -> query |> limit(^limit)
      _ -> query
    end
  end

  defp format_step(%NodeExecution{} = step) do
    %{
      id: step.id,
      node_id: step.node_id,
      node_type_id: step.node_type_id,
      status: step.status,
      input_data: step.input_data,
      output_data: step.output_data,
      error: step.error,
      attempt: step.attempt,
      duration_ms: duration_ms(step.started_at, step.finished_at),
      started_at: step.started_at,
      finished_at: step.finished_at,
      logs: nil
    }
  end

  defp duration_ms(nil, _), do: nil
  defp duration_ms(_, nil), do: nil
  defp duration_ms(started, finished), do: DateTime.diff(finished, started, :millisecond)

  defp decorate_execution(%Execution{} = execution) do
    trigger = normalize_trigger(execution.trigger)
    metadata = execution_metadata(execution.metadata)

    %{
      execution
      | trigger: trigger,
        trigger_type: trigger_type_value(trigger),
        input: Map.get(metadata, :input),
        output: Map.get(metadata, :output),
        workflow_version_tag: workflow_version_tag(execution)
    }
  end

  defp workflow_version_tag(%Execution{workflow_version: %WorkflowVersion{version_tag: tag}}),
    do: tag

  defp workflow_version_tag(%Execution{workflow_version_id: id}) when is_binary(id), do: id
  defp workflow_version_tag(_), do: nil

  defp normalize_trigger(%{type: type} = trigger) do
    %{
      type: cast_trigger_type(type),
      data: Map.get(trigger, :data) || Map.get(trigger, "data") || %{}
    }
  end

  defp normalize_trigger(%{"type" => type} = trigger) do
    %{type: cast_trigger_type(type), data: Map.get(trigger, "data") || %{}}
  end

  defp normalize_trigger(_), do: %{type: :manual, data: %{}}

  defp trigger_type_value(trigger) do
    case trigger[:type] do
      nil -> "manual"
      type -> to_string(type)
    end
  end

  defp cast_trigger_type(type) when type in [:manual, :schedule, :webhook, :event], do: type
  defp cast_trigger_type("manual"), do: :manual
  defp cast_trigger_type("schedule"), do: :schedule
  defp cast_trigger_type("webhook"), do: :webhook
  defp cast_trigger_type("event"), do: :event
  defp cast_trigger_type(type) when is_atom(type), do: type
  defp cast_trigger_type(_), do: :manual

  defp maybe_user_id(%Scope{user: nil}), do: nil
  defp maybe_user_id(%Scope{user: user}), do: user.id

  defp normalize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case normalize_metadata_key(key) do
        :tags -> Map.put(acc, :tags, value || %{})
        :extras -> Map.put(acc, :extras, value || %{})
        nil -> Map.update(acc, :extras, %{}, &Map.put(&1, key, value))
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
    |> Map.put_new(:tags, %{})
    |> Map.put_new(:extras, %{})
  end

  defp normalize_metadata(_), do: %{tags: %{}, extras: %{}}

  defp normalize_metadata_key(key) when is_atom(key), do: key

  defp normalize_metadata_key(key) when is_binary(key) do
    case key do
      "trace_id" -> :trace_id
      "correlation_id" -> :correlation_id
      "triggered_by" -> :triggered_by
      "parent_execution_id" -> :parent_execution_id
      "input" -> :input
      "output" -> :output
      "tags" -> :tags
      "extras" -> :extras
      _ -> nil
    end
  end

  defp normalize_metadata_key(_), do: nil

  defp maybe_put_input(metadata, nil), do: metadata
  defp maybe_put_input(metadata, input), do: Map.put(metadata, :input, input)

  defp maybe_put_triggered_by(metadata, %Scope{user: nil}), do: metadata

  defp maybe_put_triggered_by(metadata, %Scope{user: user}),
    do: Map.put_new(metadata, :triggered_by, user.id)

  defp execution_metadata(nil), do: %{tags: %{}, extras: %{}}

  defp execution_metadata(%Execution.Metadata{} = metadata) do
    metadata
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Map.delete(:__struct__)
    |> normalize_metadata()
  end

  defp execution_metadata(metadata) when is_map(metadata), do: normalize_metadata(metadata)
end

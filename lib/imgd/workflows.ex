defmodule Imgd.Workflows do
  @moduledoc """
  Workflows context module.

  Handles workflow CRUD, publishing, and execution orchestration.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Imgd.Accounts.Scope
  alias Imgd.Executions
  alias Imgd.Executions.Execution
  alias Imgd.Repo
  alias Imgd.Workflows.ExecutionPubSub
  alias Imgd.Workflows.{Workflow, WorkflowVersion}

  @type scope :: Scope.t()

  # ---------------------------------------------------------------------------
  # Workflow CRUD
  # ---------------------------------------------------------------------------

  @spec list_workflows(scope()) :: [Workflow.t()]
  def list_workflows(%Scope{} = scope) do
    scope
    |> workflow_query()
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
    |> Repo.preload(:published_version)
    |> Enum.map(&decorate_workflow/1)
  end

  @spec get_workflow!(scope(), Ecto.UUID.t()) :: Workflow.t()
  def get_workflow!(%Scope{} = scope, id) do
    scope
    |> workflow_query()
    |> Repo.get!(id)
    |> Repo.preload(:published_version)
    |> decorate_workflow()
  end

  @spec get_workflow(scope(), Ecto.UUID.t()) :: Workflow.t() | nil
  def get_workflow(%Scope{} = scope, id) do
    scope
    |> workflow_query()
    |> Repo.get(id)
    |> case do
      nil -> nil
      workflow -> workflow |> Repo.preload(:published_version) |> decorate_workflow()
    end
  end

  @spec change_workflow(Workflow.t(), map()) :: Ecto.Changeset.t()
  def change_workflow(%Workflow{} = workflow, attrs \\ %{}) do
    Workflow.changeset(workflow, attrs)
  end

  @spec create_workflow(scope(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(%Scope{user: user}, attrs) when is_map(attrs) do
    %Workflow{}
    |> Workflow.changeset(Map.put(attrs, :user_id, user && user.id))
    |> Repo.insert()
    |> maybe_decorate()
  end

  @spec update_workflow(scope(), Workflow.t(), map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    with :ok <- ensure_owner(scope, workflow) do
      workflow
      |> Workflow.changeset(attrs)
      |> Repo.update()
      |> maybe_decorate()
    end
  end

  @spec duplicate_workflow(scope(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    with :ok <- ensure_owner(scope, workflow) do
      attrs = %{
        name: "#{workflow.name} (Copy)",
        description: workflow.description,
        status: :draft,
        nodes: workflow.nodes,
        connections: workflow.connections,
        triggers: workflow.triggers,
        settings: workflow.settings,
        current_version_tag: workflow.current_version_tag,
        user_id: workflow.user_id
      }

      %Workflow{}
      |> Workflow.changeset(attrs)
      |> Repo.insert()
      |> maybe_decorate()
    end
  end

  @spec archive_workflow(scope(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def archive_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    update_workflow(scope, workflow, %{status: :archived})
  end

  # ---------------------------------------------------------------------------
  # Publishing
  # ---------------------------------------------------------------------------

  @spec publish_workflow(scope(), Workflow.t(), map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def publish_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) when is_map(attrs) do
    version_tag =
      Map.get(attrs, :version_tag) ||
        Map.get(attrs, "version_tag") ||
        workflow.current_version_tag ||
        "1.0.0"

    changelog =
      Map.get(attrs, :changelog) ||
        Map.get(attrs, "changelog") ||
        "Published version #{version_tag}"

    definition = Map.get(attrs, :definition) || Map.get(attrs, "definition")

    publish_workflow(workflow, version_tag, maybe_user_id(scope), changelog, definition)
  end

  @spec publish_workflow(
          Workflow.t(),
          String.t(),
          Ecto.UUID.t() | nil,
          String.t() | nil,
          map() | nil
        ) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def publish_workflow(
        %Workflow{} = workflow,
        version_tag,
        published_by_user_id,
        changelog \\ nil,
        definition \\ nil
      ) do
    source_hash = hash_workflow(workflow)
    settings = maybe_put_definition(workflow.settings, definition)

    Multi.new()
    |> Multi.insert(
      :version,
      WorkflowVersion.changeset(%WorkflowVersion{}, %{
        workflow_id: workflow.id,
        version_tag: version_tag,
        source_hash: source_hash,
        nodes: workflow.nodes,
        connections: workflow.connections,
        triggers: workflow.triggers,
        published_at: DateTime.utc_now(),
        published_by: published_by_user_id,
        changelog: changelog
      })
    )
    |> Multi.update(:workflow, fn %{version: version} ->
      Workflow.changeset(workflow, %{
        status: :active,
        current_version_tag: version_tag,
        published_version_id: version.id,
        settings: settings
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{workflow: workflow}} -> {:ok, decorate_workflow(workflow)}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Gets the currently published version for a workflow.
  """
  def get_published_version(%Workflow{} = workflow) do
    workflow
    |> Repo.preload(:published_version)
    |> Map.get(:published_version)
  end

  @doc """
  Lists all versions for a workflow, ordered by creation date.
  """
  def list_workflow_versions(workflow_id) do
    WorkflowVersion
    |> where([v], v.workflow_id == ^workflow_id)
    |> order_by([v], desc: v.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a specific workflow version by ID.
  """
  def get_workflow_version(version_id) do
    Repo.get(WorkflowVersion, version_id)
  end

  # ---------------------------------------------------------------------------
  # Execution helpers (delegate to Executions context)
  # ---------------------------------------------------------------------------

  @spec list_executions(scope(), Workflow.t(), keyword()) :: [Execution.t()]
  def list_executions(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    Executions.list_executions(scope, workflow, opts)
  end

  @spec get_execution!(scope(), Ecto.UUID.t()) :: Execution.t()
  def get_execution!(%Scope{} = scope, id), do: Executions.get_execution!(scope, id)

  @spec list_execution_steps(scope(), Execution.t()) :: [map()]
  def list_execution_steps(%Scope{} = scope, %Execution{} = execution) do
    Executions.list_execution_steps(scope, execution)
  end

  @spec start_execution(scope(), Workflow.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, term()}
  def start_execution(%Scope{} = scope, %Workflow{} = workflow, opts \\ []) do
    with :ok <- ensure_owner(scope, workflow),
         :ok <- ensure_workflow_active(workflow),
         {:ok, execution} <-
           Executions.create_execution(scope, workflow, %{
             input: Keyword.get(opts, :input),
             trigger: %{type: :manual, data: %{}},
             status: :running,
             metadata: %{
               "input" => Keyword.get(opts, :input),
               "triggered_by" => maybe_user_id(scope)
             },
             started_at: DateTime.utc_now()
           }) do
      ExecutionPubSub.broadcast_execution_started(execution)
      {:ok, execution}
    else
      {:error, :not_published} -> {:error, :not_published}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  @doc """
  Parses a semantic version string and returns major/minor/patch components.
  """
  def parse_semver(version_tag) do
    case Version.parse(version_tag) do
      {:ok, %Version{major: major, minor: minor, patch: patch}} ->
        {:ok, %{major: major, minor: minor, patch: patch}}

      :error ->
        {:error, :invalid_semver}
    end
  end

  @doc """
  Generates a content hash for a workflow based on its structure.
  """
  def hash_workflow(%Workflow{} = workflow) do
    structure = %{
      nodes: Enum.sort_by(workflow.nodes, & &1.id),
      connections: Enum.sort_by(workflow.connections, & &1.id),
      triggers: Enum.sort_by(workflow.triggers, & &1.type)
    }

    structure
    |> :erlang.term_to_binary()
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp workflow_query(%Scope{user: nil}), do: Workflow

  defp workflow_query(%Scope{user: user}) do
    from w in Workflow, where: w.user_id == ^user.id
  end

  defp ensure_owner(%Scope{user: nil}, _workflow), do: {:error, :unauthorized}

  defp ensure_owner(%Scope{user: user}, %Workflow{user_id: user_id}) when user.id == user_id,
    do: :ok

  defp ensure_owner(_scope, _workflow), do: {:error, :unauthorized}

  defp ensure_workflow_active(%Workflow{status: :active}), do: :ok
  defp ensure_workflow_active(_), do: {:error, :not_published}

  defp decorate_workflow(%Workflow{} = workflow) do
    trigger_config =
      case workflow.triggers do
        [first | _] -> first
        _ -> %{type: :manual, config: %{}}
      end

    version = workflow.current_version_tag || workflow.version || "draft"

    %{workflow | trigger_config: trigger_config, version: version}
  end

  defp maybe_decorate({:ok, workflow}), do: {:ok, decorate_workflow(workflow)}
  defp maybe_decorate(other), do: other

  defp maybe_user_id(%Scope{user: nil}), do: nil
  defp maybe_user_id(%Scope{user: user}), do: user.id

  defp maybe_put_definition(settings, nil), do: settings

  defp maybe_put_definition(settings, definition) when is_map(settings) do
    Map.put(settings, :definition, definition)
  end
end

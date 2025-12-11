defmodule Imgd.Workflows do
  @moduledoc """
  Workflows context module.

  Handles business logic for workflow management, publishing, and versioning.
  """

  import Ecto.Query
  alias Imgd.Repo
  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Ecto.Multi

  @doc """
  Publishes a workflow, creating an immutable version snapshot.

  This creates a new WorkflowVersion with semantic versioning and updates
  the workflow to point to the newly published version.
  """
  def publish_workflow(%Workflow{} = workflow, version_tag, published_by_user_id) do
    source_hash = hash_workflow(workflow)

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
        changelog: "Published version #{version_tag}"
      })
    )
    |> Multi.update(:workflow, fn %{version: version} ->
      Workflow.changeset(workflow, %{
        status: :active,
        current_version_tag: version_tag,
        published_version_id: version.id
      })
    end)
    |> Repo.transaction()
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
    # Create a normalized representation of the workflow structure
    structure = %{
      nodes: Enum.sort_by(workflow.nodes, & &1.id),
      connections: Enum.sort_by(workflow.connections, & &1.id),
      triggers: Enum.sort_by(workflow.triggers, & &1.type)
    }

    # Serialize and hash
    structure
    |> :erlang.term_to_binary()
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)
  end
end

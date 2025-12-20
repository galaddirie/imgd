defmodule Imgd.Workflows.Snapshots do
  @moduledoc """
  Manages workflow snapshots for preview/dev executions.
  """
  import Ecto.Query, warn: false
  alias Imgd.Repo
  alias Imgd.Accounts.Scope
  alias Imgd.Workflows.{Workflow, WorkflowSnapshot}

  @snapshot_ttl_days 7

  @doc """
  Gets existing snapshot or creates new one for the workflow's current state.

  Deduplicates by source_hash - if a snapshot with the same hash exists
  and hasn't expired, reuse it.
  """
  def get_or_create(%Scope{} = scope, %Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %Imgd.Workflows.WorkflowDraft{}

    source_hash =
      WorkflowSnapshot.compute_source_hash(
        draft.nodes || [],
        draft.connections || [],
        draft.triggers || []
      )

    get_or_create_with_hash(scope, workflow, source_hash)
  end

  def get_or_create_with_hash(%Scope{} = scope, %Workflow{} = workflow, source_hash) do
    case find_existing(workflow.id, source_hash) do
      nil -> create(scope, workflow, source_hash)
      snapshot -> {:ok, snapshot}
    end
  end

  defp find_existing(workflow_id, source_hash) do
    WorkflowSnapshot
    |> where([s], s.workflow_id == ^workflow_id)
    |> where([s], s.source_hash == ^source_hash)
    |> where([s], is_nil(s.expires_at) or s.expires_at > ^DateTime.utc_now())
    |> limit(1)
    |> Repo.one()
  end

  defp create(%Scope{} = scope, %Workflow{} = workflow, source_hash) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %Imgd.Workflows.WorkflowDraft{}

    %WorkflowSnapshot{}
    |> WorkflowSnapshot.changeset(%{
      workflow_id: workflow.id,
      created_by_user_id: scope.user.id,
      source_hash: source_hash,
      nodes: Enum.map(draft.nodes || [], &Map.from_struct/1),
      connections: Enum.map(draft.connections || [], &Map.from_struct/1),
      triggers: Enum.map(draft.triggers || [], &Map.from_struct/1),
      purpose: :preview,
      expires_at: DateTime.add(DateTime.utc_now(), @snapshot_ttl_days, :day)
    })
    |> Repo.insert()
  end

  @doc """
  Cleanup expired snapshots.
  Called by periodic job.
  """
  def cleanup_expired do
    WorkflowSnapshot
    |> where([s], not is_nil(s.expires_at))
    |> where([s], s.expires_at < ^DateTime.utc_now())
    |> Repo.delete_all()
  end
end

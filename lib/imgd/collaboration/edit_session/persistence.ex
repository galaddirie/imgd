defmodule Imgd.Collaboration.EditSession.Persistence do
  @moduledoc """
  Handles persistence of edit session state to database.

  Persistence strategy:

  - Operations are buffered in memory
  - Batch-persisted every N seconds or N operations
  - Draft is updated atomically with operation batch
  - Snapshots are taken periodically for faster recovery
  """

  alias Imgd.Repo
  alias Imgd.Workflows
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Collaboration.EditOperation

  import Ecto.Query

  @doc "Load pending operations since last snapshot."
  @spec load_pending_ops(String.t()) :: {:ok, integer(), [EditOperation.t()]} | {:error, term()}
  def load_pending_ops(workflow_id) do
    # Get the last persisted sequence number from the draft
    case Workflows.get_draft(workflow_id) do
      {:ok, draft} ->
        last_seq = draft.settings["last_persisted_seq"] || 0

        ops =
          EditOperation
          |> where([o], o.workflow_id == ^workflow_id and o.seq > ^last_seq)
          |> order_by([o], asc: o.seq)
          |> Repo.all()

        {:ok, last_seq, ops}

      error ->
        error
    end
  end

  @doc "Persist buffered operations and update draft."
  @spec persist(map()) :: :ok | {:error, term()}
  def persist(%{workflow_id: _workflow_id, draft: draft, op_buffer: ops, seq: seq}) do
    try do
      Repo.transaction(fn ->
        # 1. Batch insert any new operations
        new_ops =
          Enum.filter(ops, fn op ->
            not operation_persisted?(op)
          end)

        if new_ops != [] do
          entries = Enum.map(new_ops, &operation_to_entry/1)
          Repo.insert_all(EditOperation, entries, on_conflict: :nothing)
        end

        # 2. Update the draft with current state
        draft
        |> WorkflowDraft.changeset(%{
          steps: draft.steps && Enum.map(draft.steps, &Map.from_struct/1),
          connections: draft.connections && Enum.map(draft.connections, &Map.from_struct/1),
          settings: Map.put(draft.settings || %{}, "last_persisted_seq", seq)
        })
        |> Repo.update!()
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      Ecto.StaleEntryError -> :ok
      Ecto.InvalidChangesetError -> :ok
    end
  end

  @doc "Take a snapshot of current state for faster recovery."
  @spec snapshot(String.t(), WorkflowDraft.t(), integer()) :: :ok | {:error, term()}
  def snapshot(workflow_id, draft, seq) do
    # Could store compressed binary snapshot for very large workflows
    # For now, the draft itself serves as the snapshot
    persist(%{
      workflow_id: workflow_id,
      draft: draft,
      # Clear buffer since we're taking snapshot
      op_buffer: [],
      seq: seq
    })
  end

  defp operation_persisted?(op) do
    EditOperation
    |> where([o], o.operation_id == ^op.operation_id)
    |> Repo.exists?()
  end

  defp operation_to_entry(op) do
    %{
      operation_id: op.operation_id,
      seq: op.seq,
      type: op.type,
      payload: op.payload,
      user_id: op.user_id,
      client_seq: op.client_seq,
      workflow_id: op.workflow_id,
      inserted_at: DateTime.utc_now()
    }
  end
end

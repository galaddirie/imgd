defmodule Imgd.Collaboration.EditSession.Persistence do
  @moduledoc """
  Handles persistence of edit session state to database.

  Persistence strategy:

  - Operations are buffered in memory
  - Batch-persisted every N seconds or N operations
  - Draft is updated atomically with operation batch
  - Snapshots are taken periodically for faster recovery
  """

  require Logger

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
        # 1. Batch insert any new operations.
        # DB constraints + on_conflict: :nothing handles duplicates efficiently.
        if ops != [] do
          entries = Enum.map(ops, &operation_to_entry/1)
          Repo.insert_all(EditOperation, entries, on_conflict: :nothing)
        end

        # 2. Update (or create) the draft with current state.
        # Use a fresh DB copy so Ecto can detect changes even when the in-memory
        # draft already reflects the latest edits.
        draft_attrs = %{
          steps: Enum.map(draft.steps || [], &ensure_map/1),
          connections: Enum.map(draft.connections || [], &ensure_map/1),
          settings: Map.put(draft.settings || %{}, "last_persisted_seq", seq)
        }

        case Repo.get_by(WorkflowDraft, workflow_id: draft.workflow_id) do
          nil ->
            %WorkflowDraft{workflow_id: draft.workflow_id}
            |> WorkflowDraft.changeset(Map.put(draft_attrs, :workflow_id, draft.workflow_id))
            |> Repo.insert!()

          db_draft ->
            db_draft
            |> WorkflowDraft.changeset(draft_attrs)
            |> Repo.update!()
        end
      end)
      |> case do
        {:ok, _} ->
          Logger.info("Persistence.persist: Successfully persisted ops and draft.")
          :ok

        {:error, reason} ->
          Logger.error("Persistence.persist: Transaction failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error(
          "Persistence.persist: CRASHED: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        reraise e, __STACKTRACE__
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

  defp ensure_map(%_{} = struct), do: Map.from_struct(struct)
  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(nil), do: nil
end

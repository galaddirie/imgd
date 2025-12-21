defmodule Imgd.Collaboration.EditSession.Server do
  @moduledoc """
  GenServer managing a single collaborative editing session for a workflow.

  Responsibilities:
  - Maintain canonical workflow draft state
  - Process and linearize operations from all clients
  - Broadcast changes to all participants
  - Manage editor state (pins, disabled nodes, locks)
  - Persist operations and snapshots
  """
  use GenServer, restart: :transient

  require Logger

  alias Imgd.Collaboration.{EditorState, EditOperation}
  alias Imgd.Collaboration.EditSession.{Operations, Persistence, Presence}
  alias Imgd.Workflows

  @idle_timeout :timer.minutes(30)
  @persist_interval :timer.seconds(5)
  @max_op_buffer 1000

  defmodule State do
    @moduledoc false
    defstruct [
      :workflow_id,
      :draft,              # Current WorkflowDraft
      :editor_state,       # EditorState struct
      :seq,                # Current sequence number
      :op_buffer,          # Recent operations for sync
      :applied_ops,        # Set of applied operation IDs (dedup)
      :dirty,              # Has unpersisted changes
      :persist_timer,      # Timer ref for periodic persistence
      :idle_timer          # Timer ref for idle shutdown
    ]
  end

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    GenServer.start_link(__MODULE__, workflow_id, name: via_tuple(workflow_id))
  end

  def via_tuple(workflow_id) do
    {:via, Registry, {Imgd.Collaboration.EditSession.Registry, workflow_id}}
  end

  @doc "Apply an operation to the workflow."
  def apply_operation(workflow_id, operation) do
    GenServer.call(via_tuple(workflow_id), {:apply_operation, operation})
  end

  @doc "Get current state for a joining/reconnecting client."
  def get_sync_state(workflow_id, client_seq \\ nil) do
    GenServer.call(via_tuple(workflow_id), {:get_sync_state, client_seq})
  end

  @doc "Acquire a soft lock on a node for editing."
  def acquire_node_lock(workflow_id, node_id, user_id) do
    GenServer.call(via_tuple(workflow_id), {:acquire_lock, node_id, user_id})
  end

  @doc "Release a node lock."
  def release_node_lock(workflow_id, node_id, user_id) do
    GenServer.cast(via_tuple(workflow_id), {:release_lock, node_id, user_id})
  end

  @doc "Get current editor state (pins, disabled, locks)."
  def get_editor_state(workflow_id) do
    GenServer.call(via_tuple(workflow_id), :get_editor_state)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(workflow_id) do
    Logger.metadata(workflow_id: workflow_id, component: :edit_session)
    Logger.info("Starting edit session")

    case load_initial_state(workflow_id) do
      {:ok, state} ->
        # Schedule periodic persistence
        persist_timer = Process.send_after(self(), :persist, @persist_interval)
        idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)

        state = %{state | persist_timer: persist_timer, idle_timer: idle_timer}
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:apply_operation, operation}, _from, state) do
    case process_operation(state, operation) do
      {:ok, new_state, result} ->
        # Reset idle timer
        new_state = reset_idle_timer(new_state)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_sync_state, client_seq}, _from, state) do
    response = build_sync_response(state, client_seq)
    {:reply, {:ok, response}, state}
  end

  def handle_call({:acquire_lock, node_id, user_id}, _from, state) do
    case EditorState.acquire_lock(state.editor_state, node_id, user_id) do
      {:ok, new_editor_state} ->
        new_state = %{state | editor_state: new_editor_state}
        broadcast_lock_acquired(state.workflow_id, node_id, user_id)
        {:reply, :ok, new_state}

      {:locked, other_user_id} ->
        {:reply, {:error, {:locked_by, other_user_id}}, state}
    end
  end

  def handle_call(:get_editor_state, _from, state) do
    {:reply, {:ok, state.editor_state}, state}
  end

  @impl true
  def handle_cast({:release_lock, node_id, user_id}, state) do
    new_editor_state = EditorState.release_lock(state.editor_state, node_id, user_id)
    new_state = %{state | editor_state: new_editor_state}
    broadcast_lock_released(state.workflow_id, node_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:persist, state) do
    new_state =
      if state.dirty do
        case Persistence.persist(state) do
          :ok ->
            Logger.debug("Persisted edit session state")
            %{state | dirty: false}
          {:error, reason} ->
            Logger.error("Failed to persist: #{inspect(reason)}")
            state
        end
      else
        state
      end

    # Reschedule
    persist_timer = Process.send_after(self(), :persist, @persist_interval)
    {:noreply, %{new_state | persist_timer: persist_timer}}
  end

  def handle_info(:idle_timeout, state) do
    if Presence.count(state.workflow_id) == 0 do
      Logger.info("Edit session idle with no users, shutting down")
      # Persist before shutdown
      Persistence.persist(state)
      {:stop, :normal, state}
    else
      # Users present, reset timer
      idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
      {:noreply, %{state | idle_timer: idle_timer}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Edit session terminating", reason: inspect(reason))
    Persistence.persist(state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_initial_state(workflow_id) do
    with {:ok, draft} <- Workflows.get_draft(workflow_id),
         {:ok, last_seq, ops} <- Persistence.load_pending_ops(workflow_id) do

      # Replay any pending operations
      {draft, seq} = replay_operations(draft, ops, last_seq)

      state = %State{
        workflow_id: workflow_id,
        draft: draft,
        editor_state: %EditorState{workflow_id: workflow_id},
        seq: seq,
        op_buffer: ops,
        applied_ops: MapSet.new(Enum.map(ops, & &1.operation_id)),
        dirty: false
      }

      {:ok, state}
    end
  end

  defp replay_operations(draft, ops, initial_seq) do
    Enum.reduce(ops, {draft, initial_seq}, fn op, {d, seq} ->
      case Operations.apply(d, op) do
        {:ok, new_draft} -> {new_draft, max(seq, op.seq)}
        {:error, _} -> {d, seq}
      end
    end)
  end

  defp process_operation(state, operation) do
    # 1. Check for duplicate
    if MapSet.member?(state.applied_ops, operation.id) do
      # Already applied - return success with existing seq
      existing_op = Enum.find(state.op_buffer, &(&1.operation_id == operation.id))
      {:ok, state, %{seq: existing_op.seq, status: :duplicate}}
    else
      # 2. Validate operation
      with :ok <- Operations.validate(state.draft, operation) do
        # 3. Assign sequence number
        new_seq = state.seq + 1

        # 4. Apply to draft (or editor state for editor-only ops)
        {new_draft, new_editor_state} =
          apply_to_state(state.draft, state.editor_state, operation)

        # 5. Build persisted operation record
        op_record = %EditOperation{
          operation_id: operation.id,
          seq: new_seq,
          type: operation.type,
          payload: operation.payload,
          user_id: operation.user_id,
          client_seq: operation.client_seq,
          workflow_id: state.workflow_id
        }

        # 6. Update state
        new_state = %{state |
          draft: new_draft,
          editor_state: new_editor_state,
          seq: new_seq,
          op_buffer: append_to_buffer(state.op_buffer, op_record),
          applied_ops: MapSet.put(state.applied_ops, operation.id),
          dirty: true
        }

        # 7. Broadcast to all clients
        broadcast_operation(state.workflow_id, op_record)

        {:ok, new_state, %{seq: new_seq, status: :applied}}
      end
    end
  end

  defp apply_to_state(draft, editor_state, operation) do
    case operation.type do
      # Workflow structure operations - modify draft
      type when type in [:add_node, :remove_node, :update_node_config,
                         :update_node_position, :update_node_metadata,
                         :add_connection, :remove_connection] ->
        {:ok, new_draft} = Operations.apply(draft, operation)

        # Clean up editor state if node was removed
        new_editor_state =
          if type == :remove_node do
            node_id = operation.payload.node_id
            editor_state
            |> EditorState.unpin_output(node_id)
            |> EditorState.enable_node(node_id)
          else
            editor_state
          end

        {new_draft, new_editor_state}

      # Editor-only operations - modify editor state only
      :pin_node_output ->
        new_editor_state = EditorState.pin_output(
          editor_state,
          operation.payload.node_id,
          operation.payload.output_data
        )
        {draft, new_editor_state}

      :unpin_node_output ->
        new_editor_state = EditorState.unpin_output(
          editor_state,
          operation.payload.node_id
        )
        {draft, new_editor_state}

      :disable_node ->
        new_editor_state = EditorState.disable_node(
          editor_state,
          operation.payload.node_id,
          operation.payload[:mode] || :skip
        )
        {draft, new_editor_state}

      :enable_node ->
        new_editor_state = EditorState.enable_node(
          editor_state,
          operation.payload.node_id
        )
        {draft, new_editor_state}
    end
  end

  defp append_to_buffer(buffer, op) do
    [op | buffer]
    |> Enum.take(@max_op_buffer)
  end

  defp build_sync_response(state, nil) do
    # Full state for new join
    %{
      type: :full_sync,
      draft: state.draft,
      editor_state: serialize_editor_state(state.editor_state),
      seq: state.seq
    }
  end

  defp build_sync_response(state, client_seq) do
    gap = state.seq - client_seq

    cond do
      gap == 0 ->
        %{type: :up_to_date, seq: state.seq}

      gap > 0 and gap <= length(state.op_buffer) ->
        # Can send incremental ops
        ops =
          state.op_buffer
          |> Enum.filter(&(&1.seq > client_seq))
          |> Enum.sort_by(& &1.seq)

        %{type: :incremental, ops: ops, seq: state.seq}

      true ->
        # Too far behind - full sync
        %{
          type: :full_sync,
          draft: state.draft,
          editor_state: serialize_editor_state(state.editor_state),
          seq: state.seq
        }
    end
  end

  defp serialize_editor_state(editor_state) do
    %{
      pinned_outputs: editor_state.pinned_outputs,
      disabled_nodes: MapSet.to_list(editor_state.disabled_nodes),
      disabled_mode: editor_state.disabled_mode,
      node_locks: editor_state.node_locks
    }
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
    %{state | idle_timer: idle_timer}
  end

  defp broadcast_operation(workflow_id, operation) do
    Phoenix.PubSub.broadcast(
      Imgd.PubSub,
      "edit_session:#{workflow_id}",
      {:operation_applied, operation}
    )
  end

  defp broadcast_lock_acquired(workflow_id, node_id, user_id) do
    Phoenix.PubSub.broadcast(
      Imgd.PubSub,
      "edit_session:#{workflow_id}",
      {:lock_acquired, node_id, user_id}
    )
  end

  defp broadcast_lock_released(workflow_id, node_id) do
    Phoenix.PubSub.broadcast(
      Imgd.PubSub,
      "edit_session:#{workflow_id}",
      {:lock_released, node_id}
    )
  end
end

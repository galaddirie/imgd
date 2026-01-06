defmodule Imgd.Collaboration.EditSession.Server do
  @moduledoc """
  GenServer managing a single collaborative editing session for a workflow.

  Responsibilities:
  - Maintain canonical workflow draft state
  - Process and linearize operations from all clients
  - Broadcast changes to all participants
  - Manage editor state (pins, disabled steps, locks)
  - Persist operations and snapshots
  """
  use GenServer, restart: :transient

  require Logger

  alias Imgd.Collaboration.{EditorState, EditOperation}
  alias Imgd.Collaboration.EditSession.{Operations, Persistence, Presence, PubSub}
  alias Imgd.Workflows

  @idle_timeout :timer.minutes(30)
  @persist_interval :timer.seconds(5)
  @max_op_buffer 1000

  defmodule State do
    @moduledoc false
    defstruct [
      :workflow_id,
      :draft,
      :editor_state,
      :seq,
      :op_buffer,
      :applied_ops,
      :dirty,
      :persist_timer,
      :idle_timer
    ]
  end

  # =============================================================================
  # Client API
  # =============================================================================

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

  @doc "Acquire a soft lock on a step for editing."
  def acquire_step_lock(workflow_id, step_id, user_id) do
    GenServer.call(via_tuple(workflow_id), {:acquire_lock, step_id, user_id})
  end

  @doc "Release a step lock."
  def release_step_lock(workflow_id, step_id, user_id) do
    GenServer.cast(via_tuple(workflow_id), {:release_lock, step_id, user_id})
  end

  @doc "Get current editor state (pins, disabled, locks)."
  def get_editor_state(workflow_id) do
    GenServer.call(via_tuple(workflow_id), :get_editor_state)
  end

  @doc "Force a persistence of current state."
  def persist(workflow_id) do
    GenServer.cast(via_tuple(workflow_id), :persist)
  end

  @doc "Force a persistence of current state and wait for completion."
  def persist_sync(workflow_id) do
    GenServer.call(via_tuple(workflow_id), :persist_sync)
  end

  # =============================================================================
  # Server Callbacks
  # =============================================================================

  @impl true
  def init(workflow_id) do
    Logger.metadata(workflow_id: workflow_id, component: :edit_session)
    Logger.info("Starting edit session for workflow #{workflow_id}")

    case load_initial_state(workflow_id) do
      {:ok, state} ->
        persist_timer = Process.send_after(self(), :persist, @persist_interval)
        idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)

        state = %{state | persist_timer: persist_timer, idle_timer: idle_timer}
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to load initial state: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:apply_operation, operation}, _from, state) do
    case process_operation(state, operation) do
      {:ok, new_state, result} ->
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

  def handle_call({:acquire_lock, step_id, user_id}, _from, state) do
    case EditorState.acquire_lock(state.editor_state, step_id, user_id) do
      {:ok, new_editor_state} ->
        new_state = %{state | editor_state: new_editor_state}
        PubSub.broadcast_lock_acquired(state.workflow_id, step_id, user_id)
        {:reply, :ok, new_state}

      {:locked, other_user_id} ->
        {:reply, {:error, {:locked_by, other_user_id}}, state}
    end
  end

  def handle_call(:get_editor_state, _from, state) do
    {:reply, {:ok, state.editor_state}, state}
  end

  def handle_call(:persist_sync, _from, state) do
    {result, new_state} = persist_state(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_cast({:release_lock, step_id, user_id}, state) do
    new_editor_state = EditorState.release_lock(state.editor_state, step_id, user_id)
    new_state = %{state | editor_state: new_editor_state}
    PubSub.broadcast_lock_released(state.workflow_id, step_id)
    {:noreply, new_state}
  end

  def handle_cast(:persist, state) do
    {_result, new_state} = persist_state(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:persist, state) do
    {_result, new_state} = persist_state(state)
    persist_timer = Process.send_after(self(), :persist, @persist_interval)
    {:noreply, %{new_state | persist_timer: persist_timer}}
  end

  def handle_info(:idle_timeout, state) do
    if Presence.count(state.workflow_id) == 0 do
      Logger.info("Edit session idle with no users, shutting down")
      Persistence.persist(state)
      {:stop, :normal, state}
    else
      idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
      {:noreply, %{state | idle_timer: idle_timer}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Edit session terminating", reason: inspect(reason))

    try do
      Persistence.persist(state)
    catch
      :exit, _ -> :ok
      :error, _ -> :ok
    end

    :ok
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp load_initial_state(workflow_id) do
    with {:ok, draft} <- Workflows.get_draft(workflow_id),
         {:ok, last_seq, ops} <- Persistence.load_pending_ops(workflow_id) do
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
    if MapSet.member?(state.applied_ops, operation.id) do
      existing_op = Enum.find(state.op_buffer, &(&1.operation_id == operation.id))
      {:ok, state, %{seq: existing_op.seq, status: :duplicate}}
    else
      with :ok <- Operations.validate(state.draft, operation) do
        new_seq = state.seq + 1

        {new_draft, new_editor_state, editor_state_changed} =
          apply_to_state(state.draft, state.editor_state, operation)

        op_record = %EditOperation{
          operation_id: operation.id,
          seq: new_seq,
          type: operation.type,
          payload: operation.payload,
          user_id: operation.user_id,
          client_seq: Map.get(operation, :client_seq),
          workflow_id: state.workflow_id
        }

        new_state = %{
          state
          | draft: new_draft,
            editor_state: new_editor_state,
            seq: new_seq,
            op_buffer: append_to_buffer(state.op_buffer, op_record),
            applied_ops: MapSet.put(state.applied_ops, operation.id),
            dirty: true
        }

        # Broadcast the operation to all subscribers
        Logger.debug(
          "Broadcasting operation #{op_record.operation_id} (type: #{op_record.type}) to topic #{PubSub.session_topic(state.workflow_id)}"
        )

        PubSub.broadcast_operation(state.workflow_id, op_record)

        # If editor state changed, broadcast that too
        if editor_state_changed do
          Logger.debug("Broadcasting editor_state_updated for workflow #{state.workflow_id}")
          broadcast_editor_state_update(state.workflow_id, new_editor_state)
        end

        {:ok, new_state, %{seq: new_seq, status: :applied}}
      end
    end
  end

  defp apply_to_state(draft, editor_state, operation) do
    case operation.type do
      # Workflow structure operations - modify draft
      type
      when type in [
             :add_step,
             :remove_step,
             :update_step_config,
             :update_step_position,
             :update_step_metadata,
             :add_connection,
             :remove_connection
           ] ->
        {:ok, new_draft} = Operations.apply(draft, operation)

        # Clean up editor state if step was removed
        new_editor_state =
          if type == :remove_step do
            step_id =
              Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")

            editor_state
            |> EditorState.unpin_output(step_id)
            |> EditorState.enable_step(step_id)
          else
            editor_state
          end

        {new_draft, new_editor_state, type == :remove_step}

      # Editor-only operations - modify editor state only
      :pin_step_output ->
        new_editor_state =
          EditorState.pin_output(
            editor_state,
            operation.payload.step_id,
            operation.payload[:output_data] || %{}
          )

        {draft, new_editor_state, true}

      :unpin_step_output ->
        new_editor_state =
          EditorState.unpin_output(
            editor_state,
            operation.payload.step_id
          )

        {draft, new_editor_state, true}

      :disable_step ->
        new_editor_state =
          EditorState.disable_step(
            editor_state,
            Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id"),
            Map.get(operation.payload, :user_id) || Map.get(operation.payload, "user_id")
          )

        {draft, new_editor_state, true}

      :enable_step ->
        new_editor_state =
          EditorState.enable_step(
            editor_state,
            operation.payload.step_id
          )

        {draft, new_editor_state, true}

      _ ->
        {draft, editor_state, false}
    end
  end

  defp broadcast_editor_state_update(workflow_id, editor_state) do
    Phoenix.PubSub.broadcast(
      Imgd.PubSub,
      PubSub.session_topic(workflow_id),
      {:editor_state_updated, editor_state}
    )
  end

  defp append_to_buffer(buffer, op) do
    [op | buffer]
    |> Enum.take(@max_op_buffer)
  end

  defp build_sync_response(state, nil) do
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
        ops =
          state.op_buffer
          |> Enum.filter(&(&1.seq > client_seq))
          |> Enum.sort_by(& &1.seq)

        %{type: :incremental, ops: ops, seq: state.seq}

      true ->
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
      disabled_steps: MapSet.to_list(editor_state.disabled_steps),
      disabled_mode: editor_state.disabled_mode,
      step_locks: editor_state.step_locks
    }
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
    %{state | idle_timer: idle_timer}
  end

  defp persist_state(state) do
    if state.dirty do
      case Persistence.persist(state) do
        :ok ->
          Logger.debug("Persisted edit session state")
          {:ok, %{state | dirty: false}}

        {:error, reason} ->
          Logger.error("Failed to persist: #{inspect(reason)}")
          {{:error, reason}, state}
      end
    else
      {:noop, state}
    end
  end
end

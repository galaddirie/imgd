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
  @webhook_test_timeout :timer.minutes(10)

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
      :idle_timer,
      :webhook_test_timer
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

  @doc "Enable a temporary test webhook listener for a workflow."
  def enable_test_webhook(workflow_id, attrs) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:enable_test_webhook, attrs})
    end
  end

  @doc "Disable the active test webhook listener for a workflow."
  def disable_test_webhook(workflow_id, step_id \\ nil) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:disable_test_webhook, step_id})
    end
  end

  @doc "Check if a test webhook listener is active for a path and method."
  def test_webhook_enabled?(workflow_id, path, method) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:test_webhook_enabled?, path, method})
    else
      _ -> {:error, :not_listening}
    end
  end

  @doc "Broadcast that a test webhook execution was created for the session."
  def notify_webhook_test_execution(workflow_id, execution_id) do
    case lookup_session_pid(workflow_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:webhook_test_execution, execution_id})
        :ok

      _ ->
        :ok
    end
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

        state = %{
          state
          | persist_timer: persist_timer,
            idle_timer: idle_timer
        }

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

  def handle_call({:enable_test_webhook, attrs}, _from, state) do
    case resolve_webhook_test(state.draft, attrs) do
      {:ok, webhook_test} ->
        editor_state = EditorState.enable_webhook_test(state.editor_state, webhook_test)

        state =
          state
          |> cancel_webhook_test_timer()
          |> schedule_webhook_test_timer(webhook_test)
          |> Map.put(:editor_state, editor_state)

        broadcast_editor_state_update(state.workflow_id, editor_state)
        {:reply, {:ok, webhook_test}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disable_test_webhook, step_id}, _from, state) do
    {state, editor_state_changed} = maybe_disable_webhook_test(state, step_id)

    if editor_state_changed do
      broadcast_editor_state_update(state.workflow_id, state.editor_state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:test_webhook_enabled?, path, method}, _from, state) do
    case webhook_test_matches?(state.editor_state.webhook_test, path, method) do
      {:ok, webhook_test} -> {:reply, {:ok, webhook_test}, state}
      :error -> {:reply, {:error, :not_listening}, state}
    end
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

  def handle_cast({:webhook_test_execution, execution_id}, state) do
    PubSub.broadcast_webhook_test_execution(state.workflow_id, execution_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:persist, state) do
    {_result, new_state} = persist_state(state)
    persist_timer = Process.send_after(self(), :persist, @persist_interval)
    {:noreply, %{new_state | persist_timer: persist_timer}}
  end

  def handle_info({:webhook_test_timeout, key}, state) do
    {state, editor_state_changed} = maybe_disable_webhook_test(state, key)

    if editor_state_changed do
      broadcast_editor_state_update(state.workflow_id, state.editor_state)
    end

    {:noreply, state}
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
        {:ok, new_draft} ->
          {new_draft, max(seq, op.seq)}

        {:error, reason} ->
          Logger.error(
            "Failed to replay operation #{op.operation_id} (type: #{op.type}) during recovery: #{inspect(reason)}"
          )

          {d, seq}
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
            Map.get(operation.payload, :mode) || Map.get(operation.payload, "mode") || :skip
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

  defp lookup_session_pid(workflow_id) do
    case Registry.lookup(Imgd.Collaboration.EditSession.Registry, workflow_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp resolve_webhook_test(draft, attrs) do
    step_id = Map.get(attrs, :step_id) || Map.get(attrs, "step_id")
    path = Map.get(attrs, :path) || Map.get(attrs, "path")
    method = Map.get(attrs, :method) || Map.get(attrs, "method")
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    case find_webhook_step(draft, step_id, path) do
      {:ok, step, path_from_step} ->
        method =
          normalize_method(
            Map.get(step.config, "http_method") || Map.get(step.config, :http_method) || method
          )

        {:ok,
         %{
           step_id: step.id,
           path: path_from_step,
           method: method,
           enabled_by: user_id
         }}

      :error ->
        normalized_path = normalize_path(path)
        normalized_method = normalize_method(method)

        if webhook_trigger_exists?(draft, normalized_path, normalized_method) do
          {:ok,
           %{
             step_id: step_id,
             path: normalized_path,
             method: normalized_method,
             enabled_by: user_id
           }}
        else
          {:error, :webhook_not_found}
        end
    end
  end

  defp find_webhook_step(_draft, nil, nil), do: :error

  defp find_webhook_step(draft, step_id, path) do
    step =
      Enum.find(draft.steps, fn step ->
        step.id == step_id && step.type_id == "webhook_trigger"
      end)

    cond do
      step ->
        {:ok, step,
         normalize_path(Map.get(step.config, "path") || Map.get(step.config, :path) || step.id)}

      true ->
        normalized_path = normalize_path(path)

        step_by_path =
          Enum.find(draft.steps, fn step ->
            step.type_id == "webhook_trigger" &&
              normalize_path(
                Map.get(step.config, "path") || Map.get(step.config, :path) || step.id
              ) ==
                normalized_path
          end)

        if step_by_path do
          {:ok, step_by_path,
           normalize_path(
             Map.get(step_by_path.config, "path") || Map.get(step_by_path.config, :path) ||
               step_by_path.id
           )}
        else
          :error
        end
    end
  end

  defp webhook_trigger_exists?(_draft, nil, _method), do: false

  defp webhook_trigger_exists?(draft, path, method) do
    # Only search steps (triggers are now steps)
    Enum.any?(draft.steps || [], fn step ->
      step.type_id == "webhook_trigger" &&
        normalize_path(Map.get(step.config, "path") || Map.get(step.config, :path) || step.id) ==
          path &&
        normalize_method(
          Map.get(step.config, "http_method") || Map.get(step.config, :http_method)
        ) == method
    end)
  end

  defp webhook_test_matches?(nil, _path, _method), do: :error

  defp webhook_test_matches?(webhook_test, path, method) do
    normalized_path = normalize_path(path)
    normalized_method = normalize_method(method)

    if webhook_test.path == normalized_path &&
         normalize_method(webhook_test.method) == normalized_method do
      {:ok, webhook_test}
    else
      :error
    end
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_method(nil), do: "POST"

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.trim()
    |> case do
      "" -> "POST"
      trimmed -> String.upcase(trimmed)
    end
  end

  defp schedule_webhook_test_timer(state, webhook_test) do
    key = webhook_test_key(webhook_test)
    timer = Process.send_after(self(), {:webhook_test_timeout, key}, @webhook_test_timeout)
    %{state | webhook_test_timer: timer}
  end

  defp cancel_webhook_test_timer(state) do
    if state.webhook_test_timer do
      Process.cancel_timer(state.webhook_test_timer)
    end

    %{state | webhook_test_timer: nil}
  end

  defp webhook_test_key(%{step_id: step_id}) when is_binary(step_id), do: {:step, step_id}
  defp webhook_test_key(%{path: path}) when is_binary(path), do: {:path, path}
  defp webhook_test_key(_), do: :unknown

  defp maybe_disable_webhook_test(state, nil) do
    do_disable_webhook_test(state, state.editor_state.webhook_test)
  end

  defp maybe_disable_webhook_test(state, {:step, step_id}) do
    current = state.editor_state.webhook_test

    if current && current.step_id == step_id do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, {:path, path}) do
    current = state.editor_state.webhook_test

    if current && current.path == path do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, step_id) when is_binary(step_id) do
    current = state.editor_state.webhook_test

    if current && current.step_id == step_id do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, _step_id), do: {state, false}

  defp do_disable_webhook_test(state, nil), do: {cancel_webhook_test_timer(state), false}

  defp do_disable_webhook_test(state, _current) do
    editor_state = EditorState.disable_webhook_test(state.editor_state)

    state =
      state
      |> cancel_webhook_test_timer()
      |> Map.put(:editor_state, editor_state)

    {state, true}
  end

  defp broadcast_editor_state_update(workflow_id, editor_state) do
    PubSub.broadcast_editor_state_updated(workflow_id, editor_state)
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
      step_locks: editor_state.step_locks,
      webhook_test: editor_state.webhook_test
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

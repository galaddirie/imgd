defmodule Imgd.Workflows.EditingSession.Server do
  @moduledoc """
  GenServer that owns editing session state in memory.
  """
  use GenServer, restart: :temporary

  alias Imgd.Workflows.EditingSessions
  alias Imgd.Workflows.EditingSession.Registry
  import Ecto.Query
  alias Imgd.Repo

  @idle_timeout :timer.hours(1)
  @persist_debounce :timer.seconds(5)

  defmodule State do
    defstruct [
      :user_id,
      :workflow_id,
      :session_id,
      :source_hash,
      :pinned_outputs,
      :dirty,
      :last_persisted_at,
      :timer
    ]
  end

  # API

  def start_link(args) do
    scope = Keyword.fetch!(args, :scope)
    workflow = Keyword.fetch!(args, :workflow)
    user_id = scope.user.id
    workflow_id = workflow.id

    GenServer.start_link(__MODULE__, args, name: Registry.via_tuple(user_id, workflow_id))
  end

  def get_summary(pid) do
    GenServer.call(pid, :get_summary)
  end

  def pin_output(pid, pin_attrs) do
    GenServer.call(pid, {:pin_output, pin_attrs})
  end

  def unpin_output(pid, node_id) do
    GenServer.call(pid, {:unpin_output, node_id})
  end

  def clear_pins(pid) do
    GenServer.call(pid, :clear_pins)
  end

  def get_status(pid, workflow) do
    GenServer.call(pid, {:get_status, workflow})
  end

  def get_compatible_pins(pid, source_hash) do
    GenServer.call(pid, {:get_compatible_pins, source_hash})
  end

  def sync_persist(pid) do
    GenServer.call(pid, :persist)
  end

  # Callbacks

  @impl true
  def init(args) do
    scope = Keyword.fetch!(args, :scope)
    workflow = Keyword.fetch!(args, :workflow)
    user_id = scope.user.id
    workflow_id = workflow.id

    # Load session from DB or create one
    case EditingSessions.get_or_create_session(scope, workflow) do
      {:ok, session} ->
        # Load pins
        pins = EditingSessions.list_pins(session)
        pinned_outputs = Map.new(pins, &{&1.node_id, &1})

        state = %State{
          user_id: user_id,
          workflow_id: workflow_id,
          session_id: session.id,
          source_hash: session.base_source_hash,
          pinned_outputs: pinned_outputs,
          dirty: false,
          last_persisted_at: DateTime.utc_now()
        }

        {:ok, state, @idle_timeout}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = %{
      session_id: state.session_id,
      source_hash: state.source_hash,
      pinned_count: map_size(state.pinned_outputs)
    }

    {:reply, summary, state, @idle_timeout}
  end

  @impl true
  def handle_call({:pin_output, pin_attrs}, _from, state) do
    node_id = pin_attrs.node_id

    # Update in-memory
    new_pin =
      struct(
        Imgd.Workflows.PinnedOutput,
        Map.merge(pin_attrs, %{
          editing_session_id: state.session_id,
          user_id: state.user_id,
          pinned_at: DateTime.utc_now()
        })
      )

    pinned_outputs = Map.put(state.pinned_outputs, node_id, new_pin)
    state = %{state | pinned_outputs: pinned_outputs, dirty: true}

    state = schedule_persist(state)
    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_call({:unpin_output, node_id}, _from, state) do
    pinned_outputs = Map.delete(state.pinned_outputs, node_id)
    state = %{state | pinned_outputs: pinned_outputs, dirty: true}

    # We also need to explicitly delete from DB eventually, but for simplicity
    # we'll let the persisted set reflect the in-memory set.
    state = schedule_persist(state)
    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_call(:clear_pins, _from, state) do
    state = %{state | pinned_outputs: %{}, dirty: true}
    state = schedule_persist(state)
    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_call({:get_status, workflow}, _from, state) do
    status = EditingSessions.build_pins_status(state.pinned_outputs, state.source_hash, workflow)
    {:reply, status, state, @idle_timeout}
  end

  @impl true
  def handle_call({:get_compatible_pins, source_hash}, _from, state) do
    pins =
      state.pinned_outputs
      |> Map.values()
      |> Enum.filter(&(&1.source_hash == source_hash))
      |> Map.new(&{&1.node_id, &1.data})

    {:reply, pins, state, @idle_timeout}
  end

  @impl true
  def handle_call(:persist, _from, state) do
    state = persist_now(state)
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, %{state | timer: nil, dirty: false}, @idle_timeout}
  end

  @impl true
  def handle_info(:persist, state) do
    state = persist_now(state)
    {:noreply, %{state | timer: nil}, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.dirty do
      persist_now(state)
    end

    :ok
  end

  # Helpers

  defp schedule_persist(%{timer: nil} = state) do
    timer = Process.send_after(self(), :persist, @persist_debounce)
    %{state | timer: timer}
  end

  defp schedule_persist(state), do: state

  defp persist_now(state) do
    # Perform full sync of pins
    # In a real high-traffic app, we'd only persist diffs or use COPY
    # But for a single-user editing session, a transact/delete_all/insert_all is fast enough

    Repo.transact(fn ->
      # Clear existing pins for this session
      Imgd.Workflows.PinnedOutput
      |> where([p], p.editing_session_id == ^state.session_id)
      |> Repo.delete_all()

      # Insert all current pins
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      allowed_fields = [
        :editing_session_id,
        :workflow_draft_id,
        :user_id,
        :node_id,
        :source_hash,
        :node_config_hash,
        :data,
        :source_execution_id,
        :label,
        :pinned_at
      ]

      # Load draft to get ID
      workflow = Repo.get(Imgd.Workflows.Workflow, state.workflow_id) |> Repo.preload(:draft)
      draft_id = workflow.draft.workflow_id

      entries =
        Enum.map(state.pinned_outputs, fn {_, pin} ->
          pin
          |> Map.take(allowed_fields)
          |> Map.put(:workflow_draft_id, draft_id)
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)

      unless entries == [] do
        Repo.insert_all(Imgd.Workflows.PinnedOutput, entries)
      end

      # Update session last_activity_at
      _ = EditingSessions.touch_session_id(state.session_id)

      {:ok, :synced}
    end)

    %{state | dirty: false, last_persisted_at: DateTime.utc_now()}
  end
end

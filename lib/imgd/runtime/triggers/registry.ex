defmodule Imgd.Runtime.Triggers.Registry do
  @moduledoc """
  GenServer that manages active triggers for published workflows.

  Responsibilities:
  - Tracks which workflows are active and have triggers.
  - Acts as a lookup for webhook routing (to verify workflow status).
  """
  use GenServer
  require Logger

  alias Imgd.Workflows
  alias Imgd.Repo

  @type state :: %{
          active_workflows: MapSet.t(),
        }

  # ============================================================================
  # API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a workflow for trigger activation.
  Usually called when a workflow is published or toggled to 'active'.
  """
  def register(workflow_id, name \\ __MODULE__) do
    GenServer.cast(name, {:register, workflow_id})
  end

  @doc """
  Unregisters a workflow, stopping its child processes and removing it from active registry.
  """
  def unregister(workflow_id, name \\ __MODULE__) do
    GenServer.cast(name, {:unregister, workflow_id})
  end

  @doc """
  Checks if a workflow is currently active in the registry.
  """
  def active?(workflow_id, name \\ __MODULE__) do
    GenServer.call(name, {:is_active, workflow_id})
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("Initializing Trigger Registry")

    {:ok, %{active_workflows: MapSet.new()}, {:continue, :load_active_workflows}}
  end

  @impl true
  def handle_continue(:load_active_workflows, state) do
    # Load all active workflows from DB and register them
    active_ids =
      Workflows.list_active_workflows_query()
      |> Repo.all()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Logger.info("Trigger Registry: Loaded #{MapSet.size(active_ids)} active workflows")

    {:noreply, %{state | active_workflows: active_ids}}
  end

  @impl true
  def handle_cast({:register, workflow_id}, state) do
    Logger.info("Registering triggers for workflow: #{workflow_id}")
    {:noreply, %{state | active_workflows: MapSet.put(state.active_workflows, workflow_id)}}
  end

  @impl true
  def handle_cast({:unregister, workflow_id}, state) do
    Logger.info("Unregistering triggers for workflow: #{workflow_id}")
    {:noreply, %{state | active_workflows: MapSet.delete(state.active_workflows, workflow_id)}}
  end

  @impl true
  def handle_call({:is_active, workflow_id}, _from, state) do
    {:reply, MapSet.member?(state.active_workflows, workflow_id), state}
  end
end

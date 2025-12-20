defmodule Imgd.Workflows.EditingSession.DynamicSupervisor do
  @moduledoc """
  DynamicSupervisor to manage the lifecycle of session processes.
  """
  use DynamicSupervisor

  alias Imgd.Workflows.EditingSession.Server

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(scope, workflow, opts \\ []) do
    spec = {Server, [scope: scope, workflow: workflow, opts: opts]}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end

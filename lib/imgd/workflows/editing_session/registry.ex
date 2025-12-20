defmodule Imgd.Workflows.EditingSession.Registry do
  @moduledoc """
  Registry for locating editing session processes by `{user_id, workflow_id}`.
  """
  def child_spec(_) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  def via_tuple(user_id, workflow_id) do
    {:via, Registry, {__MODULE__, {user_id, workflow_id}}}
  end

  def lookup(user_id, workflow_id) do
    case Registry.lookup(__MODULE__, {user_id, workflow_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end

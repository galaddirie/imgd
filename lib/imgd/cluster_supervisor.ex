defmodule Imgd.ClusterSupervisor do
  @moduledoc """
  Supervisor for clustering components.

  Manages:
  - Cluster.Supervisor (Libcluster)
  - Horde.Registry
  - Horde.DynamicSupervisor
  """
  use Supervisor

  # todo: horde dynamic supervisor?
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Start libcluster supervisor with configured topologies
      {Cluster.Supervisor, [topologies, [name: Imgd.Cluster.Supervisor]]}

      # Future: Add Horde Registry and Supervisor here
      # {Horde.Registry, [keys: :unique, name: Imgd.ClusterRegistry, members: :auto]},
      # {Horde.DynamicSupervisor, [name: Imgd.ClusterDynamicSupervisor, strategy: :one_for_one, members: :auto]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

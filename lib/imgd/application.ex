defmodule Imgd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()
    Imgd.Observability.Telemetry.setup()
    Imgd.Sandbox.Telemetry.setup()

    _flame_parent = FLAME.Parent.get()

    children =
      [
        # Start the Cluster Supervisor
        Imgd.ClusterSupervisor,
        ImgdWeb.Telemetry,
        Imgd.Observability.PromEx,
        Imgd.Repo,
        {Oban, Application.fetch_env!(:imgd, Oban)},
        {DNSCluster, query: Application.get_env(:imgd, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Imgd.PubSub},
        # Step type registry - must start before endpoint so types are available
        Imgd.Steps.Registry,
        {Registry, keys: :unique, name: Imgd.Runtime.Execution.Registry},
        {Task.Supervisor, name: Imgd.Runtime.Execution.TaskSupervisor},
        Imgd.Runtime.Execution.Supervisor,
        Imgd.Runtime.Expression.Cache,
        Imgd.Sandbox.Supervisor,
        # Collaboration modules
        {Registry, keys: :unique, name: Imgd.Collaboration.EditSession.Registry},
        Imgd.Collaboration.EditSession.Supervisor,
        {Imgd.Collaboration.EditSession.Presence, []},
        ImgdWeb.Endpoint
      ]
      |> Enum.filter(& &1)

    opts = [strategy: :one_for_one, name: Imgd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ImgdWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_opentelemetry do
    :opentelemetry_cowboy.setup()
    OpentelemetryPhoenix.setup(adapter: :cowboy2)
    OpentelemetryEcto.setup([:imgd, :repo])
    OpentelemetryOban.setup()
    OpentelemetryLiveView.setup()
    OpentelemetryLoggerMetadata.setup()

    :ok
  end
end

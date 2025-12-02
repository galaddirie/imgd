defmodule Imgd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do

    setup_opentelemetry()

    children = [
      ImgdWeb.Telemetry,
      Imgd.Observability.PromEx,
      Imgd.Repo,
      {Oban, Application.fetch_env!(:imgd, Oban)},
      {DNSCluster, query: Application.get_env(:imgd, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Imgd.PubSub},
      ImgdWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Imgd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
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

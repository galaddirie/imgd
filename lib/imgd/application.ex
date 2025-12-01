defmodule Imgd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ImgdWeb.Telemetry,
      Imgd.Repo,
      {Oban, Application.fetch_env!(:imgd, Oban)},
      {DNSCluster, query: Application.get_env(:imgd, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Imgd.PubSub},
      # Start a worker by calling: Imgd.Worker.start_link(arg)
      # {Imgd.Worker, arg},
      # Start to serve requests, typically the last entry
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
end

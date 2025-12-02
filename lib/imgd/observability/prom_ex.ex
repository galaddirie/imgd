defmodule Imgd.Observability.PromEx do
  @moduledoc """
  PromEx configuration for imgd metrics.

  Exposes Prometheus metrics for:
  - Workflow execution counts, duration, and status
  - Step execution latency, counts, and error rates
  - BEAM VM metrics (memory, processes, schedulers)
  - Phoenix request metrics
  - Ecto query metrics
  - Oban job metrics

  ## Grafana Integration

  PromEx can automatically upload dashboards to Grafana.
  Configure the `:grafana` key in your config to enable this.

  ## Custom Metrics

  The `Imgd.Observability.PromEx.Plugins.Engine` plugin defines
  custom metrics specific to the workflow engine.
  """

  use PromEx, otp_app: :imgd

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      # Built-in PromEx plugins
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: ImgdWeb.Router, endpoint: ImgdWeb.Endpoint},
      {Plugins.Ecto, repos: [Imgd.Repo]},
      Plugins.Oban,

      # Custom plugin for workflow engine metrics
      Imgd.Observability.PromEx.Plugins.Engine
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus",
      default_selected_interval: "30s"
    ]
  end

  @impl true
  def dashboards do
    [
      # Built-in dashboards
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"},
      {:prom_ex, "ecto.json"},
      {:prom_ex, "oban.json"},

      # Custom workflow engine dashboard
      {:otp_app, "engine_dashboard.json"}
    ]
  end
end

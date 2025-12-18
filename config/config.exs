# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :imgd, :scopes,
  user: [
    default: true,
    module: Imgd.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Imgd.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :imgd,
  ecto_repos: [Imgd.Repo],
  generators: [timestamp_type: :utc_datetime]

quickjs_wasm_path =
  System.get_env("QJS_WASM_PATH") ||
    Path.expand("../priv/wasm/qjs-wasi.wasm", __DIR__)

config :imgd, Imgd.Sandbox,
  quickjs_wasm_path: quickjs_wasm_path,
  timeout: 5_000,
  fuel: 10_000_000,
  memory_mb: 16,
  max_code_size: 102_400,
  max_output_size: 1_048_576

config :imgd, Imgd.Sandbox.Pool,
  min: 0,
  max: 10,
  max_concurrency: 20,
  idle_shutdown_after: 30_000

# Expression cache settings
config :imgd, Imgd.Runtime.Expression.Cache,
  max_entries: 10_000,
  ttl_seconds: 3600

config :imgd, :execution_engine, Imgd.Runtime.Engines.Runic

# Allowed environment variables (security)
config :imgd, :allowed_env_vars, ~w(
  MIX_ENV
  APP_ENV
)

# Configure the endpoint
config :imgd, ImgdWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ImgdWeb.ErrorHTML, json: ImgdWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Imgd.PubSub,
  live_view: [signing_salt: "kv/AE/28"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :imgd, Imgd.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  imgd: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  imgd: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  metrics_exporter: :none,
  resource: %{
    service: %{
      name: "imgd",
      version: Mix.Project.config()[:version] || "0.1.0",
      namespace: "imgd"
    }
  }

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_compression: :gzip

config :imgd, Imgd.Observability.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled

config :logger,
  backends: [:console, {LoggerFileBackend, :file}],
  level: :info,
  truncate: 8_192

config :logger, :console,
  format: {Imgd.LoggerJSONFormatter, :format},
  metadata: :all

config :logger, :file,
  path: "log/imgd.log",
  level: :info,
  format: {Imgd.LoggerJSONFormatter, :format},
  metadata: :all,
  rotate: %{max_bytes: 104_857_600, keep: 5}

config :logger_json, :backend,
  metadata: [
    :request_id,
    :trace_id,
    :span_id,
    :execution_id,
    :workflow_id,
    :workflow_name,
    :step_hash,
    :step_name,
    :step_type,
    :attempt,
    :event
  ],
  json_encoder: Jason,
  formatter: LoggerJSON.Formatters.Basic

config :opentelemetry_logger_metadata,
  trace_id_field: :trace_id,
  span_id_field: :span_id,
  trace_flags_field: :trace_flags

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban
config :imgd, Oban,
  engine: Oban.Engines.Basic,
  queues: [
    default: 10,
    # ExecutionWorker - coordination jobs
    executions: 5
  ],
  repo: Imgd.Repo

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

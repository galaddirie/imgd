import Config

config :imgd, :env, :test

config :live_vue, enable_props_diff: false

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :imgd, Imgd.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "imgd_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :imgd, ImgdWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VYCzrEj2WYjSlUeZPsMgeV4Mahw5I0XD9qa3FA5LbZwhl4SpK0SYQ2xD79GReUWi",
  server: false

# In test we don't send emails
config :imgd, Imgd.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

config :logger, level: :warning

config :imgd, :sync_node_execution_buffer, true

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Configure Oban for testing
config :imgd, Oban, testing: :manual

config :flame, :backend, FLAME.LocalBackend

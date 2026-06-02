import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :avcs, Avcs.Repo,
  database: Path.expand("../priv/db/avcs_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :avcs,
  global_db_path: Path.expand("../tmp/test-global-avcs.sqlite3", __DIR__),
  codex_timeout_ms: 1_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :avcs, AvcsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "E0aor0uPmpl9jAgQLRLjWp5YxH+DbJYU5+e3HU9utCn6/UiEw6WwzK9Dpe7laNoN",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

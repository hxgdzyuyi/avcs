# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :avcs,
  ecto_repos: [Avcs.Repo],
  codex_schema_validation: config_env() in [:dev, :test],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :avcs, AvcsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AvcsWeb.ErrorHTML, json: AvcsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Avcs.PubSub,
  live_view: [signing_salt: "z4wx6hRh"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

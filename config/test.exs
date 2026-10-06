import Config

# Don't start the Slack supervision tree under `mix test`:
# `Slack.Supervisor.init/1` calls `auth.test` over the network and raises
# unless Slack answers `ok`, so the application would fail to boot.
config :salamendar, :slack, start_supervisor?: false

config :logger, level: :warning

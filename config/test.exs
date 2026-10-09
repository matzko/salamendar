import Config

# MIX_TEST_PARTITION lets CI run partitioned suites against separate databases.
config :salamendar, Salamendar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "salamendar_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Don't start the Slack supervision tree under `mix test`:
# `Slack.Supervisor.init/1` calls `auth.test` over the network and raises
# unless Slack answers `ok`, so the application would fail to boot.
config :salamendar, :slack, start_supervisor?: false

# Slack Web API calls go to a Mox mock (defined in `test/test_helper.exs`).
config :salamendar, :slack_api, Salamendar.SlackAPI.Mock

# For `Salamendar.SlackAPI.Client`'s own tests, which never reach Slack:
# requests go to `Req.Test` stubs.
config :salamendar, slack_bot_token: "xoxb-test"

config :salamendar, Salamendar.SlackAPI.Client,
  req_options: [plug: {Req.Test, Salamendar.SlackAPI.Client}]

# Use the bundled tz data; don't fetch updates over the network in tests.
config :tzdata, :autoupdate, :disabled

config :logger, level: :warning

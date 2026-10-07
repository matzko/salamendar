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

config :logger, level: :warning

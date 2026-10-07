import Config

# Matches compose.yaml. `just up` starts it.
config :salamendar, Salamendar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "salamendar_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :debug

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: [:module, :line, :function]

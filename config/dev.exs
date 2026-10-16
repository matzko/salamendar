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

# `just run` (`iex -S mix`) serves the web calendar alongside the bot.
config :salamendar, SalamendarWeb.Endpoint,
  # Loopback only. Use `ip: {0, 0, 0, 0}` to allow other machines.
  http: [ip: {127, 0, 0, 1}],
  server: true,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "I/4CBlZpd1dcS+q3TlF8bmmZiuarInIitg40n+t70QgKST4av+Jmq8teD4wZorL/",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:salamendar, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/salamendar_web/router\.ex$"E,
      ~r"lib/salamendar_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Changing these needs `mix clean` and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :logger, level: :debug

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: [:module, :line, :function]

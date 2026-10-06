import Config

config :logger, level: :debug

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: [:module, :line, :function]

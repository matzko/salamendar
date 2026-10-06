import Config

config :slack_elixir,
  socket_mode: true

import_config "#{config_env()}.exs"

# Local, git-ignored overrides (e.g. Slack tokens) for dev. Copy
# `config/.env.exs.example` to `config/.env.exs` to use it.
if config_env() == :dev and File.exists?(Path.expand(".env.exs", __DIR__)) do
  import_config ".env.exs"
end

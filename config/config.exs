import Config

config :salamendar, ecto_repos: [Salamendar.Repo]

# UUID primary/foreign keys and timezone-aware timestamps for every table.
# Schemas pick up the matching settings via `use Salamendar.Schema`.
config :salamendar, Salamendar.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

# Full IANA time zone support (the default database only knows Etc/UTC).
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Used for channels that haven't set their own time zone.
config :salamendar, default_time_zone: "America/Chicago"

config :slack_elixir,
  socket_mode: true

import_config "#{config_env()}.exs"

# Local, git-ignored overrides (e.g. Slack tokens) for dev. Copy
# `config/.env.exs.example` to `config/.env.exs` to use it.
if config_env() == :dev and File.exists?(Path.expand(".env.exs", __DIR__)) do
  import_config ".env.exs"
end

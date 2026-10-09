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

# Background jobs. Cron times are UTC.
config :salamendar, Oban,
  repo: Salamendar.Repo,
  # `canvases` is kept small: `canvases.edit` is rate limited per workspace.
  queues: [default: 5, canvases: 2],
  plugins: [
    # Keep finished jobs for a week, for debugging.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Salamendar.Workers.Rollover},
       # 03:00 in Chicago (08:00 UTC during daylight saving time).
       {"0 8 * * *", Salamendar.Workers.ReconcileMembers}
     ]}
  ]

import_config "#{config_env()}.exs"

# Local, git-ignored overrides (e.g. Slack tokens) for dev. Copy
# `config/.env.exs.example` to `config/.env.exs` to use it.
if config_env() == :dev and File.exists?(Path.expand(".env.exs", __DIR__)) do
  import_config ".env.exs"
end

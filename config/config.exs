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

# The web calendar. `PORT` and, in prod, `PHX_HOST` are read in
# `config/runtime.exs`.
config :salamendar, SalamendarWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SalamendarWeb.ErrorHTML, json: SalamendarWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Salamendar.PubSub,
  live_view: [signing_salt: "bF09QLFU"]

# The base of links to the web calendar sent to Slack.
config :salamendar, :web_url, "http://localhost:4000"

config :phoenix, :json_library, Jason

# Bundles `app.js` and `app.css` into `priv/static/assets/{js,css}/`.
config :esbuild,
  version: "0.25.4",
  salamendar: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

import_config "#{config_env()}.exs"

# Local, git-ignored overrides (e.g. Slack tokens) for dev. Copy
# `config/.env.exs.example` to `config/.env.exs` to use it.
if config_env() == :dev and File.exists?(Path.expand(".env.exs", __DIR__)) do
  import_config ".env.exs"
end

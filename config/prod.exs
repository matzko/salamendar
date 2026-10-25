import Config

# Made by `mix assets.deploy`.
config :salamendar, SalamendarWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

# A release can't write tz data updates into its own `lib/`, and shouldn't
# fetch them at runtime. Updates come with tzdata version bumps.
config :tzdata, :autoupdate, :disabled

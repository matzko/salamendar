import Config

# Made by `mix assets.deploy`.
config :salamendar, SalamendarWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

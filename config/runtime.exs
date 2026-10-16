import Config

# Environment variables win over anything set in `config/.env.exs`.
slack_env =
  [slack_bot_token: "SLACK_BOT_TOKEN", slack_app_token: "SLACK_APP_TOKEN"]
  |> Enum.map(fn {key, var} -> {key, System.get_env(var)} end)
  |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

if slack_env != [] do
  config :salamendar, slack_env
end

# Releases need `PHX_SERVER=true` to serve HTTP.
if System.get_env("PHX_SERVER") do
  config :salamendar, SalamendarWeb.Endpoint, server: true
end

if config_env() != :test do
  config :salamendar, SalamendarWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE must be set. Generate one with `mix phx.gen.secret`."

  host = System.get_env("PHX_HOST") || raise "PHX_HOST must be set, e.g. salamendar.example.com"

  config :salamendar, SalamendarWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # IPv6 and IPv4, on all interfaces.
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :salamendar, :web_url, "https://#{host}"

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL must be set, e.g. ecto://USER:PASS@HOST/DATABASE"

  config :salamendar, Salamendar.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

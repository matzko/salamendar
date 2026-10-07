import Config

# Environment variables win over anything set in `config/.env.exs`.
slack_env =
  [slack_bot_token: "SLACK_BOT_TOKEN", slack_app_token: "SLACK_APP_TOKEN"]
  |> Enum.map(fn {key, var} -> {key, System.get_env(var)} end)
  |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

if slack_env != [] do
  config :salamendar, slack_env
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL must be set, e.g. ecto://USER:PASS@HOST/DATABASE"

  config :salamendar, Salamendar.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

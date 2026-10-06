import Config

# Environment variables win over anything set in `config/.env.exs`.
slack_env =
  [slack_bot_token: "SLACK_BOT_TOKEN", slack_app_token: "SLACK_APP_TOKEN"]
  |> Enum.map(fn {key, var} -> {key, System.get_env(var)} end)
  |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

if slack_env != [] do
  config :salamendar, slack_env
end

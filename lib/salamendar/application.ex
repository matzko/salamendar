defmodule Salamendar.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Salamendar.Repo,
      {Oban, Application.fetch_env!(:salamendar, Oban)} | slack_children()
    ]

    opts = [strategy: :one_for_one, name: Salamendar.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `Slack.Supervisor.init/1` fetches the bot's identity over the network and
  # raises if `auth.test` doesn't come back `ok`, so it can't start under
  # `mix test` (switched off in `config/test.exs`). Elsewhere a missing token
  # is a hard failure: a bot that silently can't reach Slack is worse than
  # one that doesn't boot.
  defp slack_children do
    if Keyword.get(Application.get_env(:salamendar, :slack, []), :start_supervisor?, true) do
      [{Slack.Supervisor, slack_bot_config()}]
    else
      []
    end
  end

  defp slack_bot_config do
    bot_token = Application.get_env(:salamendar, :slack_bot_token)
    app_token = Application.get_env(:salamendar, :slack_app_token)

    unless bot_token && app_token do
      raise "SLACK_BOT_TOKEN and SLACK_APP_TOKEN must be set " <>
              "(environment variables or config/.env.exs)"
    end

    [
      bot: Salamendar.Bot,
      bot_token: bot_token,
      app_token: app_token
    ]
  end
end

defmodule Salamendar.MixProject do
  use Mix.Project

  def project do
    [
      app: :salamendar,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Salamendar.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Fork of ryanwinchester/slack_elixir that also dispatches Socket Mode
      # `interactive` envelopes (Block Kit button clicks, etc.) to the bot.
      {:slack_elixir,
       git: "https://github.com/matzko/slack_elixir.git",
       ref: "f7d2a1bc9671981995ab98913d6ac2452bf1b29f"},
      {:jason, "~> 1.4"}
    ]
  end
end

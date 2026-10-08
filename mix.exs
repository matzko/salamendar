defmodule Salamendar.MixProject do
  use Mix.Project

  def project do
    [
      app: :salamendar,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Salamendar.Application, []}
    ]
  end

  # Test helpers like `Salamendar.DataCase` live in test/support.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Fork of ryanwinchester/slack_elixir that also dispatches Socket Mode
      # `interactive` envelopes (Block Kit button clicks, etc.) to the bot and
      # lets `view_submission` handlers return `{:ack, payload}` to show
      # modal validation errors.
      {:slack_elixir,
       git: "https://github.com/matzko/slack_elixir.git",
       ref: "afec212f50b2fea252cef32472c3dc4a8394d5df"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end

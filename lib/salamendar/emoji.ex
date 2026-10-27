defmodule Salamendar.Emoji do
  @moduledoc """
  Slack's emoji names (`"tada"`, `"+1"`), from
  `priv/static/vendor/emoji.json`, which the web picker reads too. See
  `Mix.Tasks.Salamendar.Gen.Emoji` for where the file comes from.
  """

  @path Path.expand("../../priv/static/vendor/emoji.json", __DIR__)
  @external_resource @path

  @by_name for [char, names, _category] <- Jason.decode!(File.read!(@path))["emoji"],
               name <- names,
               into: %{},
               do: {name, char}

  @doc """
  The emoji named `name` (without colons), or nil.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(name), do: Map.get(@by_name, name)
end

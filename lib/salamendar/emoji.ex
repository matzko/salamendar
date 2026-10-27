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

  @doc """
  `text` with each `:name:` that `get/1` knows replaced by its emoji, as
  Slack shows it. Anything else (custom workspace emoji, typos,
  `10:30:00`) is left as typed. Skin tones (`:wave::skin-tone-3:`) are
  left as text for now.
  """
  @spec replace_shortcodes(String.t()) :: String.t()
  @spec replace_shortcodes(nil) :: nil
  def replace_shortcodes(nil), do: nil

  def replace_shortcodes(text) do
    [first | rest] = String.split(text, ":")
    IO.iodata_to_binary([first | replace_parts(rest)])
  end

  # Each part followed a `:`. A known name with another part after it was
  # `:name:`: the emoji takes both colons, and the part after it starts
  # fresh, as Slack reads `:x:tada:` as `:x` then `:tada:`.
  defp replace_parts([name, next | rest]) do
    case get(name) do
      nil -> [":", name | replace_parts([next | rest])]
      emoji -> [emoji, next | replace_parts(rest)]
    end
  end

  defp replace_parts([last]), do: [":", last]
  defp replace_parts([]), do: []
end

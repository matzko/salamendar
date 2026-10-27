defmodule Mix.Tasks.Salamendar.Gen.Emoji do
  @shortdoc "Writes priv/static/vendor/emoji.json from iamcal's emoji.json"

  @moduledoc """
  Turns iamcal's `emoji.json` (the `emoji-datasource` package, where
  Slack's emoji names come from) into the compact file the web picker and
  `Salamendar.Emoji` read:

      mix salamendar.gen.emoji path/to/emoji.json

  `just update-emoji VERSION` downloads the file and runs this.

  The output is `{"categories": [...], "emoji": [[char, [names...],
  category_index], ...]}`, in iamcal's `sort_order`, one emoji per line so
  updates diff well. The first name is the one Slack shows.

  Left out: the "Component" category (the skin tone modifiers, which
  aren't emoji on their own) and emoji newer than Unicode 15.1, which
  older systems draw as boxes. Obsoleted entries (`:runner:`, `:cop:`)
  stay: Slack still takes their names.
  """

  use Mix.Task

  @output "priv/static/vendor/emoji.json"
  @max_version "15.1"
  @skipped_categories ["Component"]

  @impl Mix.Task
  def run([path]) do
    output =
      path
      |> File.read!()
      |> Jason.decode!()
      |> compact()
      |> encode()

    File.write!(@output, output)
    Mix.shell().info("Wrote #{@output}")
  end

  def run(_), do: Mix.raise("Usage: mix salamendar.gen.emoji path/to/emoji.json")

  @doc """
  The compact form of iamcal's entries, as a map of `"categories"` and
  `"emoji"`.
  """
  @spec compact([map()]) :: %{String.t() => list()}
  def compact(entries) do
    kept =
      entries
      |> Enum.reject(&(&1["category"] in @skipped_categories))
      |> Enum.filter(&supported?/1)
      |> Enum.sort_by(& &1["sort_order"])

    categories = kept |> Enum.map(& &1["category"]) |> Enum.uniq()
    index = categories |> Enum.with_index() |> Map.new()

    emoji =
      for entry <- kept do
        [char(entry["unified"]), entry["short_names"], Map.fetch!(index, entry["category"])]
      end

    %{"categories" => categories, "emoji" => emoji}
  end

  defp supported?(%{"added_in" => added_in}),
    do: Version.compare(version(added_in), version(@max_version)) != :gt

  defp version(string) do
    [major, minor] = String.split(string, ".")
    Version.parse!("#{major}.#{minor}.0")
  end

  # "1F44D-1F3FB" → "👍🏻"
  defp char(unified) do
    unified
    |> String.split("-")
    |> Enum.map(&String.to_integer(&1, 16))
    |> List.to_string()
  end

  defp encode(%{"categories" => categories, "emoji" => emoji}) do
    lines = Enum.map_join(emoji, ",\n", &Jason.encode!/1)
    ~s({"categories":#{Jason.encode!(categories)},"emoji":[\n#{lines}\n]}\n)
  end
end

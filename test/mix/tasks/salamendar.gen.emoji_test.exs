defmodule Mix.Tasks.Salamendar.Gen.EmojiTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Salamendar.Gen.Emoji

  defp entry(unified, names, category, sort_order, added_in \\ "0.6") do
    %{
      "unified" => unified,
      "short_names" => names,
      "category" => category,
      "sort_order" => sort_order,
      "added_in" => added_in
    }
  end

  test "compact/1 keeps the char, names and category, in sort order" do
    entries = [
      entry("1F44D", ["+1", "thumbsup"], "People & Body", 197),
      entry("1F600", ["grinning"], "Smileys & Emotion", 1),
      entry("2764-FE0F", ["heart"], "Smileys & Emotion", 150)
    ]

    assert Emoji.compact(entries) == %{
             "categories" => ["Smileys & Emotion", "People & Body"],
             "emoji" => [
               ["😀", ["grinning"], 0],
               ["❤️", ["heart"], 0],
               ["👍", ["+1", "thumbsup"], 1]
             ]
           }
  end

  test "compact/1 drops skin tone components and emoji newer than 15.1" do
    entries = [
      entry("1F600", ["grinning"], "Smileys & Emotion", 1),
      entry("1F3FB", ["skin-tone-2"], "Component", 2),
      entry("1FAE9", ["face_with_bags_under_eyes"], "Smileys & Emotion", 3, "16.0"),
      entry("1F426-200D-1F525", ["phoenix"], "Animals & Nature", 4, "15.1")
    ]

    assert %{"emoji" => [["😀", _, _], ["🐦‍🔥", ["phoenix"], _]]} = Emoji.compact(entries)
  end
end

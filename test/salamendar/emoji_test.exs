defmodule Salamendar.EmojiTest do
  use ExUnit.Case, async: true

  alias Salamendar.Emoji

  test "get/1 knows every one of an emoji's Slack names" do
    assert Emoji.get("+1") == "👍"
    assert Emoji.get("thumbsup") == "👍"
    assert Emoji.get("tada") == "🎉"
    assert Emoji.get("heart") == "❤️"
  end

  test "get/1 keeps the names of obsoleted entries, which Slack still takes" do
    assert Emoji.get("runner") == "🏃"
  end

  test "get/1 gives nil for unknown names and skin tones" do
    assert Emoji.get("not_an_emoji") == nil
    assert Emoji.get("skin-tone-2") == nil
    assert Emoji.get("") == nil
  end
end

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

  describe "replace_shortcodes/1" do
    test "replaces known names" do
      assert Emoji.replace_shortcodes("Party :tada:") == "Party 🎉"
      assert Emoji.replace_shortcodes(":+1: from :thumbsup:") == "👍 from 👍"
    end

    test "replaces names next to each other" do
      assert Emoji.replace_shortcodes(":tada::tada:") == "🎉🎉"
      assert Emoji.replace_shortcodes("x:tada:y") == "x🎉y"
    end

    test "starts fresh after an unknown name" do
      assert Emoji.replace_shortcodes(":not_an_emoji:tada:") == ":not_an_emoji🎉"
    end

    test "leaves everything else as typed" do
      for text <- [
            "10:30:00",
            ":not_an_emoji:",
            "a:b",
            ":tada",
            "tada:",
            ":",
            "::",
            "",
            "Re: notes",
            ":TADA:",
            ":wave::skin-tone-3:"
          ] do
        expected = String.replace(text, ":wave:", "👋")
        assert Emoji.replace_shortcodes(text) == expected
      end
    end

    test "passes nil through" do
      assert Emoji.replace_shortcodes(nil) == nil
    end
  end
end

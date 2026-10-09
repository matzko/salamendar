defmodule Salamendar.Bot.ChannelEventsTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  alias Salamendar.{Accounts, Bot, Channels}
  alias Salamendar.Channels.Channel
  alias Salamendar.Workers.DeleteCanvases

  @bot %Slack.Bot{
    id: "B1",
    module: Bot,
    token: "xoxb-test",
    team_id: "TCE1",
    user_id: "UBOT"
  }

  setup do
    {:ok, channel} = Channels.upsert_channel("TCE1", "C1", %{name: "general"})
    {:ok, channel} = Channels.enable_calendar(channel)
    {:ok, user} = Accounts.get_or_create_user("TCE1", "U1")
    %{channel: channel, user: user}
  end

  describe "member_joined_channel / member_left_channel" do
    test "track members of calendar channels", %{channel: channel, user: user} do
      Bot.handle_event(
        "member_joined_channel",
        %{
          "type" => "member_joined_channel",
          "user" => "U1",
          "channel" => "C1",
          "channel_type" => "C",
          "team" => "TCE1"
        },
        @bot
      )

      assert Channels.member?(channel, user)

      Bot.handle_event(
        "member_left_channel",
        %{
          "type" => "member_left_channel",
          "user" => "U1",
          "channel" => "C1",
          "channel_type" => "C",
          "team" => "TCE1"
        },
        @bot
      )

      refute Channels.member?(channel, user)
    end

    test "ignore the bot itself" do
      Bot.handle_event("member_joined_channel", %{"user" => "UBOT", "channel" => "C1"}, @bot)
      refute Repo.get_by(Salamendar.Accounts.User, slack_user_id: "UBOT")
    end

    test "ignore channels without the calendar", %{user: user} do
      {:ok, other} = Channels.upsert_channel("TCE1", "C2")
      Bot.handle_event("member_joined_channel", %{"user" => "U1", "channel" => "C2"}, @bot)
      Bot.handle_event("member_joined_channel", %{"user" => "U1", "channel" => "C-unknown"}, @bot)

      refute Channels.member?(other, user)
    end
  end

  for type <- ["channel_left", "group_left"] do
    test "#{type} (the bot was removed) disables the calendar", %{channel: channel, user: user} do
      :ok = Channels.add_member(channel, user)

      Bot.handle_event(
        unquote(type),
        %{"type" => unquote(type), "channel" => "C1", "actor_id" => "U1"},
        @bot
      )

      refute Repo.reload!(channel).calendar_enabled
      refute Channels.member?(channel, user)
      assert_enqueued(worker: DeleteCanvases, args: %{channel_id: channel.id})
    end
  end

  test "channel_left for a channel without the calendar does nothing" do
    Bot.handle_event("channel_left", %{"channel" => "C-unknown"}, @bot)
    refute_enqueued(worker: DeleteCanvases)
  end

  for prefix <- ["channel", "group"] do
    test "#{prefix} rename, archive, unarchive and delete", %{channel: channel} do
      Bot.handle_event(
        "#{unquote(prefix)}_rename",
        %{"channel" => %{"id" => "C1", "name" => "renamed", "created" => 1_700_000_000}},
        @bot
      )

      assert Repo.reload!(channel).name == "renamed"

      Bot.handle_event("#{unquote(prefix)}_archive", %{"channel" => "C1", "user" => "U1"}, @bot)
      assert %DateTime{} = Repo.reload!(channel).archived_at

      Bot.handle_event("#{unquote(prefix)}_unarchive", %{"channel" => "C1", "user" => "U1"}, @bot)
      assert is_nil(Repo.reload!(channel).archived_at)

      Bot.handle_event("#{unquote(prefix)}_deleted", %{"channel" => "C1"}, @bot)
      refute Repo.get(Channel, channel.id)
    end
  end
end

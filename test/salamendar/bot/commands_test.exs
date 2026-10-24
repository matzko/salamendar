defmodule Salamendar.Bot.CommandsTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Mox

  alias Salamendar.{Accounts, Bot, Channels}
  alias Salamendar.Calendar.Changes
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.ReconcileMembers
  alias SalamendarWeb.SignInLink

  setup :verify_on_exit!

  @bot %Slack.Bot{
    id: "B1",
    module: Bot,
    token: "xoxb-test",
    team_id: "TCM1",
    user_id: "UBOT"
  }

  @response_url "https://hooks.slack.com/commands/TCM1/1/abc"

  # A `/salamendar` payload as Socket Mode delivers it.
  defp command(text, attrs) do
    Map.merge(
      %{
        "command" => "/salamendar",
        "text" => text,
        "team_id" => "TCM1",
        "channel_id" => "C1",
        "channel_name" => "general",
        "user_id" => "U1",
        "user_name" => "ada",
        "trigger_id" => "trigger-1",
        "response_url" => @response_url
      },
      attrs
    )
  end

  defp run(text, attrs \\ %{}), do: Bot.handle_event("slash_commands", command(text, attrs), @bot)

  # Expects one ephemeral reply and sends its text to the test.
  defp expect_reply do
    test = self()

    expect(Mock, :respond, fn @response_url, %{response_type: "ephemeral", text: text} ->
      send(test, {:reply, text})
      :ok
    end)
  end

  defp enabled_channel! do
    {:ok, channel} = Channels.upsert_channel("TCM1", "C1", %{name: "general"})
    {:ok, channel} = Channels.enable_calendar(channel)
    channel
  end

  test "shows help without a subcommand" do
    expect_reply()
    run("")
    assert_received {:reply, text}
    assert text =~ "/salamendar enable"
  end

  describe "enable" do
    test "joins a public channel, enables it and replies with a link" do
      expect(Mock, :get, fn "conversations.info", %{channel: "C1"} ->
        {:ok,
         %{
           "ok" => true,
           "channel" => %{
             "id" => "C1",
             "name" => "general",
             "is_private" => false,
             "is_member" => false
           }
         }}
      end)

      # No other Slack calls (e.g. `canvases.create`): Mox fails on any.
      expect(Mock, :post, fn "conversations.join", %{channel: "C1"} -> {:ok, %{"ok" => true}} end)

      test = self()

      expect(Mock, :respond, fn @response_url, %{text: text, blocks: blocks} ->
        send(test, {:reply, text, blocks})
        :ok
      end)

      run("enable")

      assert_received {:reply, "The calendar is on" <> _,
                       [%{accessory: %{action_id: "open_calendar", url: url}}]}

      assert url =~ "return_to=%2F%3Fchannel%3DC1"

      channel = Channels.get_channel("TCM1", "C1")
      assert channel.calendar_enabled
      assert channel.name == "general"
      assert_enqueued(worker: ReconcileMembers, args: %{channel_id: channel.id})
    end

    test "asks to be invited to a private channel it can't see" do
      expect(Mock, :get, fn "conversations.info", _ -> {:error, "channel_not_found"} end)
      expect_reply()

      run("enable")

      assert_received {:reply, text}
      assert text =~ "/invite @Salamendar"
      refute Channels.get_channel("TCM1", "C1")
    end

    test "points DMs to a channel" do
      expect_reply()
      run("enable", %{"channel_id" => "D1"})
      assert_received {:reply, "Run `/salamendar enable` in the channel" <> _}
    end
  end

  describe "disable" do
    test "disables the calendar" do
      channel = enabled_channel!()
      {:ok, user} = Accounts.get_or_create_user("TCM1", "U9")
      :ok = Channels.add_member(channel, user)
      :ok = Changes.subscribe(user)
      expect_reply()

      run("disable")

      assert_received {:reply, "The calendar is off" <> _}
      refute Repo.reload!(channel).calendar_enabled
      assert_receive :calendar_changed
    end

    test "says so when the calendar isn't on" do
      expect_reply()
      run("disable")
      assert_received {:reply, "The calendar isn't on in this channel."}
    end
  end

  describe "week-start" do
    test "accepts day names and abbreviations" do
      channel = enabled_channel!()

      for {day, index, name} <- [
            {"Monday", 1, "Monday"},
            {"sat", 6, "Saturday"},
            {"su", 0, "Sunday"}
          ] do
        expect_reply()
        run("week-start #{day}")
        assert_received {:reply, text}
        assert text == "This channel's calendar now starts weeks on *#{name}*."
        assert Repo.reload!(channel).week_start == index
      end
    end

    test "rejects other words" do
      enabled_channel!()

      for day <- ["funday", "s", "t"] do
        expect_reply()
        run("week-start #{day}")
        assert_received {:reply, "`" <> _}
      end
    end
  end

  test "new opens the event form" do
    expect(Mock, :post, fn "views.open", %{trigger_id: "trigger-1", view: %{type: "modal"}} ->
      {:ok, %{"ok" => true}}
    end)

    run("new")
  end

  describe "open" do
    # Expects an ephemeral reply with a link button, and returns its URL's
    # query.
    defp open_link(attrs) do
      test = self()

      expect(Mock, :respond, fn @response_url, %{response_type: "ephemeral", blocks: blocks} ->
        send(test, {:blocks, blocks})
        :ok
      end)

      run("open", attrs)

      assert_received {:blocks, [%{accessory: %{action_id: "open_calendar", url: url}}]}
      assert "http://localhost:4000/auth/slack?" <> query = url
      URI.decode_query(query)
    end

    test "replies with a sign-in link focused on the channel" do
      query = open_link(%{})

      user =
        Salamendar.Repo.get_by!(Salamendar.Accounts.User,
          slack_team_id: "TCM1",
          slack_user_id: "U1"
        )

      assert SignInLink.verify(query["token"]) == {:ok, user.id}
      assert query["return_to"] == "/?channel=C1"
    end

    test "doesn't focus a direct message" do
      query = open_link(%{"channel_id" => "D1"})
      refute Map.has_key?(query, "return_to")
    end
  end
end

defmodule Salamendar.Bot.CommandsTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Mox

  alias Salamendar.{Bot, Channels}
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.{DeleteCanvases, ReconcileMembers, SyncCanvas}

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
    test "joins a public channel, enables it and creates its canvas" do
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

      expect(Mock, :post, fn "conversations.join", %{channel: "C1"} -> {:ok, %{"ok" => true}} end)

      expect(Mock, :post, fn "canvases.create", %{channel_id: "C1", title: "Calendar"} ->
        {:ok, %{"ok" => true, "canvas_id" => "F1"}}
      end)

      expect_reply()
      run("enable")

      assert_received {:reply, text}
      assert text =~ "The calendar is on"

      channel = Channels.get_channel("TCM1", "C1")
      assert channel.calendar_enabled
      assert channel.name == "general"
      assert [%{slack_canvas_id: "F1"}] = Channels.list_canvases(channel)
      assert_enqueued(worker: ReconcileMembers, args: %{channel_id: channel.id})
      assert_enqueued(worker: SyncCanvas, args: %{channel_id: channel.id, kind: "month"})
    end

    test "reuses an existing canvas" do
      channel = enabled_channel!()
      {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)
      {:ok, _} = Channels.set_canvas_slack_id(canvas, "F1")

      expect(Mock, :get, fn "conversations.info", _ ->
        {:ok, %{"channel" => %{"id" => "C1", "name" => "general", "is_member" => true}}}
      end)

      expect_reply()
      run("enable")
      assert_received {:reply, "The calendar is on" <> _}
    end

    test "asks to be invited to a private channel it can't see" do
      expect(Mock, :get, fn "conversations.info", _ -> {:error, "channel_not_found"} end)
      expect_reply()

      run("enable")

      assert_received {:reply, text}
      assert text =~ "/invite @Salamendar"
      refute Channels.get_channel("TCM1", "C1")
    end

    test "explains a canvas tab that's already there" do
      expect(Mock, :get, fn "conversations.info", _ ->
        {:ok, %{"channel" => %{"id" => "C1", "name" => "general", "is_member" => true}}}
      end)

      expect(Mock, :post, fn "canvases.create", _ ->
        {:error, "free_team_canvas_tab_already_exists"}
      end)

      expect_reply()
      run("enable")

      assert_received {:reply, text}
      assert text =~ "already has a canvas tab"

      # Enabled, so running it again retries the canvas.
      channel = Channels.get_channel("TCM1", "C1")
      assert channel.calendar_enabled
      assert [%{slack_canvas_id: nil}] = Channels.list_canvases(channel)
      refute_enqueued(worker: SyncCanvas)
    end

    test "points DMs to a channel" do
      expect_reply()
      run("enable", %{"channel_id" => "D1"})
      assert_received {:reply, "Run `/salamendar enable` in the channel" <> _}
    end
  end

  describe "disable" do
    test "disables the calendar and schedules the canvas deletion" do
      channel = enabled_channel!()
      {:ok, _} = SyncCanvas.enqueue(channel.id)
      expect_reply()

      run("disable")

      assert_received {:reply, "The calendar is off" <> _}
      refute Repo.reload!(channel).calendar_enabled
      assert_enqueued(worker: DeleteCanvases, args: %{channel_id: channel.id})
      refute_enqueued(worker: SyncCanvas)
    end

    test "says so when the calendar isn't on" do
      expect_reply()
      run("disable")
      assert_received {:reply, "The calendar isn't on in this channel."}
    end
  end

  describe "tz" do
    test "shows and sets the time zone" do
      channel = enabled_channel!()

      expect_reply()
      run("tz")
      assert_received {:reply, "This channel's calendar uses *America/Chicago*."}

      expect_reply()
      run("tz Europe/London")
      assert_received {:reply, "This channel's calendar now uses *Europe/London*."}
      assert Repo.reload!(channel).time_zone == "Europe/London"
      assert_enqueued(worker: SyncCanvas, args: %{channel_id: channel.id})
    end

    test "rejects unknown zones" do
      channel = enabled_channel!()
      expect_reply()

      run("tz Mars/Olympus")

      assert_received {:reply, "`Mars/Olympus` isn't a time zone I know." <> _}
      assert is_nil(Repo.reload!(channel).time_zone)
    end

    test "needs the calendar on" do
      expect_reply()
      run("tz UTC")
      assert_received {:reply, "The calendar isn't on in this channel." <> _}
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
end

defmodule Salamendar.Bot.HomeTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Mox

  alias Salamendar.{Accounts, Bot, Calendar, Channels}
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.PublishHome

  setup :verify_on_exit!

  @bot %Slack.Bot{
    id: "B1",
    module: Bot,
    token: "xoxb-test",
    team_id: "THO1",
    user_id: "UBOT"
  }

  defp home_opened(user_id \\ "U1", tab \\ "home") do
    Bot.handle_event(
      "app_home_opened",
      %{"type" => "app_home_opened", "user" => user_id, "channel" => "D1", "tab" => tab},
      @bot
    )
  end

  # A users.info answer for U1.
  defp expect_users_info(time_zone) do
    expect(Mock, :get, fn "users.info", %{user: "U1"} ->
      {:ok,
       %{
         "ok" => true,
         "user" => %{
           "id" => "U1",
           "name" => "ada",
           "real_name" => "Ada Lovelace",
           "tz" => time_zone,
           "profile" => %{"display_name" => ""}
         }
       }}
    end)
  end

  defp expect_publish do
    test = self()

    expect(Mock, :post, fn "views.publish",
                           %{user_id: "U1", view: %{type: "home", blocks: blocks}} ->
      send(test, {:blocks, blocks})
      {:ok, %{"ok" => true}}
    end)
  end

  test "refreshes a stale profile, then publishes today's events" do
    {:ok, user} = Accounts.get_or_create_user("THO1", "U1")
    {:ok, channel} = Channels.upsert_channel("THO1", "C1")
    {:ok, channel} = Channels.enable_calendar(channel)
    :ok = Channels.add_member(channel, user)

    # Yesterday to tomorrow, so it's on today's Home tab whatever the time.
    today = Date.utc_today()

    {:ok, _, _} =
      Calendar.create_event(
        user,
        %{
          title: "Offsite",
          time_zone: "Etc/UTC",
          all_day: true,
          start_date: Date.add(today, -1),
          end_date: Date.add(today, 2)
        },
        [channel]
      )

    expect_users_info("Etc/UTC")
    expect_publish()

    home_opened()

    assert_received {:blocks, blocks}
    assert Enum.any?(blocks, &match?(%{type: "section", text: %{text: "*Offsite*" <> _}}, &1))

    user = Repo.reload!(user)
    assert user.name == "Ada Lovelace"
    assert user.time_zone == "Etc/UTC"
    assert %DateTime{} = user.profile_synced_at
  end

  test "skips users.info for a fresh profile" do
    {:ok, _} = Accounts.get_or_create_user("THO1", "U1", %{profile_synced_at: DateTime.utc_now()})
    expect_publish()

    home_opened()
    assert_received {:blocks, _}
  end

  @tag :capture_log
  test "still publishes when users.info fails" do
    expect(Mock, :get, fn "users.info", _ -> {:error, "user_not_found"} end)
    expect_publish()

    home_opened()

    assert_received {:blocks, blocks}
    assert Enum.any?(blocks, &match?(%{text: %{text: "Nothing on your calendar today" <> _}}, &1))
  end

  test "ignores the Messages tab" do
    home_opened("U1", "messages")
  end

  test "PublishHome republishes from a job" do
    {:ok, _} = Accounts.get_or_create_user("THO1", "U1", %{profile_synced_at: DateTime.utc_now()})
    expect_publish()

    assert :ok = perform_job(PublishHome, %{team_id: "THO1", slack_user_id: "U1"})
  end

  test "PublishHome snoozes when rate limited" do
    {:ok, _} = Accounts.get_or_create_user("THO1", "U1", %{profile_synced_at: DateTime.utc_now()})
    expect(Mock, :post, fn "views.publish", _ -> {:error, :ratelimited, 4} end)

    assert {:snooze, 4} = perform_job(PublishHome, %{team_id: "THO1", slack_user_id: "U1"})
  end
end

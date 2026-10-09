defmodule Salamendar.ChannelsTest do
  use Salamendar.DataCase, async: true

  import Ecto.Query

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels
  alias Salamendar.Channels.{Canvas, Channel, Membership}

  defp channel!(slack_channel_id \\ "C1", attrs \\ %{}) do
    {:ok, channel} = Channels.upsert_channel("T1", slack_channel_id, attrs)
    channel
  end

  defp enabled_channel!(slack_channel_id \\ "C1") do
    {:ok, channel} = Channels.enable_calendar(channel!(slack_channel_id))
    channel
  end

  defp user!(slack_user_id, attrs \\ %{}) do
    {:ok, user} = Accounts.get_or_create_user("T1", slack_user_id, attrs)
    user
  end

  defp member_slack_ids(channel) do
    Repo.all(
      from(m in Membership,
        join: u in assoc(m, :user),
        where: m.channel_id == ^channel.id,
        order_by: u.slack_user_id,
        select: u.slack_user_id
      )
    )
  end

  describe "upsert_channel/3" do
    test "creates a channel with default settings" do
      assert {:ok, %Channel{} = channel} =
               Channels.upsert_channel("T1", "C1", %{name: "general", is_private: true})

      assert channel.slack_team_id == "T1"
      assert channel.slack_channel_id == "C1"
      assert channel.name == "general"
      assert channel.is_private
      refute channel.calendar_enabled
    end

    test "returns the existing channel and updates the given attributes" do
      original = channel!("C1", %{name: "general", is_private: true})
      {:ok, updated} = Channels.upsert_channel("T1", "C1", %{is_private: false})

      assert updated.id == original.id
      # Omitted attributes are kept; `false` overwrites `true` even though
      # it is the column default.
      assert updated.name == "general"
      refute updated.is_private
      assert Repo.aggregate(Channel, :count) == 1
    end

    test "doesn't touch calendar settings" do
      {:ok, _} = Channels.enable_calendar(channel!())

      {:ok, channel} =
        Channels.upsert_channel("T1", "C1", %{calendar_enabled: false, week_start: 3})

      assert channel.calendar_enabled
      assert channel.week_start == 0
    end
  end

  describe "enable_calendar/1 and disable_calendar/1" do
    test "disabling deletes memberships but keeps events and their channels" do
      channel = enabled_channel!()
      other = enabled_channel!("C2")
      user = user!("U1")
      :ok = Channels.add_member(channel, user)
      :ok = Channels.add_member(other, user)
      {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)

      event =
        %Event{slack_team_id: "T1", owner_id: user.id}
        |> Event.changeset(%{
          title: "Standup",
          time_zone: "America/Chicago",
          starts_at: ~U[2026-10-10 14:00:00.000000Z],
          ends_at: ~U[2026-10-10 14:15:00.000000Z]
        })
        |> put_assoc(:channels, [channel])
        |> Repo.insert!()

      assert {:ok, channel, [returned]} = Channels.disable_calendar(channel)

      refute channel.calendar_enabled
      assert returned.id == canvas.id
      refute Channels.member?(channel, user)
      assert Channels.member?(other, user)
      assert Repo.get(Event, event.id)
      assert Repo.aggregate("event_channels", :count) == 1
    end

    test "enabling again keeps the channel's settings" do
      channel = enabled_channel!()
      {:ok, channel} = channel |> Channel.changeset(%{week_start: 1}) |> Repo.update()
      {:ok, channel, []} = Channels.disable_calendar(channel)

      {:ok, channel} = Channels.enable_calendar(channel)
      assert channel.calendar_enabled
      assert channel.week_start == 1
    end
  end

  describe "channel lifecycle" do
    test "archive, unarchive and rename" do
      channel = channel!("C1", %{name: "general"})

      {:ok, channel} = Channels.archive_channel(channel)
      assert %DateTime{} = channel.archived_at

      {:ok, channel} = Channels.unarchive_channel(channel)
      assert is_nil(channel.archived_at)

      {:ok, channel} = Channels.rename_channel(channel, "random")
      assert Repo.reload!(channel).name == "random"
    end
  end

  describe "time_zone/1" do
    test "uses the channel's zone, or the configured default" do
      assert Channels.time_zone(%Channel{time_zone: "Asia/Kolkata"}) == "Asia/Kolkata"

      assert Channels.time_zone(%Channel{}) ==
               Application.fetch_env!(:salamendar, :default_time_zone)
    end
  end

  describe "add_member/2, remove_member/2 and member?/2" do
    test "are idempotent" do
      channel = enabled_channel!()
      user = user!("U1")

      refute Channels.member?(channel, user)
      assert :ok = Channels.add_member(channel, user)
      assert :ok = Channels.add_member(channel, user)
      assert Channels.member?(channel, user)
      assert Repo.aggregate(Membership, :count) == 1

      assert :ok = Channels.remove_member(channel, user)
      assert :ok = Channels.remove_member(channel, user)
      refute Channels.member?(channel, user)
    end
  end

  describe "replace_members/2" do
    test "creates stub users for unknown Slack IDs" do
      channel = enabled_channel!()
      known = user!("U1", %{name: "Ada", time_zone: "Europe/London"})

      assert {:ok, %{added: 2, removed: 0}} = Channels.replace_members(channel, ["U1", "U2"])

      assert member_slack_ids(channel) == ["U1", "U2"]
      # The existing user is reused, not overwritten.
      assert %User{name: "Ada", time_zone: "Europe/London"} = Repo.reload!(known)

      stub = Repo.get_by!(User, slack_team_id: "T1", slack_user_id: "U2")
      assert is_nil(stub.name)
      assert is_nil(stub.time_zone)
      assert {:ok, <<_::48, 7::4, _::76>>} = Ecto.UUID.dump(stub.id)
    end

    test "is idempotent and ignores duplicate IDs" do
      channel = enabled_channel!()

      {:ok, _} = Channels.replace_members(channel, ["U1", "U2", "U1"])
      assert {:ok, %{added: 0, removed: 0}} = Channels.replace_members(channel, ["U2", "U1"])

      assert member_slack_ids(channel) == ["U1", "U2"]
      assert Repo.aggregate(User, :count) == 2
    end

    test "removes people who left, and only from this channel" do
      channel = enabled_channel!()
      other = enabled_channel!("C2")
      {:ok, _} = Channels.replace_members(channel, ["U1", "U2"])
      {:ok, _} = Channels.replace_members(other, ["U1", "U2"])

      assert {:ok, %{added: 1, removed: 1}} = Channels.replace_members(channel, ["U1", "U3"])
      assert member_slack_ids(channel) == ["U1", "U3"]
      assert member_slack_ids(other) == ["U1", "U2"]

      # The user who left still exists.
      assert Repo.get_by(User, slack_team_id: "T1", slack_user_id: "U2")

      assert {:ok, %{added: 0, removed: 2}} = Channels.replace_members(channel, [])
      assert member_slack_ids(channel) == []
    end

    test "keeps users of other workspaces apart" do
      {:ok, channel} = Channels.upsert_channel("T2", "C1")
      {:ok, _} = Accounts.get_or_create_user("T1", "U1")

      {:ok, %{added: 1}} = Channels.replace_members(channel, ["U1"])

      assert Repo.get_by(User, slack_team_id: "T2", slack_user_id: "U1")
      assert Repo.aggregate(User, :count) == 2
    end
  end

  describe "list_enabled_channels/0" do
    test "excludes disabled and archived channels" do
      enabled = enabled_channel!("C1")
      _disabled = channel!("C2")
      {:ok, _archived} = Channels.archive_channel(enabled_channel!("C3"))

      assert [%Channel{id: id}] = Channels.list_enabled_channels()
      assert id == enabled.id
    end
  end

  describe "get_or_create_canvas/2 and mark_canvas_rendered/3" do
    test "returns the same row on repeated calls" do
      channel = enabled_channel!()

      assert {:ok, %Canvas{kind: :month, slack_canvas_id: nil} = canvas} =
               Channels.get_or_create_canvas(channel, :month)

      assert {:ok, again} = Channels.get_or_create_canvas(channel, :month)
      assert again.id == canvas.id
      assert Repo.aggregate(Canvas, :count) == 1
    end

    test "keeps existing render state" do
      channel = enabled_channel!()
      {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)
      {:ok, _} = Channels.mark_canvas_rendered(canvas, "2026-10-01", "abc")

      assert {:ok, %Canvas{rendered_period: "2026-10-01"}} =
               Channels.get_or_create_canvas(channel, :month)
    end

    test "mark_canvas_rendered/3 records the period, hash and time" do
      {:ok, canvas} = Channels.get_or_create_canvas(enabled_channel!(), :month)

      assert {:ok, canvas} = Channels.mark_canvas_rendered(canvas, "2026-10-01", "abc")
      assert canvas.rendered_period == "2026-10-01"
      assert canvas.content_hash == "abc"
      assert %DateTime{} = canvas.rendered_at
    end
  end
end

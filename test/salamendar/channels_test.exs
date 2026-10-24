defmodule Salamendar.ChannelsTest do
  use Salamendar.DataCase, async: true

  import Ecto.Query

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels
  alias Salamendar.Channels.{Channel, Membership}

  defp channel!(slack_channel_id \\ "C1", attrs \\ %{}) do
    {:ok, channel} = Channels.upsert_channel("TCH1", slack_channel_id, attrs)
    channel
  end

  defp enabled_channel!(slack_channel_id \\ "C1") do
    {:ok, channel} = Channels.enable_calendar(channel!(slack_channel_id))
    channel
  end

  defp user!(slack_user_id, attrs \\ %{}) do
    {:ok, user} = Accounts.get_or_create_user("TCH1", slack_user_id, attrs)
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
               Channels.upsert_channel("TCH1", "C1", %{name: "general", is_private: true})

      assert channel.slack_team_id == "TCH1"
      assert channel.slack_channel_id == "C1"
      assert channel.name == "general"
      assert channel.is_private
      refute channel.calendar_enabled
    end

    test "returns the existing channel and updates the given attributes" do
      original = channel!("C1", %{name: "general", is_private: true})
      {:ok, updated} = Channels.upsert_channel("TCH1", "C1", %{is_private: false})

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
        Channels.upsert_channel("TCH1", "C1", %{calendar_enabled: false, week_start: 3})

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

      event =
        %Event{slack_team_id: "TCH1", owner_id: user.id}
        |> Event.changeset(%{
          title: "Standup",
          time_zone: "America/Chicago",
          starts_at: ~U[2026-10-10 14:00:00.000000Z],
          ends_at: ~U[2026-10-10 14:15:00.000000Z]
        })
        |> put_assoc(:channels, [channel])
        |> Repo.insert!()

      assert {:ok, channel} = Channels.disable_calendar(channel)

      refute channel.calendar_enabled
      refute Channels.member?(channel, user)
      assert Channels.member?(other, user)
      assert Repo.get(Event, event.id)
      assert Repo.aggregate("event_channels", :count) == 1
    end

    test "enabling again keeps the channel's settings" do
      channel = enabled_channel!()
      {:ok, channel} = channel |> Channel.changeset(%{week_start: 1}) |> Repo.update()
      {:ok, channel} = Channels.disable_calendar(channel)

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

      stub = Repo.get_by!(User, slack_team_id: "TCH1", slack_user_id: "U2")
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
      assert Repo.get_by(User, slack_team_id: "TCH1", slack_user_id: "U2")

      assert {:ok, %{added: 0, removed: 2}} = Channels.replace_members(channel, [])
      assert member_slack_ids(channel) == []
    end

    test "keeps users of other workspaces apart" do
      {:ok, channel} = Channels.upsert_channel("TCH2", "C1")
      {:ok, _} = Accounts.get_or_create_user("TCH1", "U1")

      {:ok, %{added: 1}} = Channels.replace_members(channel, ["U1"])

      assert Repo.get_by(User, slack_team_id: "TCH2", slack_user_id: "U1")
      assert Repo.aggregate(User, :count) == 2
    end
  end

  describe "list_picker_channels/2" do
    test "puts the current channels first, then the user's calendar channels, once each" do
      user = user!("U1")
      general = enabled_channel!("C1")
      random = enabled_channel!("C2")
      {:ok, old} = Channels.disable_calendar(enabled_channel!("C3"))
      :ok = Channels.add_member(general, user)
      :ok = Channels.add_member(random, user)

      ids = fn channels -> Enum.map(channels, & &1.id) end

      assert Enum.sort(ids.(Channels.list_picker_channels(user))) ==
               Enum.sort([general.id, random.id])

      assert [first | rest] = Channels.list_picker_channels(user, [old, random])
      assert first.id == old.id
      assert Enum.sort(ids.(rest)) == Enum.sort([general.id, random.id])
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
end

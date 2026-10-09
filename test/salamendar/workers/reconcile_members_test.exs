defmodule Salamendar.Workers.ReconcileMembersTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Ecto.Query
  import Mox

  alias Salamendar.Channels
  alias Salamendar.Channels.Membership
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.ReconcileMembers

  setup :verify_on_exit!

  defp enabled_channel!(slack_channel_id) do
    {:ok, channel} = Channels.upsert_channel("TRM1", slack_channel_id)
    {:ok, channel} = Channels.enable_calendar(channel)
    channel
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

  test "the cron run enqueues one job per enabled channel" do
    a = enabled_channel!("C1")
    b = enabled_channel!("C2")
    {:ok, _, _} = Channels.disable_calendar(enabled_channel!("C3"))

    assert :ok = perform_job(ReconcileMembers, %{})

    ids = for job <- all_enqueued(worker: ReconcileMembers), do: job.args["channel_id"]
    assert Enum.sort(ids) == Enum.sort([a.id, b.id])
  end

  test "replaces a channel's members with Slack's, leaving out the bot" do
    channel = enabled_channel!("C1")
    {:ok, _} = Channels.replace_members(channel, ["U0"])

    expect(Mock, :post, fn "auth.test", %{} -> {:ok, %{"ok" => true, "user_id" => "UBOT"}} end)

    expect(Mock, :stream, fn "conversations.members", %{channel: "C1"}, "members" ->
      ["U2", "UBOT", "U1"]
    end)

    assert :ok = perform_job(ReconcileMembers, %{channel_id: channel.id})
    assert member_slack_ids(channel) == ["U1", "U2"]
  end

  test "does nothing for disabled channels" do
    {:ok, channel, _} = Channels.disable_calendar(enabled_channel!("C1"))
    assert :ok = perform_job(ReconcileMembers, %{channel_id: channel.id})
  end

  test "snoozes when rate limited" do
    channel = enabled_channel!("C1")
    expect(Mock, :post, fn "auth.test", _ -> {:error, :ratelimited, 9} end)

    assert {:snooze, 9} = perform_job(ReconcileMembers, %{channel_id: channel.id})
  end

  test "enqueue/1 doesn't duplicate a pending job" do
    channel = enabled_channel!("C1")
    {:ok, _} = ReconcileMembers.enqueue(channel.id)
    {:ok, _} = ReconcileMembers.enqueue(channel.id)

    assert length(all_enqueued(worker: ReconcileMembers)) == 1
  end
end

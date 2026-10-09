defmodule Salamendar.Workers.RolloverTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  alias Salamendar.Channels
  alias Salamendar.Workers.{Rollover, SyncCanvas}

  defp channel_with_canvas!(slack_channel_id, slack_canvas_id) do
    {:ok, channel} = Channels.upsert_channel("TRO1", slack_channel_id)
    {:ok, channel} = Channels.enable_calendar(channel)
    {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)
    {:ok, _} = Channels.set_canvas_slack_id(canvas, slack_canvas_id)
    channel
  end

  test "enqueues a sync for every enabled channel's canvas in Slack" do
    live = channel_with_canvas!("C1", "F1")
    _no_canvas = channel_with_canvas!("C2", nil)
    {:ok, _, _} = Channels.disable_calendar(channel_with_canvas!("C3", "F3"))
    {:ok, _} = Channels.archive_channel(channel_with_canvas!("C4", "F4"))

    assert :ok = perform_job(Rollover, %{})

    assert [%{args: %{"channel_id" => channel_id, "kind" => "month"}}] =
             all_enqueued(worker: SyncCanvas)

    assert channel_id == live.id
  end

  test "doesn't pile up syncs across runs" do
    channel_with_canvas!("C1", "F1")

    assert :ok = perform_job(Rollover, %{})
    assert :ok = perform_job(Rollover, %{})

    assert length(all_enqueued(worker: SyncCanvas)) == 1
  end
end

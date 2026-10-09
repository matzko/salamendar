defmodule Salamendar.Workers.DeleteCanvasesTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Mox

  alias Salamendar.Channels
  alias Salamendar.Channels.Canvas
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.{DeleteCanvases, SyncCanvas}

  setup :verify_on_exit!

  setup do
    {:ok, channel} = Channels.upsert_channel("TDC1", "C1")
    {:ok, channel} = Channels.enable_calendar(channel)
    {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)
    {:ok, canvas} = Channels.set_canvas_slack_id(canvas, "F1")
    {:ok, channel, _} = Channels.disable_calendar(channel)

    %{channel: channel, canvas: canvas}
  end

  defp perform(channel), do: perform_job(DeleteCanvases, %{channel_id: channel.id})

  test "deletes the canvas in Slack, then its row", %{channel: channel} do
    expect(Mock, :post, fn "canvases.delete", %{canvas_id: "F1"} -> {:ok, %{"ok" => true}} end)

    assert :ok = perform(channel)
    assert Repo.aggregate(Canvas, :count) == 0
  end

  test "treats a canvas that's already gone as deleted", %{channel: channel} do
    expect(Mock, :post, fn "canvases.delete", _ -> {:error, "canvas_not_found"} end)

    assert :ok = perform(channel)
    assert Repo.aggregate(Canvas, :count) == 0
  end

  test "deletes rows that never got a canvas without calling Slack",
       %{channel: channel, canvas: canvas} do
    {:ok, _} = Channels.set_canvas_slack_id(canvas, nil)

    assert :ok = perform(channel)
    assert Repo.aggregate(Canvas, :count) == 0
  end

  test "keeps the canvas if the calendar was enabled again", %{channel: channel} do
    {:ok, channel} = Channels.enable_calendar(channel)

    assert :ok = perform(channel)
    assert Repo.aggregate(Canvas, :count) == 1
  end

  test "keeps the row to retry on errors", %{channel: channel} do
    expect(Mock, :post, fn "canvases.delete", _ -> {:error, :ratelimited, 5} end)
    expect(Mock, :post, fn "canvases.delete", _ -> {:error, "internal_error"} end)

    assert {:snooze, 5} = perform(channel)
    assert {:error, "internal_error"} = perform(channel)
    assert Repo.aggregate(Canvas, :count) == 1
  end

  test "does nothing for a deleted channel", %{channel: channel} do
    Repo.delete!(channel)
    assert :ok = perform(channel)
  end

  test "enqueue/1 cancels pending canvas rewrites", %{channel: channel} do
    {:ok, _} = SyncCanvas.enqueue(channel.id)
    {:ok, _} = DeleteCanvases.enqueue(channel.id)

    refute_enqueued(worker: SyncCanvas)
    assert_enqueued(worker: DeleteCanvases, args: %{channel_id: channel.id})
  end
end

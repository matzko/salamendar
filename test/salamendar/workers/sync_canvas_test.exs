defmodule Salamendar.Workers.SyncCanvasTest do
  use Salamendar.DataCase, async: true
  use Oban.Testing, repo: Salamendar.Repo

  import Ecto.Query
  import Mox

  alias Salamendar.{Accounts, Calendar, Channels}
  alias Salamendar.Render.Period
  alias Salamendar.SlackAPI.Mock
  alias Salamendar.Workers.SyncCanvas

  setup :verify_on_exit!

  setup do
    {:ok, owner} = Accounts.get_or_create_user("TSC1", "U1")
    {:ok, channel} = Channels.upsert_channel("TSC1", "C1")
    {:ok, channel} = Channels.enable_calendar(channel)
    {:ok, canvas} = Channels.get_or_create_canvas(channel, :month)
    {:ok, canvas} = Channels.set_canvas_slack_id(canvas, "F1")

    starts_at = DateTime.add(DateTime.utc_now(), 3600)

    {:ok, _, _} =
      Calendar.create_event(
        owner,
        %{
          title: "Standup",
          time_zone: "Etc/UTC",
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 900)
        },
        [channel]
      )

    %{channel: channel, canvas: canvas}
  end

  defp perform(channel, kind \\ "month"),
    do: perform_job(SyncCanvas, %{channel_id: channel.id, kind: kind})

  describe "perform/1" do
    test "replaces the canvas content and records the render",
         %{channel: channel, canvas: canvas} do
      expect(Mock, :post, fn "canvases.edit", %{canvas_id: "F1", changes: [change]} ->
        assert %{operation: "replace", document_content: %{type: "markdown", markdown: markdown}} =
                 change

        assert markdown =~ "Standup"
        {:ok, %{"ok" => true}}
      end)

      assert :ok = perform(channel)

      canvas = Repo.reload!(canvas)
      month = Period.current_month(Channels.time_zone(channel))
      assert canvas.rendered_period == Period.key(month)
      assert canvas.content_hash =~ ~r/^[0-9a-f]{64}$/
      assert %DateTime{} = canvas.rendered_at
    end

    test "skips the edit when nothing changed", %{channel: channel} do
      expect(Mock, :post, 1, fn "canvases.edit", _ -> {:ok, %{"ok" => true}} end)

      assert :ok = perform(channel)
      # A second call to the mock would fail the test.
      assert :ok = perform(channel)
    end

    test "edits again when the period changed", %{channel: channel, canvas: canvas} do
      expect(Mock, :post, 2, fn "canvases.edit", _ -> {:ok, %{"ok" => true}} end)

      assert :ok = perform(channel)
      {:ok, _} = Channels.mark_canvas_rendered(Repo.reload!(canvas), "2000-01-01", "old")
      assert :ok = perform(channel)
    end

    test "clears the ID when the canvas is gone", %{channel: channel, canvas: canvas} do
      expect(Mock, :post, fn "canvases.edit", _ -> {:error, "canvas_not_found"} end)

      assert :ok = perform(channel)
      assert Repo.reload!(canvas).slack_canvas_id == nil
    end

    test "makes no Slack calls without a canvas ID", %{channel: channel, canvas: canvas} do
      {:ok, _} = Channels.set_canvas_slack_id(canvas, nil)
      assert :ok = perform(channel)
    end

    test "makes no Slack calls for disabled or archived channels", %{channel: channel} do
      {:ok, archived} = Channels.archive_channel(channel)
      assert :ok = perform(archived)

      {:ok, _} = Channels.unarchive_channel(archived)
      {:ok, disabled, _} = Channels.disable_calendar(Repo.reload!(channel))
      assert :ok = perform(disabled)
    end

    test "snoozes when rate limited", %{channel: channel, canvas: canvas} do
      expect(Mock, :post, fn "canvases.edit", _ -> {:error, :ratelimited, 12} end)

      assert {:snooze, 12} = perform(channel)
      assert Repo.reload!(canvas).content_hash == nil
    end

    test "fails the attempt on other errors", %{channel: channel} do
      expect(Mock, :post, fn "canvases.edit", _ -> {:error, "internal_error"} end)
      assert {:error, "internal_error"} = perform(channel)
    end

    test "cancels kinds it can't render", %{channel: channel} do
      assert {:cancel, _} = perform(channel, "week")
    end
  end

  describe "enqueue/2" do
    test "debounces a burst of changes into one scheduled job", %{channel: channel} do
      for _ <- 1..3, do: {:ok, _} = SyncCanvas.enqueue(channel.id)

      assert [job] = all_enqueued(worker: SyncCanvas)
      assert job.args == %{"channel_id" => channel.id, "kind" => "month"}
      assert job.state == "scheduled"
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "a running job doesn't block a new one", %{channel: channel} do
      {:ok, job} = SyncCanvas.enqueue(channel.id)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      {:ok, _} = SyncCanvas.enqueue(channel.id)
      assert length(all_enqueued(worker: SyncCanvas)) == 1
      assert Repo.aggregate(Oban.Job, :count) == 2
    end

    test "keeps channels apart", %{channel: channel} do
      {:ok, other} = Channels.upsert_channel("TSC1", "C2")
      {:ok, _} = SyncCanvas.enqueue(channel.id)
      {:ok, _} = SyncCanvas.enqueue(other.id)

      assert length(all_enqueued(worker: SyncCanvas)) == 2
    end
  end

  describe "cancel_pending/1" do
    test "cancels only this channel's pending jobs", %{channel: channel} do
      {:ok, other} = Channels.upsert_channel("TSC1", "C2")
      {:ok, _} = SyncCanvas.enqueue(channel.id)
      {:ok, _} = SyncCanvas.enqueue(other.id)

      assert {:ok, 1} = SyncCanvas.cancel_pending(channel.id)
      assert [%{args: %{"channel_id" => other_id}}] = all_enqueued(worker: SyncCanvas)
      assert other_id == other.id
    end
  end
end

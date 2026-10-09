defmodule Salamendar.Workers.ReconcileMembers do
  @moduledoc """
  Makes the local copy of channel membership match Slack, repairing any
  `member_joined_channel`/`member_left_channel` events missed while the bot
  was down.

  Without a `channel_id` (the nightly Oban cron run) it enqueues one job per
  enabled channel, so one failing channel doesn't redo the others. With a
  `channel_id` (also used to backfill on `/salamendar enable`) it reconciles
  that channel.
  """

  use Oban.Worker,
    max_attempts: 5,
    unique: [keys: [:channel_id], states: :incomplete, period: :infinity]

  require Logger

  alias Salamendar.{Channels, Repo, SlackAPI}
  alias Salamendar.Channels.Channel

  @doc """
  Schedules a reconcile of `channel_id`.
  """
  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(channel_id), do: %{channel_id: channel_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id}}) do
    case Repo.get(Channel, channel_id) do
      %Channel{calendar_enabled: true, archived_at: nil} = channel -> reconcile(channel)
      _ -> :ok
    end
  end

  def perform(%Oban.Job{}) do
    for channel <- Channels.list_enabled_channels(), do: {:ok, _} = enqueue(channel.id)
    :ok
  end

  defp reconcile(channel) do
    # The bot is a member of every calendar channel; it isn't a user.
    case SlackAPI.post("auth.test", %{}) do
      {:ok, %{"user_id" => bot_user_id}} ->
        # Streams every page; raises (and so retries the job) if a page fails.
        slack_user_ids =
          "conversations.members"
          |> SlackAPI.stream(%{channel: channel.slack_channel_id, limit: 200}, "members")
          |> Enum.reject(&(&1 == bot_user_id))

        {:ok, counts} = Channels.replace_members(channel, slack_user_ids)
        Logger.info("Reconciled members of #{channel.slack_channel_id}: #{inspect(counts)}")
        :ok

      {:error, :ratelimited, seconds} ->
        {:snooze, seconds}

      error ->
        error
    end
  end
end

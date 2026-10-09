defmodule Salamendar.Channels do
  @moduledoc """
  Slack channels, their calendar settings, a local copy of their membership
  and the canvases that show their calendar.

  Nothing here calls Slack. Functions that change what Slack should show
  (e.g. `disable_calendar/1`) return what the caller needs to update it.
  """

  import Ecto.Query

  alias Salamendar.Accounts.User
  alias Salamendar.Channels.{Canvas, Channel, Membership}
  alias Salamendar.Repo

  @doc """
  Returns the channel for `team_id`/`channel_id`, creating it if needed.

  Any of `:name` and `:is_private` in `attrs` (atom keys) overwrite the
  stored values; other keys are ignored. Calendar settings change only through the
  functions below. It is a single upsert, so concurrent calls for the same
  channel don't race.
  """
  @spec upsert_channel(String.t(), String.t(), map()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def upsert_channel(team_id, channel_id, attrs \\ %{}) do
    attrs = Map.take(attrs, [:name, :is_private])

    changeset =
      Channel.changeset(
        %Channel{},
        Map.merge(attrs, %{slack_team_id: team_id, slack_channel_id: channel_id})
      )

    # Keyed off `attrs` rather than `changes`: `is_private: false` equals
    # the default, so it isn't a change, but it must still overwrite `true`.
    replace = Enum.filter([:name, :is_private], &Map.has_key?(attrs, &1))

    Repo.insert(changeset,
      on_conflict: {:replace, replace ++ [:updated_at]},
      conflict_target: [:slack_team_id, :slack_channel_id],
      returning: true
    )
  end

  @doc """
  Turns the calendar on for `channel`.
  """
  @spec enable_calendar(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def enable_calendar(%Channel{} = channel),
    do: update_channel(channel, %{calendar_enabled: true})

  @doc """
  Turns the calendar off for `channel` and deletes its memberships.

  Its events and their `event_channels` rows are kept, so enabling it again
  brings everything back. Returns the channel's canvas rows: the caller
  deletes those canvases in Slack and then the rows.
  """
  @spec disable_calendar(Channel.t()) ::
          {:ok, Channel.t(), [Canvas.t()]} | {:error, Ecto.Changeset.t()}
  def disable_calendar(%Channel{} = channel) do
    Repo.transact(fn ->
      with {:ok, channel} <- update_channel(channel, %{calendar_enabled: false}) do
        Repo.delete_all(from(m in Membership, where: m.channel_id == ^channel.id))
        {:ok, {channel, Repo.all(from(c in Canvas, where: c.channel_id == ^channel.id))}}
      end
    end)
    |> case do
      {:ok, {channel, canvases}} -> {:ok, channel, canvases}
      error -> error
    end
  end

  @doc """
  Marks `channel` as archived in Slack.
  """
  @spec archive_channel(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def archive_channel(%Channel{} = channel),
    do: update_channel(channel, %{archived_at: DateTime.utc_now()})

  @doc """
  Clears `channel`'s archived mark.
  """
  @spec unarchive_channel(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_channel(%Channel{} = channel), do: update_channel(channel, %{archived_at: nil})

  @doc """
  Updates the cached name of `channel`.
  """
  @spec rename_channel(Channel.t(), String.t()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def rename_channel(%Channel{} = channel, name), do: update_channel(channel, %{name: name})

  defp update_channel(channel, attrs), do: channel |> Channel.changeset(attrs) |> Repo.update()

  @doc """
  The time zone `channel`'s calendar is shown in: its own, or the configured
  default.
  """
  @spec time_zone(Channel.t()) :: String.t()
  def time_zone(%Channel{time_zone: nil}),
    do: Application.fetch_env!(:salamendar, :default_time_zone)

  def time_zone(%Channel{time_zone: time_zone}), do: time_zone

  @doc """
  Records that `user` is a member of `channel`. Idempotent.

  Membership is only kept for calendar-enabled channels; callers check that
  first.
  """
  @spec add_member(Channel.t(), User.t()) :: :ok
  def add_member(%Channel{} = channel, %User{} = user) do
    Repo.insert_all(
      Membership,
      [%{channel_id: channel.id, user_id: user.id, inserted_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Records that `user` is no longer a member of `channel`. Idempotent.
  """
  @spec remove_member(Channel.t(), User.t()) :: :ok
  def remove_member(%Channel{} = channel, %User{} = user) do
    Repo.delete_all(
      from(m in Membership, where: m.channel_id == ^channel.id and m.user_id == ^user.id)
    )

    :ok
  end

  @doc """
  Makes `channel`'s memberships match `slack_user_ids` (e.g. the result of
  `conversations.members`), in one transaction.

  Users not seen before get stub rows with only their Slack IDs; their names
  and time zones are filled in later from `users.info`. Returns how many
  memberships were added and removed.
  """
  @spec replace_members(Channel.t(), [String.t()]) ::
          {:ok, %{added: non_neg_integer(), removed: non_neg_integer()}}
  def replace_members(%Channel{} = channel, slack_user_ids) do
    slack_user_ids = Enum.uniq(slack_user_ids)
    team_id = channel.slack_team_id
    now = DateTime.utc_now()

    Repo.transact(fn ->
      Repo.insert_all(
        User,
        Enum.map(slack_user_ids, fn slack_user_id ->
          %{
            id: Ecto.UUID.generate(version: 7),
            slack_team_id: team_id,
            slack_user_id: slack_user_id,
            inserted_at: now,
            updated_at: now
          }
        end),
        on_conflict: :nothing,
        conflict_target: [:slack_team_id, :slack_user_id]
      )

      user_ids =
        Repo.all(
          from(u in User,
            where: u.slack_team_id == ^team_id and u.slack_user_id in ^slack_user_ids,
            select: u.id
          )
        )

      {added, _} =
        Repo.insert_all(
          Membership,
          Enum.map(user_ids, &%{channel_id: channel.id, user_id: &1, inserted_at: now}),
          on_conflict: :nothing
        )

      {removed, _} =
        Repo.delete_all(
          from(m in Membership, where: m.channel_id == ^channel.id and m.user_id not in ^user_ids)
        )

      {:ok, %{added: added, removed: removed}}
    end)
  end

  @doc """
  Whether `user` is a member of `channel`, as far as the local copy knows.
  """
  @spec member?(Channel.t(), User.t()) :: boolean()
  def member?(%Channel{} = channel, %User{} = user) do
    Repo.exists?(
      from(m in Membership, where: m.channel_id == ^channel.id and m.user_id == ^user.id)
    )
  end

  @doc """
  Channels with the calendar enabled, excluding archived ones.
  """
  @spec list_enabled_channels() :: [Channel.t()]
  def list_enabled_channels do
    Repo.all(from(c in Channel, where: c.calendar_enabled and is_nil(c.archived_at)))
  end

  @doc """
  Returns `channel`'s canvas row of `kind`, creating it if needed. A new row
  has no `slack_canvas_id` until the canvas is created in Slack.
  """
  @spec get_or_create_canvas(Channel.t(), Canvas.kind()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_canvas(%Channel{} = channel, kind) do
    with {:ok, _} <-
           %Canvas{channel_id: channel.id}
           |> Canvas.changeset(%{kind: kind})
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:channel_id, :kind]) do
      {:ok, Repo.get_by!(Canvas, channel_id: channel.id, kind: kind)}
    end
  end

  @doc """
  Records that `canvas` now shows `period` (e.g. `"2026-10-01"`), rendered
  to content with hash `hash`.
  """
  @spec mark_canvas_rendered(Canvas.t(), String.t(), String.t()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def mark_canvas_rendered(%Canvas{} = canvas, period, hash) do
    canvas
    |> Canvas.changeset(%{
      rendered_period: period,
      content_hash: hash,
      rendered_at: DateTime.utc_now()
    })
    |> Repo.update()
  end
end

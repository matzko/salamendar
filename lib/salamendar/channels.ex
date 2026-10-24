defmodule Salamendar.Channels do
  @moduledoc """
  Slack channels, their calendar settings and a local copy of their
  membership.

  Nothing here calls Slack.
  """

  import Ecto.Query

  alias Salamendar.Accounts.User
  alias Salamendar.Channels.{Channel, Membership}
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
  The channel for `team_id`/`channel_id`, or `nil` if it isn't stored.
  """
  @spec get_channel(String.t(), String.t()) :: Channel.t() | nil
  def get_channel(team_id, channel_id) do
    Repo.get_by(Channel, slack_team_id: team_id, slack_channel_id: channel_id)
  end

  @doc """
  Deletes `channel` (e.g. after it's deleted in Slack). Its memberships
  and `event_channels` rows go with it; its events stay.
  """
  @spec delete_channel(Channel.t()) :: :ok
  def delete_channel(%Channel{} = channel) do
    Repo.delete_all(from(c in Channel, where: c.id == ^channel.id))
    :ok
  end

  @doc """
  Updates `channel`'s calendar settings: `:week_start` in `attrs`.
  """
  @spec update_settings(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(%Channel{} = channel, attrs) do
    update_channel(channel, Map.take(attrs, [:week_start]))
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
  brings everything back.
  """
  @spec disable_calendar(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def disable_calendar(%Channel{} = channel) do
    Repo.transact(fn ->
      with {:ok, channel} <- update_channel(channel, %{calendar_enabled: false}) do
        Repo.delete_all(from(m in Membership, where: m.channel_id == ^channel.id))
        {:ok, channel}
      end
    end)
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
  The calendar-enabled, unarchived channels `user` is a member of, by name:
  the channels they can add events to.
  """
  @spec list_member_channels(User.t()) :: [Channel.t()]
  def list_member_channels(%User{} = user) do
    Repo.all(
      from(c in Channel,
        join: m in Membership,
        on: m.channel_id == c.id,
        where: m.user_id == ^user.id and c.calendar_enabled and is_nil(c.archived_at),
        order_by: [c.name, c.slack_channel_id]
      )
    )
  end

  @doc """
  Channels with the calendar enabled, excluding archived ones.
  """
  @spec list_enabled_channels() :: [Channel.t()]
  def list_enabled_channels do
    Repo.all(from(c in Channel, where: c.calendar_enabled and is_nil(c.archived_at)))
  end
end

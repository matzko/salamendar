defmodule Salamendar.Calendar do
  @moduledoc """
  Calendar events: creating, changing and deleting them, and the queries
  behind the channel canvases and the Home tab.

  Functions that change events return the IDs of the channels whose canvases
  need re-rendering. Nothing here calls Slack.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels
  alias Salamendar.Channels.{Channel, Membership}
  alias Salamendar.Repo

  @type affected_channel_ids :: [Ecto.UUID.t()]

  @doc """
  Creates an event owned by `owner` in `channels`.

  Every channel must be in the owner's workspace, have the calendar enabled
  and not be archived, and private channels need the owner as a member.
  Problems with the channels are reported on the changeset's `:channels`
  field.
  """
  @spec create_event(User.t(), map(), [Channel.t()]) ::
          {:ok, Event.t(), affected_channel_ids()} | {:error, Ecto.Changeset.t()}
  def create_event(%User{} = owner, attrs, channels) do
    changeset =
      %Event{slack_team_id: owner.slack_team_id, owner_id: owner.id, channels: []}
      |> Event.changeset(attrs)
      |> put_channels(owner, channels)

    with {:ok, event} <- Repo.insert(changeset) do
      {:ok, event, channel_ids(event)}
    end
  end

  @doc """
  Updates `event` as `user`, who must be its owner, and replaces its
  channels with `channels`.

  Channels being added follow the rules in `create_event/3`. Channels the
  event already has can stay even if they've since been disabled or
  archived, and removing a channel needs no checks. The affected channels
  are those the event was in before and those it's in now.
  """
  @spec update_event(User.t(), Event.t(), map(), [Channel.t()]) ::
          {:ok, Event.t(), affected_channel_ids()}
          | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def update_event(%User{} = user, %Event{} = event, attrs, channels) do
    Repo.transact(fn ->
      with {:ok, event} <- lock_owned_event(user, event),
           before = channel_ids(event),
           {:ok, event} <-
             event |> Event.changeset(attrs) |> put_channels(user, channels) |> Repo.update() do
        {:ok, {event, Enum.uniq(before ++ channel_ids(event))}}
      end
    end)
    |> unwrap()
  end

  @doc """
  Deletes `event` as `user`, who must be its owner.
  """
  @spec delete_event(User.t(), Event.t()) ::
          {:ok, Event.t(), affected_channel_ids()} | {:error, :forbidden | :not_found}
  def delete_event(%User{} = user, %Event{} = event) do
    Repo.transact(fn ->
      with {:ok, event} <- lock_owned_event(user, event) do
        {:ok, {Repo.delete!(event), channel_ids(event)}}
      end
    end)
    |> unwrap()
  end

  # Reloads the event under a row lock, so its channels can't change between
  # reading them (for the affected IDs) and writing.
  defp lock_owned_event(user, event) do
    case Repo.one(from(e in Event, where: e.id == ^event.id, lock: "FOR UPDATE")) do
      nil ->
        {:error, :not_found}

      %Event{owner_id: owner_id} = event when owner_id == user.id ->
        {:ok, Repo.preload(event, :channels)}

      %Event{} ->
        {:error, :forbidden}
    end
  end

  defp unwrap({:ok, {event, channel_ids}}), do: {:ok, event, channel_ids}
  defp unwrap(error), do: error

  defp channel_ids(%Event{channels: channels}), do: Enum.map(channels, & &1.id)

  # Puts `requested` as the event's channels, checking the ones being added.
  # Channels are reloaded so the checks don't trust stale structs.
  defp put_channels(changeset, actor, requested) do
    current_ids = changeset.data.channels |> Enum.map(& &1.id) |> MapSet.new()
    requested_ids = requested |> Enum.map(& &1.id) |> Enum.uniq()
    channels = Repo.all(from(c in Channel, where: c.id in ^requested_ids))
    added = Enum.reject(channels, &MapSet.member?(current_ids, &1.id))

    changeset
    |> put_assoc(:channels, channels)
    |> validate_channels(actor, channels, added)
  end

  defp validate_channels(changeset, actor, channels, added) do
    cond do
      channels == [] ->
        add_error(changeset, :channels, "must include at least one channel")

      Enum.any?(added, &(&1.slack_team_id != actor.slack_team_id)) ->
        add_error(changeset, :channels, "must be in your workspace")

      Enum.any?(added, &(not &1.calendar_enabled or not is_nil(&1.archived_at))) ->
        add_error(changeset, :channels, "must have the calendar enabled")

      Enum.any?(added, &(&1.is_private and not Channels.member?(&1, actor))) ->
        add_error(changeset, :channels, "can only include private channels you're in")

      true ->
        changeset
    end
  end

  @doc """
  Events in `channel` that overlap `range`, taking the days in the channel's
  time zone. All-day events first, then by start.
  """
  @spec list_channel_events(Channel.t(), Date.Range.t()) :: [Event.t()]
  def list_channel_events(%Channel{} = channel, %Date.Range{first: first, last: last, step: 1}) do
    from(e in Event,
      join: c in assoc(e, :channels),
      where: c.id == ^channel.id,
      where: ^overlaps(first, Date.add(last, 1), Channels.time_zone(channel)),
      order_by: ^chronological()
    )
    |> Repo.all()
  end

  @doc """
  Events on `date` in `user`'s time zone that `user` should see on their
  Home tab: those in calendar-enabled, unarchived channels they're a member
  of, plus their own (wherever they are). All-day events first, then by
  start.
  """
  @spec list_user_events_on(User.t(), Date.t()) :: [Event.t()]
  def list_user_events_on(%User{} = user, %Date{} = date) do
    # A subquery rather than joins, so an event in several of the user's
    # channels comes back once.
    via_channels =
      from(ec in "event_channels",
        join: m in Membership,
        on: m.channel_id == ec.channel_id,
        join: c in Channel,
        on: c.id == ec.channel_id,
        where: m.user_id == ^user.id and c.calendar_enabled and is_nil(c.archived_at),
        select: ec.event_id
      )

    from(e in Event,
      where: e.slack_team_id == ^user.slack_team_id,
      where: e.id in subquery(via_channels) or e.owner_id == ^user.id,
      where: ^overlaps(date, Date.add(date, 1), Accounts.time_zone(user)),
      order_by: ^chronological()
    )
    |> Repo.all()
  end

  # Events overlapping the local days [first, stop) in `time_zone`. Timed
  # events are compared in UTC; all-day dates are the same everywhere.
  defp overlaps(first, stop, time_zone) do
    window_start = start_of_day(first, time_zone)
    window_end = start_of_day(stop, time_zone)

    dynamic(
      [e],
      (not e.all_day and e.starts_at < ^window_end and e.ends_at > ^window_start) or
        (e.all_day and e.start_date < ^stop and e.end_date > ^first)
    )
  end

  defp chronological, do: [desc: :all_day, asc: :start_date, asc: :starts_at, asc: :title]

  # Where a daylight saving change skips midnight, the day starts at the
  # first time that exists; where midnight happens twice, at the first one.
  defp start_of_day(date, time_zone) do
    case DateTime.new(date, ~T[00:00:00], time_zone) do
      {:ok, datetime} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
    end
  end
end

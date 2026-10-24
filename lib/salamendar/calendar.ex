defmodule Salamendar.Calendar do
  @moduledoc """
  Calendar events: creating, changing and deleting them, and the queries
  behind the web calendar and the Home tab.

  Functions that change events return the IDs of the channels they affect,
  so callers can tell open calendars to refresh. Nothing here calls Slack.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Salamendar.Accounts
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels
  alias Salamendar.Channels.{Channel, Membership}
  alias Salamendar.Render.Period
  alias Salamendar.Repo

  @type affected_channel_ids :: [Ecto.UUID.t()]

  @doc """
  The event with `id`, or `nil` if there's none or `id` isn't a UUID. It
  doesn't check who may see it.
  """
  @spec get_event(term()) :: Event.t() | nil
  def get_event(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Event, id)
      :error -> nil
    end
  end

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
  Moves or resizes `event` as `user`, who must be its owner. Only the times
  change (see `Event.reschedule_changeset/2`): the event stays all-day or
  timed, and keeps its channels and time zone. The affected channels are
  the event's.
  """
  @spec reschedule_event(User.t(), Event.t(), map()) ::
          {:ok, Event.t(), affected_channel_ids()}
          | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def reschedule_event(%User{} = user, %Event{} = event, attrs) do
    Repo.transact(fn ->
      with {:ok, event} <- lock_owned_event(user, event),
           {:ok, event} <- event |> Event.reschedule_changeset(attrs) |> Repo.update() do
        {:ok, {event, channel_ids(event)}}
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

  @typedoc """
  One edge of a range of local days, in both forms: the instant of that
  local midnight (for timed events) and its date (for all-day events, whose
  dates are the same everywhere).
  """
  @type day_edge :: {DateTime.t(), Date.t()}

  @doc """
  Events `user` can see that overlap `[from, to)`: those in calendar-enabled,
  unarchived channels they're a member of, plus their own (wherever they
  are). All-day events first, then by start. `:owner` and `:channels` are
  preloaded.

  Options:

    * `:channel_ids` - only events in these channels (still only ones the
      user can see), plus their own if `:own` is true. Defaults to all.
    * `:own` - with `:channel_ids`, whether to include the user's own
      events in other channels. Defaults to true.
  """
  @spec list_visible_events(User.t(), day_edge(), day_edge(), keyword()) :: [Event.t()]
  def list_visible_events(%User{} = user, from, to, opts \\ []) do
    channel_ids = Keyword.get(opts, :channel_ids)
    own? = is_nil(channel_ids) or Keyword.get(opts, :own, true)

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

    via_channels =
      if channel_ids,
        do: where(via_channels, [ec], ec.channel_id in type(^channel_ids, {:array, :binary_id})),
        else: via_channels

    visible =
      if own?,
        do: dynamic([e], e.id in subquery(via_channels) or e.owner_id == ^user.id),
        else: dynamic([e], e.id in subquery(via_channels))

    from(e in Event,
      where: e.slack_team_id == ^user.slack_team_id,
      where: ^visible,
      where: ^overlaps(from, to),
      order_by: ^chronological(),
      preload: [:owner, :channels]
    )
    |> Repo.all()
  end

  @doc """
  Events on `date` in `user`'s time zone that `user` should see on their
  Home tab: `list_visible_events/4` for that one day.
  """
  @spec list_user_events_on(User.t(), Date.t()) :: [Event.t()]
  def list_user_events_on(%User{} = user, %Date{} = date) do
    time_zone = Accounts.time_zone(user)
    next = Date.add(date, 1)

    list_visible_events(
      user,
      {Period.start_of_day(date, time_zone), date},
      {Period.start_of_day(next, time_zone), next}
    )
  end

  # Timed events are compared by instant; all-day events by date.
  defp overlaps({window_start, first}, {window_end, stop}) do
    dynamic(
      [e],
      (not e.all_day and e.starts_at < ^window_end and e.ends_at > ^window_start) or
        (e.all_day and e.start_date < ^stop and e.end_date > ^first)
    )
  end

  defp chronological, do: [desc: :all_day, asc: :start_date, asc: :starts_at, asc: :title]
end

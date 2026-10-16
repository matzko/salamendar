defmodule SalamendarWeb.EventJSON do
  @moduledoc """
  Events as EventCalendar reads them.

  Timed events are UTC instants (`"2026-10-14T15:00:00Z"`), which the
  browser shows in its own zone. All-day events are dates with the stored,
  exclusive `end_date`: EventCalendar treats the end as exclusive too, and
  reads dates as local dates, so they stay put in every zone.
  """

  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event
  alias Salamendar.Colors

  @doc """
  `event` as `viewer` sees it. `:owner` and `:channels` must be preloaded.
  Only the channels in `visible_channel_ids` are named, so an event doesn't
  reveal private channels the viewer isn't in.

  `startEditable` and `durationEditable` are explicitly false for other
  people's events. The per-event `editable` field isn't used: EventCalendar
  checks `startEditable`, then its `eventStartEditable` option (which
  defaults to true), and only then `editable`, so `editable: false` alone
  doesn't lock an event. The server checks the owner again on every change.
  """
  @spec event(Event.t(), User.t(), MapSet.t(Ecto.UUID.t())) :: map()
  def event(%Event{} = event, %User{} = viewer, visible_channel_ids) do
    color = Colors.for_event(event)
    own? = event.owner_id == viewer.id

    Map.merge(times(event), %{
      id: event.id,
      title: event.title,
      backgroundColor: color.background,
      textColor: color.text,
      startEditable: own?,
      durationEditable: own?,
      extendedProps: %{
        owner: owner_name(event.owner),
        channels:
          for(
            channel <- event.channels,
            MapSet.member?(visible_channel_ids, channel.id),
            do: channel.name || channel.slack_channel_id
          ),
        description: event.description
      }
    })
  end

  defp times(%Event{all_day: true} = event) do
    %{
      start: Date.to_iso8601(event.start_date),
      end: Date.to_iso8601(event.end_date),
      allDay: true
    }
  end

  defp times(%Event{} = event) do
    %{start: instant(event.starts_at), end: instant(event.ends_at), allDay: false}
  end

  # Whole seconds, always with `Z`.
  defp instant(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp owner_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp owner_name(%User{slack_user_id: slack_user_id}), do: slack_user_id
  defp owner_name(_owner), do: nil
end

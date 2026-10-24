defmodule SalamendarWeb.CalendarLive do
  @moduledoc """
  The web calendar at `/`, drawn in the browser by EventCalendar
  (`assets/js/hooks/calendar.js`).

  EventCalendar asks for events with a `fetch` event whenever it shows a new
  range, so events aren't kept in assigns. The LiveView holds which
  channels are checked in the sidebar, and pushes `refetch` when that
  changes, or when `Salamendar.Calendar.Changes` says events changed.
  Subscriptions are made once, at mount, so a channel enabled or joined
  later needs a reload (as the sidebar does).

  `?channel=<Slack channel ID>` (from `/salamendar open`) starts with only
  that channel checked.

  `:time_zone` is the browser's zone, which EventCalendar shows times in
  (`timeZone: "local"`). It comes from the `timeZone` connect param, falling
  back to the user's Slack zone before the socket connects or if the
  browser sends something unknown.
  """
  use SalamendarWeb, :live_view

  alias Salamendar.{Accounts, Calendar, Channels, Colors, TimeZones}
  alias Salamendar.Calendar.{Changes, Event}
  alias Salamendar.Workers.PublishHome

  # The longest range a fetch may ask for. A month grid shows six weeks.
  @max_fetch_days 62

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    channels = Channels.list_member_channels(user)
    if connected?(socket), do: :ok = Changes.subscribe(user)

    {:ok,
     assign(socket,
       page_title: "Calendar",
       channels: channels,
       channel_ids: MapSet.new(channels, & &1.id),
       checked: MapSet.new(channels, & &1.id),
       own: true,
       own_color: Colors.for_user(user),
       time_zone: browser_time_zone(socket, user),
       week_start: common_week_start(channels)
     )}
  end

  @impl true
  def handle_params(%{"channel" => slack_channel_id}, _uri, socket) do
    case Enum.find(socket.assigns.channels, &(&1.slack_channel_id == slack_channel_id)) do
      nil ->
        {:noreply, socket}

      channel ->
        {:noreply,
         assign(socket,
           checked: MapSet.new([channel.id]),
           own: false,
           week_start: channel.week_start
         )}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("fetch", params, socket) do
    events =
      case fetch_range(params) do
        {:ok, from, to} ->
          %{current_user: user, checked: checked, own: own, channel_ids: visible} = socket.assigns

          user
          |> Calendar.list_visible_events(from, to,
            channel_ids: MapSet.to_list(checked),
            own: own
          )
          |> Enum.map(&SalamendarWeb.EventJSON.event(&1, user, visible))

        :error ->
          []
      end

    {:reply, %{events: events}, socket}
  end

  # A drag or resize. Only the times change; the hook reverts the move
  # unless the reply is `ok: true`.
  def handle_event("reschedule", %{"id" => id} = params, socket) do
    user = socket.assigns.current_user

    result =
      with %Event{} = event <- Calendar.get_event(id) || {:error, :not_found},
           {:ok, attrs} <- reschedule_attrs(event, params) do
        Calendar.reschedule_event(user, event, attrs)
      end

    case result do
      {:ok, event, channel_ids} ->
        :ok = Changes.broadcast(channel_ids, event.owner_id)
        {:ok, _} = PublishHome.enqueue(user.slack_team_id, user.slack_user_id)
        {:reply, %{ok: true}, socket}

      {:error, reason} ->
        {:reply, %{ok: false}, put_flash(socket, :error, reschedule_error(reason))}
    end
  end

  def handle_event("toggle_channel", %{"id" => id}, socket) do
    if MapSet.member?(socket.assigns.channel_ids, id) do
      checked = socket.assigns.checked

      checked =
        if MapSet.member?(checked, id),
          do: MapSet.delete(checked, id),
          else: MapSet.put(checked, id)

      {:noreply, socket |> assign(checked: checked) |> push_event("refetch", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_own", _params, socket) do
    {:noreply, socket |> assign(own: not socket.assigns.own) |> push_event("refetch", %{})}
  end

  @impl true
  def handle_info(:calendar_changed, socket), do: {:noreply, push_event(socket, "refetch", %{})}

  # Dates for an all-day event, instants for a timed one, according to the
  # stored event: a drag never switches between them.
  defp reschedule_attrs(%Event{all_day: true}, %{"start" => start, "end" => stop})
       when is_binary(start) and is_binary(stop) do
    with {:ok, start_date} <- Date.from_iso8601(start),
         {:ok, end_date} <- Date.from_iso8601(stop) do
      {:ok, %{start_date: start_date, end_date: end_date}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp reschedule_attrs(%Event{}, %{"start" => start, "end" => stop})
       when is_binary(start) and is_binary(stop) do
    with {:ok, starts_at, _} <- DateTime.from_iso8601(start),
         {:ok, ends_at, _} <- DateTime.from_iso8601(stop) do
      {:ok, %{starts_at: starts_at, ends_at: ends_at}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp reschedule_attrs(_event, _params), do: {:error, :invalid}

  defp reschedule_error(:forbidden), do: "Only the owner can move this event."
  defp reschedule_error(:not_found), do: "This event was deleted."
  defp reschedule_error(_reason), do: "Couldn't move this event."

  # The hook sends each edge of the range twice: as an instant (the local
  # midnight, for timed events) and as a local date (for all-day events).
  defp fetch_range(%{
         "start" => start,
         "end" => stop,
         "start_date" => start_date,
         "end_date" => end_date
       }) do
    with {:ok, starts_at, _} <- DateTime.from_iso8601(start),
         {:ok, ends_at, _} <- DateTime.from_iso8601(stop),
         {:ok, first} <- Date.from_iso8601(start_date),
         {:ok, last} <- Date.from_iso8601(end_date),
         true <- DateTime.before?(starts_at, ends_at) and Date.before?(first, last),
         true <- Date.diff(last, first) <= @max_fetch_days do
      {:ok, {starts_at, first}, {ends_at, last}}
    else
      _ -> :error
    end
  end

  defp fetch_range(_params), do: :error

  defp browser_time_zone(socket, user) do
    time_zone = get_connect_params(socket)["timeZone"]
    if TimeZones.valid?(time_zone), do: time_zone, else: Accounts.time_zone(user)
  end

  # Channels can start weeks on different days; use the most common.
  defp common_week_start([]), do: 0

  defp common_week_start(channels) do
    channels
    |> Enum.frequencies_by(& &1.week_start)
    |> Enum.max_by(fn {day, count} -> {count, -day} end)
    |> elem(0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <div class="calendar-page">
        <button
          type="button"
          class="sidebar-toggle"
          aria-controls="sidebar"
          phx-click={JS.toggle_class("open", to: "#sidebar")}
        >
          Calendars
        </button>

        <aside id="sidebar" class="sidebar">
          <div class="sidebar-header">
            <h2>Calendars</h2>
            <button
              type="button"
              class="sidebar-close"
              phx-click={JS.remove_class("open", to: "#sidebar")}
            >
              Done
            </button>
          </div>

          <label class="calendar-option">
            <input type="checkbox" checked={@own} phx-click="toggle_own" />
            <span class="swatch" style={"background: #{@own_color.background}"}></span> My events
          </label>

          <label :for={channel <- @channels} class="calendar-option">
            <input
              type="checkbox"
              checked={MapSet.member?(@checked, channel.id)}
              phx-click="toggle_channel"
              phx-value-id={channel.id}
            />
            <span class="channel-name">#{channel.name || channel.slack_channel_id}</span>
          </label>

          <p :if={@channels == []} class="muted">
            None of your channels have a calendar yet. Turn one on with
            <code>/salamendar enable</code>
            in Slack.
          </p>

          <footer class="sidebar-footer">
            <p class="muted">{@current_user.name || @current_user.slack_user_id}</p>
            <p class="muted time-zone">Times in {@time_zone}</p>
            <.link href={~p"/session"} method="delete">Sign out</.link>
          </footer>
        </aside>

        <div
          id="calendar"
          class="calendar ec-auto-dark"
          phx-hook="Calendar"
          phx-update="ignore"
          data-week-start={@week_start}
        >
        </div>
      </div>
    </Layouts.app>
    """
  end
end

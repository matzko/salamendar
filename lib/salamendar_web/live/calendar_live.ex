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

  Clicking an event opens the event panel (`:event`), which shows its
  details to anyone who can see it. Its owner can delete it there, or
  switch it to the form (`:form`, editing `:editing`), which is also how
  events are added: from the sidebar's button or by selecting a range on
  the calendar. The form's params are described in
  `SalamendarWeb.EventParams`.
  """
  use SalamendarWeb, :live_view

  alias Salamendar.{Accounts, Calendar, Channels, Colors, Labels, TimeZones}
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.{Changes, Event}
  alias Salamendar.Channels.Channel
  alias Salamendar.Workers.PublishHome
  alias SalamendarWeb.{EventParams, EventTimes}

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
       labels: Labels.list_labels(user),
       time_zone: browser_time_zone(socket, user),
       event: nil,
       form: nil,
       editing: nil,
       channel_options: [],
       label_options: [],
       label_colors: %{},
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

  def handle_event("open", %{"id" => id}, socket) do
    case Calendar.get_visible_event(socket.assigns.current_user, id) do
      nil -> {:noreply, socket}
      event -> {:noreply, assign(socket, event: event)}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, close_panel(socket)}

  # The sidebar's "Add event" button.
  def handle_event("add", _params, socket) do
    {:noreply, open_form(socket, :new, EventParams.new(socket.assigns.time_zone))}
  end

  # A range selected on the calendar.
  def handle_event("new", params, socket) do
    {:noreply,
     open_form(socket, :new, EventParams.from_selection(params, socket.assigns.time_zone))}
  end

  def handle_event("edit", _params, socket) do
    %{event: event, current_user: user, time_zone: time_zone} = socket.assigns

    if event && event.owner_id == user.id,
      do: {:noreply, open_form(socket, event, EventParams.from_event(event, time_zone))},
      else: {:noreply, socket}
  end

  # From the owner's details view, after the browser's confirmation.
  def handle_event("delete", _params, socket) do
    %{event: event, current_user: user} = socket.assigns

    case event && Calendar.delete_event(user, event) do
      {:ok, deleted, affected} ->
        :ok = Changes.broadcast(affected, deleted.owner_id)
        {:ok, _} = PublishHome.enqueue(user.slack_team_id, user.slack_user_id)
        {:noreply, socket |> close_panel() |> put_flash(:info, "Deleted “#{deleted.title}”.")}

      {:error, :forbidden} ->
        {:noreply,
         socket |> close_panel() |> put_flash(:error, "Only the event's owner can delete it.")}

      {:error, :not_found} ->
        {:noreply,
         socket |> close_panel() |> put_flash(:error, "This event was already deleted.")}

      nil ->
        {:noreply, socket}
    end
  end

  # Back to the details of the event being edited, or closed for a new one.
  def handle_event("cancel", _params, socket) do
    case socket.assigns.editing do
      %Event{} -> {:noreply, assign(socket, form: nil, editing: nil)}
      _ -> {:noreply, close_panel(socket)}
    end
  end

  def handle_event("validate", %{"event" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, form: event_form(params, preview_errors(socket, params)))}
  end

  def handle_event("save", %{"event" => params}, socket) when is_map(params) do
    %{current_user: user, editing: editing, time_zone: time_zone} = socket.assigns
    {attrs, channel_ids} = EventParams.to_attrs(params, time_zone)
    channels = Enum.map(channel_ids, &%Channel{id: &1})

    result =
      case editing do
        %Event{} = event -> Calendar.update_event(user, event, attrs, channels)
        _new -> Calendar.create_event(user, Map.put(attrs, :time_zone, time_zone), channels)
      end

    case result do
      {:ok, event, affected} ->
        :ok = Changes.broadcast(affected, event.owner_id)
        {:ok, _} = PublishHome.enqueue(user.slack_team_id, user.slack_user_id)

        {:noreply,
         assign(socket,
           form: nil,
           editing: nil,
           event: Calendar.get_visible_event(user, event.id)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: event_form(params, EventParams.errors(changeset)))}

      {:error, :forbidden} ->
        {:noreply,
         socket |> close_panel() |> put_flash(:error, "Only the event's owner can change it.")}

      {:error, :not_found} ->
        {:noreply, socket |> close_panel() |> put_flash(:error, "This event was deleted.")}
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

  # The event in the details view may have changed too: reload it, closing
  # the panel if it's gone or no longer visible. An open form is left
  # alone; saving it reports a deleted event.
  @impl true
  def handle_info(:calendar_changed, socket) do
    socket =
      case socket.assigns do
        %{form: nil, event: %Event{id: id}, current_user: user} ->
          assign(socket, event: Calendar.get_visible_event(user, id))

        _ ->
          socket
      end

    {:noreply, push_event(socket, "refetch", %{})}
  end

  defp close_panel(socket), do: assign(socket, event: nil, form: nil, editing: nil)

  defp open_form(socket, editing, params) do
    current = if match?(%Event{}, editing), do: editing.channels, else: []

    options =
      for channel <- Channels.list_picker_channels(socket.assigns.current_user, current),
          do: {"#" <> (channel.name || channel.slack_channel_id), channel.id}

    labels = Labels.list_labels(socket.assigns.current_user)

    assign(socket,
      editing: editing,
      form: event_form(params, []),
      channel_options: options,
      label_options:
        for(
          {group, labels} <- [{"Shared", labels.shared}, {"Mine", labels.mine}],
          labels != [],
          do: {group, Enum.map(labels, &{"#{&1.name} · #{Colors.get(&1.color).name}", &1.id})}
        ),
      label_colors: Map.new(labels.shared ++ labels.mine, &{&1.id, Colors.get(&1.color)})
    )
  end

  defp event_form(params, errors), do: to_form(params, as: :event, errors: errors)

  # The changeset's errors for `params` without saving, so fields can show
  # them as they're filled in. Channels are only checked on save.
  defp preview_errors(socket, params) do
    %{current_user: user, editing: editing, time_zone: time_zone} = socket.assigns
    {attrs, _channel_ids} = EventParams.to_attrs(params, time_zone)

    base =
      case editing do
        %Event{} = event -> event
        _new -> %Event{slack_team_id: user.slack_team_id, time_zone: time_zone}
      end

    base |> Event.changeset(attrs) |> EventParams.errors()
  end

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
          <.button
            type="button"
            variant="primary"
            class="add-event"
            phx-click={JS.push("add") |> JS.remove_class("open", to: "#sidebar")}
          >
            Add event
          </.button>

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

          <.label_legend labels={@labels} />

          <footer class="sidebar-footer">
            <p class="muted">{@current_user.name || @current_user.slack_user_id}</p>
            <p class="muted time-zone">Times in {@time_zone}</p>
            <p><.link navigate={~p"/settings"}>Settings</.link></p>
            <.link href={~p"/session"} method="delete">Sign out</.link>
          </footer>
        </aside>

        <.form_panel
          :if={@form}
          form={@form}
          new?={not match?(%Event{}, @editing)}
          channel_options={@channel_options}
          label_options={@label_options}
          label_colors={@label_colors}
        />

        <.event_panel
          :if={@event && !@form}
          event={@event}
          viewer={@current_user}
          channel_ids={@channel_ids}
          time_zone={@time_zone}
        />

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

  attr :labels, :map, required: true, doc: "from `Labels.list_labels/1`"

  defp label_legend(assigns) do
    ~H"""
    <section class="label-legend" aria-labelledby="label-legend-title">
      <h2 id="label-legend-title">Labels</h2>

      <%= for {heading, labels} <- [{"Shared", @labels.shared}, {"Mine", @labels.mine}], labels != [] do %>
        <h3>{heading}</h3>
        <ul>
          <li :for={label <- labels} class="legend-item">
            <span class="swatch" style={"background: #{Colors.get(label.color).background}"}></span>
            <span class="label-name">{label.name}</span>
          </li>
        </ul>
      <% end %>

      <p :if={@labels.shared == [] and @labels.mine == []} class="muted">
        Make labels in <.link navigate={~p"/settings"}>Settings</.link> to color events.
      </p>
    </section>
    """
  end

  attr :event, Event, required: true
  attr :viewer, User, required: true
  attr :channel_ids, MapSet, required: true, doc: "channels the viewer may see named"
  attr :time_zone, :string, required: true

  defp event_panel(assigns) do
    assigns =
      assign(assigns,
        color: Colors.for_event(assigns.event),
        own?: assigns.event.owner_id == assigns.viewer.id,
        channels:
          for(
            channel <- assigns.event.channels,
            MapSet.member?(assigns.channel_ids, channel.id),
            do: channel.name || channel.slack_channel_id
          )
      )

    ~H"""
    <aside
      id="event-panel"
      class="event-panel"
      role="dialog"
      aria-labelledby="event-panel-title"
      phx-window-keydown="close"
      phx-key="Escape"
    >
      <header class="event-panel-header">
        <span class="swatch" style={"background: #{@color.background}"}></span>
        <h2 id="event-panel-title">{@event.title}</h2>
        <button type="button" class="event-panel-close" phx-click="close" aria-label="Close">
          ×
        </button>
      </header>

      <p class="event-when">{EventTimes.format(@event, @time_zone)}</p>

      <dl class="event-details">
        <dt>Owner</dt>
        <dd class="event-owner">{if @own?, do: "You", else: owner_name(@event.owner)}</dd>

        <%= if @event.label do %>
          <dt>Label</dt>
          <dd class="event-label">{@event.label.name}</dd>
        <% end %>

        <%= if @channels != [] do %>
          <dt>Channels</dt>
          <dd class="event-channels">{Enum.map_join(@channels, " ", &"##{&1}")}</dd>
        <% end %>
      </dl>

      <p :if={@event.description} class="event-description">{@event.description}</p>

      <div :if={@own?} class="event-panel-actions">
        <.button type="button" phx-click="edit">Edit</.button>
        <.button
          type="button"
          variant="danger"
          phx-click="delete"
          data-confirm={"Delete “#{@event.title}”? This can't be undone."}
        >
          Delete
        </.button>
      </div>
    </aside>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :new?, :boolean, required: true
  attr :channel_options, :list, required: true
  attr :label_options, :list, required: true, doc: "grouped `{name, id}` options"
  attr :label_colors, :map, required: true, doc: "each label's color, by ID"

  defp form_panel(assigns) do
    assigns =
      assign(assigns,
        all_day?: EventParams.all_day?(assigns.form.params),
        label_color: Map.get(assigns.label_colors, assigns.form[:label_id].value)
      )

    ~H"""
    <aside
      id="event-panel"
      class="event-panel"
      role="dialog"
      aria-labelledby="event-panel-title"
      phx-window-keydown="close"
      phx-key="Escape"
    >
      <header class="event-panel-header">
        <h2 id="event-panel-title">{if @new?, do: "Add event", else: "Edit event"}</h2>
        <button type="button" class="event-panel-close" phx-click="close" aria-label="Close">
          ×
        </button>
      </header>

      <.form for={@form} id="event-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:title]} label="Title" maxlength="255" />
        <.input field={@form[:all_day]} type="checkbox" label="All day" />

        <%= if @all_day? do %>
          <.input field={@form[:start_date]} type="date" label="Starts" />
          <.input field={@form[:end_date]} type="date" label="Ends" />
          <.input field={@form[:starts_at]} type="hidden" />
          <.input field={@form[:ends_at]} type="hidden" />
        <% else %>
          <.input field={@form[:starts_at]} type="datetime-local" label="Starts" />
          <.input field={@form[:ends_at]} type="datetime-local" label="Ends" />
          <.input field={@form[:start_date]} type="hidden" />
          <.input field={@form[:end_date]} type="hidden" />
        <% end %>

        <.input
          field={@form[:channel_ids]}
          type="checkgroup"
          label="Channels"
          options={@channel_options}
        />
        <p :if={@channel_options == []} class="muted">
          You aren't in any channels with the calendar on yet. Run <code>/salamendar enable</code>
          in a channel to start one.
        </p>

        <div class="label-picker">
          <.input
            field={@form[:label_id]}
            type="select"
            label="Label"
            prompt="None"
            options={@label_options}
          />
          <span
            :if={@label_color}
            class="swatch"
            style={"background: #{@label_color.background}"}
          ></span>
        </div>

        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="event-panel-actions">
          <.button type="submit" variant="primary" phx-disable-with="Saving…">Save</.button>
          <.button type="button" phx-click="cancel">Cancel</.button>
        </div>
      </.form>
    </aside>
    """
  end

  defp owner_name(%User{name: name}) when is_binary(name) and name != "",
    do: name

  defp owner_name(%User{slack_user_id: slack_user_id}), do: slack_user_id
  defp owner_name(nil), do: "Someone who has left"
end

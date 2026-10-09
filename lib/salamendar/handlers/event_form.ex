defmodule Salamendar.Handlers.EventForm do
  @moduledoc """
  The modals for adding, editing and deleting events.

  The form has a title, start and end (`datetimepicker`s, which Slack shows
  in the viewer's time zone), an "All day" checkbox, the channels, and a
  description. Block Kit can't show or hide fields as the checkbox changes
  without a round trip, so all-day events use the dates of the start and
  end pickers and ignore their times; the end date is inclusive in the form
  and exclusive in the database.

  The channel picker is a `multi_static_select` of the calendar channels the
  user belongs to (plus, when editing, the event's current channels), since
  Slack's own conversation pickers can't be filtered by our data.

  Submissions answer Slack within its 3-second limit: they only touch the
  database and enqueue jobs (canvas syncs and a Home tab refresh), and they
  return `{:ack, …}` with errors to show in the form.
  """

  alias Salamendar.{Accounts, Calendar, Channels, Repo, SlackAPI}
  alias Salamendar.Calendar.Event
  alias Salamendar.Channels.Channel
  alias Salamendar.Render.Period
  alias Salamendar.Workers.{PublishHome, SyncCanvas}

  @form_callback_id "event_form"
  @delete_callback_id "delete_event"
  @max_channel_options 100

  # Where each changeset field's errors are shown in the form.
  @error_blocks %{
    title: "title",
    description: "description",
    starts_at: "start",
    start_date: "start",
    time_zone: "start",
    ends_at: "end",
    end_date: "end",
    all_day: "all_day",
    channels: "channels"
  }

  @doc """
  `callback_id` of the add/edit form.
  """
  @spec form_callback_id() :: String.t()
  def form_callback_id, do: @form_callback_id

  @doc """
  `callback_id` of the delete confirmation.
  """
  @spec delete_callback_id() :: String.t()
  def delete_callback_id, do: @delete_callback_id

  @doc """
  Opens the form for a new event, or for editing `event_id`.
  """
  @spec open(String.t(), String.t(), String.t(), Ecto.UUID.t() | nil) :: SlackAPI.result()
  def open(trigger_id, team_id, slack_user_id, event_id \\ nil) do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)

    view =
      case load_owned_event(user, event_id) do
        {:ok, event} -> form_view(user, event)
        {:error, message} -> message_view("Edit event", message)
      end

    SlackAPI.post("views.open", %{trigger_id: trigger_id, view: view})
  end

  @doc """
  Opens a confirmation before deleting `event_id`.
  """
  @spec open_delete(String.t(), String.t(), String.t(), Ecto.UUID.t()) :: SlackAPI.result()
  def open_delete(trigger_id, team_id, slack_user_id, event_id) do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)

    view =
      case load_owned_event(user, event_id) do
        {:ok, %Event{} = event} -> delete_view(event)
        {:error, message} -> message_view("Delete event", message)
      end

    SlackAPI.post("views.open", %{trigger_id: trigger_id, view: view})
  end

  @doc """
  Handles a submitted add/edit form (`view_submission` payload). Returns
  `:ok` to close the form, or `{:ack, …}` with errors to show in it.
  """
  @spec submit(String.t(), map()) :: :ok | {:ack, map()}
  def submit(team_id, %{"user" => %{"id" => slack_user_id}, "view" => view}) do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)
    attrs = form_attrs(view["state"]["values"], Accounts.time_zone(user))
    channels = Enum.map(selected_channel_ids(view["state"]["values"]), &%Channel{id: &1})

    result =
      case blank_to_nil(view["private_metadata"]) do
        nil ->
          Calendar.create_event(user, attrs, channels)

        event_id ->
          case Repo.get(Event, event_id) do
            nil -> {:error, :not_found}
            event -> Calendar.update_event(user, event, attrs, channels)
          end
      end

    case result do
      {:ok, _event, channel_ids} ->
        after_change(team_id, slack_user_id, channel_ids)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:ack, %{response_action: "errors", errors: form_errors(changeset)}}

      {:error, :not_found} ->
        {:ack, %{response_action: "errors", errors: %{"title" => "This event was deleted."}}}

      {:error, :forbidden} ->
        {:ack,
         %{
           response_action: "errors",
           errors: %{"title" => "Only the event's owner can change it."}
         }}
    end
  end

  @doc """
  Handles a confirmed delete (`view_submission` payload).
  """
  @spec submit_delete(String.t(), map()) :: :ok | {:ack, map()}
  def submit_delete(team_id, %{"user" => %{"id" => slack_user_id}, "view" => view}) do
    {:ok, user} = Accounts.get_or_create_user(team_id, slack_user_id)

    result =
      case Repo.get(Event, view["private_metadata"]) do
        nil -> {:error, :not_found}
        event -> Calendar.delete_event(user, event)
      end

    case result do
      {:ok, _event, channel_ids} ->
        after_change(team_id, slack_user_id, channel_ids)

      {:error, :not_found} ->
        {:ack, update_to_message("This event was already deleted.")}

      {:error, :forbidden} ->
        {:ack, update_to_message("Only the event's owner can delete it.")}
    end
  end

  defp after_change(team_id, slack_user_id, channel_ids) do
    for channel_id <- channel_ids, do: {:ok, _} = SyncCanvas.enqueue(channel_id)
    {:ok, _} = PublishHome.enqueue(team_id, slack_user_id)
    :ok
  end

  defp load_owned_event(_user, nil), do: {:ok, nil}

  defp load_owned_event(user, event_id) do
    case Repo.get(Event, event_id) do
      nil ->
        {:error, "This event was deleted."}

      %Event{owner_id: owner_id} = event when owner_id == user.id ->
        {:ok, Repo.preload(event, :channels)}

      %Event{} ->
        {:error, "Only the event's owner can change it."}
    end
  end

  # -- Views -------------------------------------------------------------------

  defp form_view(user, event) do
    channels = picker_channels(user, event)

    if channels == [] do
      message_view(
        "Add event",
        "You aren't in any channels with the calendar on yet. " <>
          "Run `/salamendar enable` in a channel to start one."
      )
    else
      time_zone = Accounts.time_zone(user)
      {starts_at, ends_at} = initial_times(event, time_zone)

      %{
        type: "modal",
        callback_id: @form_callback_id,
        private_metadata: (event && event.id) || "",
        title: plain(if event, do: "Edit event", else: "Add event"),
        submit: plain("Save"),
        close: plain("Cancel"),
        blocks: [
          input("title", "Title", %{
            type: "plain_text_input",
            action_id: "value",
            max_length: 255,
            initial_value: event && event.title
          }),
          input("start", "Starts", datetimepicker(starts_at)),
          input("end", "Ends", datetimepicker(ends_at)),
          input(
            "all_day",
            "All day",
            all_day_checkbox(event),
            optional: true,
            hint: "Uses the start and end dates (inclusive); their times are ignored."
          ),
          input("channels", "Channels", channel_picker(channels, event)),
          input(
            "description",
            "Description",
            %{
              type: "plain_text_input",
              action_id: "value",
              multiline: true,
              initial_value: event && event.description
            },
            optional: true
          )
        ]
      }
    end
  end

  defp delete_view(event) do
    %{
      type: "modal",
      callback_id: @delete_callback_id,
      private_metadata: event.id,
      title: plain("Delete event"),
      submit: plain("Delete"),
      close: plain("Cancel"),
      blocks: [
        %{
          type: "section",
          text: %{type: "mrkdwn", text: "Delete *#{escape(event.title)}*? This can't be undone."}
        }
      ]
    }
  end

  defp message_view(title, text) do
    %{
      type: "modal",
      title: plain(title),
      close: plain("OK"),
      blocks: [%{type: "section", text: %{type: "mrkdwn", text: text}}]
    }
  end

  defp update_to_message(text),
    do: %{response_action: "update", view: message_view("Delete event", text)}

  defp input(block_id, label, element, opts \\ []) do
    %{
      type: "input",
      block_id: block_id,
      label: plain(label),
      element: reject_nils(element),
      optional: Keyword.get(opts, :optional, false)
    }
    |> then(fn block ->
      if hint = opts[:hint], do: Map.put(block, :hint, plain(hint)), else: block
    end)
  end

  defp datetimepicker(datetime) do
    %{type: "datetimepicker", action_id: "value", initial_date_time: DateTime.to_unix(datetime)}
  end

  defp all_day_checkbox(event) do
    option = %{text: plain("All day"), value: "all_day"}
    checkbox = %{type: "checkboxes", action_id: "value", options: [option]}

    if event && event.all_day,
      do: Map.put(checkbox, :initial_options, [option]),
      else: checkbox
  end

  defp channel_picker(channels, event) do
    options = Enum.map(channels, &channel_option/1)
    selected_ids = if event, do: Enum.map(event.channels, & &1.id), else: []
    initial = Enum.filter(options, &(&1.value in selected_ids))

    %{
      type: "multi_static_select",
      action_id: "value",
      placeholder: plain("Choose channels"),
      options: options
    }
    |> then(fn picker ->
      if initial == [], do: picker, else: Map.put(picker, :initial_options, initial)
    end)
  end

  # The user's calendar channels, plus the event's own (which may since have
  # been disabled, or which the owner may have left), up to Slack's limit.
  defp picker_channels(user, event) do
    current = if event, do: event.channels, else: []

    (current ++ Channels.list_member_channels(user))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(@max_channel_options)
  end

  defp channel_option(channel) do
    # Slack limits option text to 75 characters.
    %{
      text: plain(String.slice("##{channel.name || channel.slack_channel_id}", 0, 75)),
      value: channel.id
    }
  end

  # A new event starts at the next full hour and lasts an hour. An all-day
  # event shows 9:00 on its first day to 17:00 on its last.
  defp initial_times(nil, _time_zone) do
    now = DateTime.to_unix(DateTime.utc_now())
    starts_at = DateTime.from_unix!(div(now, 3600) * 3600 + 3600)
    {starts_at, DateTime.add(starts_at, 3600)}
  end

  defp initial_times(%Event{all_day: true} = event, time_zone) do
    {DateTime.add(Period.start_of_day(event.start_date, time_zone), 9 * 3600),
     DateTime.add(Period.start_of_day(Date.add(event.end_date, -1), time_zone), 17 * 3600)}
  end

  defp initial_times(%Event{} = event, _time_zone), do: {event.starts_at, event.ends_at}

  # -- Submissions --------------------------------------------------------------

  defp form_attrs(values, time_zone) do
    starts_at = selected_datetime(values, "start")
    ends_at = selected_datetime(values, "end")

    times =
      if all_day?(values) do
        %{
          all_day: true,
          start_date: starts_at && Period.today(time_zone, starts_at),
          end_date: ends_at && Date.add(Period.today(time_zone, ends_at), 1),
          starts_at: nil,
          ends_at: nil
        }
      else
        %{all_day: false, starts_at: starts_at, ends_at: ends_at, start_date: nil, end_date: nil}
      end

    Map.merge(times, %{
      title: get_in(values, ["title", "value", "value"]),
      description: blank_to_nil(get_in(values, ["description", "value", "value"])),
      time_zone: time_zone
    })
  end

  defp selected_datetime(values, block_id) do
    case get_in(values, [block_id, "value", "selected_date_time"]) do
      unix when is_integer(unix) -> DateTime.from_unix!(unix)
      _ -> nil
    end
  end

  defp all_day?(values),
    do: get_in(values, ["all_day", "value", "selected_options"]) not in [nil, []]

  defp selected_channel_ids(values) do
    for %{"value" => id} <- get_in(values, ["channels", "value", "selected_options"]) || [],
        do: id
  end

  defp form_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.reduce(%{}, fn {field, [message | _]}, errors ->
      block_id = Map.get(@error_blocks, field, "title")
      Map.put_new(errors, block_id, String.capitalize(message) <> ".")
    end)
  end

  # -- Helpers ------------------------------------------------------------------

  defp plain(text), do: %{type: "plain_text", text: text}

  defp reject_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

defmodule SalamendarWeb.EventParams do
  @moduledoc """
  The event panel's form: its params, and turning them into `Calendar`
  attrs.

  The form keeps both kinds of times so that toggling "All day" doesn't
  lose what was typed. Only the pair that matches the checkbox is shown;
  the other rides along in hidden inputs.

    * `starts_at`/`ends_at`: `datetime-local` values (`"2026-10-14T09:00"`),
      wall-clock times in the viewer's zone.
    * `start_date`/`end_date`: dates, with the end **inclusive**, as in the
      Slack form. It's stored exclusive.

  Params are string-keyed, as the browser sends them.
  """

  alias Salamendar.Calendar.Event
  alias Salamendar.Render.Period

  # Where each changeset field's errors are shown in the form.
  @error_fields %{
    title: :title,
    description: :description,
    all_day: :all_day,
    starts_at: :starts_at,
    ends_at: :ends_at,
    start_date: :start_date,
    end_date: :end_date,
    time_zone: :starts_at,
    channels: :channel_ids,
    label_id: :label_id
  }

  @doc """
  Params for a new event from the "Add event" button: the next full hour,
  for an hour, in `time_zone`.
  """
  @spec new(String.t(), DateTime.t()) :: map()
  def new(time_zone, now \\ DateTime.utc_now()) do
    hour = div(DateTime.to_unix(now), 3600) * 3600 + 3600
    starts_at = DateTime.from_unix!(hour)
    timed(starts_at, DateTime.add(starts_at, 3600), time_zone)
  end

  @doc """
  Params for a new event from a selection on the calendar. EventCalendar
  sends the range as `start`/`end` instants and as local `start_date`/
  `end_date` (exclusive), and `all_day` for a selection in the month grid.
  A selection that can't be read falls back to `new/2`.
  """
  @spec from_selection(map(), String.t()) :: map()
  def from_selection(%{"all_day" => true, "start_date" => first, "end_date" => stop}, time_zone)
      when is_binary(first) and is_binary(stop) do
    with {:ok, first} <- Date.from_iso8601(first),
         {:ok, stop} <- Date.from_iso8601(stop),
         true <- Date.before?(first, stop) do
      all_day(first, Date.add(stop, -1), time_zone)
    else
      _ -> new(time_zone)
    end
  end

  def from_selection(%{"start" => start, "end" => stop}, time_zone)
      when is_binary(start) and is_binary(stop) do
    with {:ok, starts_at, _} <- DateTime.from_iso8601(start),
         {:ok, ends_at, _} <- DateTime.from_iso8601(stop),
         true <- DateTime.before?(starts_at, ends_at) do
      timed(starts_at, ends_at, time_zone)
    else
      _ -> new(time_zone)
    end
  end

  def from_selection(_params, time_zone), do: new(time_zone)

  @doc """
  Params for editing `event` (with `:channels` loaded), times in
  `time_zone`.
  """
  @spec from_event(Event.t(), String.t()) :: map()
  def from_event(%Event{} = event, time_zone) do
    times =
      if event.all_day,
        do: all_day(event.start_date, Date.add(event.end_date, -1), time_zone),
        else: timed(event.starts_at, event.ends_at, time_zone)

    Map.merge(times, %{
      "title" => event.title,
      "description" => event.description || "",
      "channel_ids" => Enum.map(event.channels, & &1.id),
      "label_id" => event.label_id || ""
    })
  end

  @doc """
  Whether `params` are for an all-day event.
  """
  @spec all_day?(map()) :: boolean()
  def all_day?(params), do: params["all_day"] in [true, "true"]

  @doc """
  `Calendar` attrs and the chosen channel IDs from submitted `params`.
  `datetime-local` values are read in `time_zone`. Values that can't be
  read become `nil`, so the changeset says they're missing. A blank or
  malformed `label_id` means no label.
  """
  @spec to_attrs(map(), String.t()) :: {map(), [Ecto.UUID.t()]}
  def to_attrs(params, time_zone) do
    times =
      if all_day?(params) do
        end_date = parse_date(params["end_date"])

        %{
          all_day: true,
          start_date: parse_date(params["start_date"]),
          end_date: end_date && Date.add(end_date, 1),
          starts_at: nil,
          ends_at: nil
        }
      else
        %{
          all_day: false,
          starts_at: parse_local(params["starts_at"], time_zone),
          ends_at: parse_local(params["ends_at"], time_zone),
          start_date: nil,
          end_date: nil
        }
      end

    attrs =
      Map.merge(times, %{
        title: params["title"],
        description: blank_to_nil(params["description"]),
        label_id: label_id(params["label_id"])
      })

    {attrs, channel_ids(params["channel_ids"])}
  end

  @doc """
  `changeset`'s errors as `{form_field, {message, opts}}`, for `to_form/2`.
  """
  @spec errors(Ecto.Changeset.t()) :: keyword()
  def errors(%Ecto.Changeset{errors: errors}) do
    for {field, error} <- errors, do: {Map.get(@error_fields, field, :title), error}
  end

  defp timed(starts_at, ends_at, time_zone) do
    local_start = DateTime.shift_zone!(starts_at, time_zone)
    # An event ending at midnight doesn't cover the next day.
    last = DateTime.shift_zone!(DateTime.add(ends_at, -1), time_zone)

    %{
      "all_day" => false,
      "starts_at" => format_local(starts_at, time_zone),
      "ends_at" => format_local(ends_at, time_zone),
      "start_date" => Date.to_iso8601(DateTime.to_date(local_start)),
      "end_date" =>
        Date.to_iso8601(Enum.max([DateTime.to_date(local_start), DateTime.to_date(last)], Date))
    }
  end

  # An all-day event offers 9:00 on its first day to 17:00 on its last if
  # it's switched to timed, as the Slack form does.
  defp all_day(first, last, time_zone) do
    %{
      "all_day" => true,
      "start_date" => Date.to_iso8601(first),
      "end_date" => Date.to_iso8601(last),
      "starts_at" => format_local(at_hour(first, 9, time_zone), time_zone),
      "ends_at" => format_local(at_hour(last, 17, time_zone), time_zone)
    }
  end

  defp at_hour(date, hour, time_zone),
    do: DateTime.add(Period.start_of_day(date, time_zone), hour * 3600)

  defp format_local(datetime, time_zone) do
    datetime
    |> DateTime.shift_zone!(time_zone)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> binary_part(0, 16)
  end

  # Browsers send `datetime-local` values without seconds.
  defp parse_local(value, time_zone) when is_binary(value) do
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> to_utc(naive, time_zone)
      {:error, _} -> nil
    end
  end

  defp parse_local(_value, _time_zone), do: nil

  defp to_utc(naive, time_zone) do
    case DateTime.from_naive(naive, time_zone) do
      {:ok, datetime} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      # A time skipped by DST: the first time after the gap.
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      # A time that happens twice: the first.
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  # The checkgroup sends `""` so the field is present when nothing is
  # checked. IDs that aren't UUIDs would make the channel query raise.
  defp channel_ids(ids) when is_list(ids) do
    for id <- ids, {:ok, id} <- [Ecto.UUID.cast(id)], uniq: true, do: id
  end

  defp channel_ids(_ids), do: []

  defp label_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end

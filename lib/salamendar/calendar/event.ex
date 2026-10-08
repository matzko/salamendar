defmodule Salamendar.Calendar.Event do
  @moduledoc """
  A calendar event, shown in one or more channels.

  An event is either all-day (`start_date`/`end_date`, no time zone) or timed
  (`starts_at`/`ends_at` in UTC). Both ranges are half-open, so a one-day
  all-day event on Oct 10 has `end_date` Oct 11.
  """

  use Salamendar.Schema
  import Ecto.Changeset

  alias Salamendar.Accounts.User
  alias Salamendar.Channels.Channel
  alias Salamendar.TimeZones

  @type t :: %__MODULE__{}

  @title_max_length 255

  schema "events" do
    field :slack_team_id, :string
    belongs_to :owner, User
    field :title, :string
    field :description, :string
    field :all_day, :boolean, default: false
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :start_date, :date
    field :end_date, :date
    field :time_zone, :string

    many_to_many :channels, Channel, join_through: "event_channels", on_replace: :delete

    timestamps()
  end

  @doc """
  Casts the user-editable fields. `slack_team_id` and `owner_id` are set on
  the struct by the caller.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :title,
      :description,
      :all_day,
      :starts_at,
      :ends_at,
      :start_date,
      :end_date,
      :time_zone
    ])
    |> validate_required([:slack_team_id, :title, :time_zone])
    |> validate_length(:title, max: @title_max_length)
    |> TimeZones.validate(:time_zone)
    |> validate_time_shape()
    |> assoc_constraint(:owner)
    |> check_constraint(:starts_at, name: :events_time_shape, message: "is invalid")
  end

  # Mirrors the `events_time_shape` CHECK constraint with readable errors.
  defp validate_time_shape(changeset) do
    if get_field(changeset, :all_day) do
      changeset
      |> validate_required([:start_date, :end_date])
      |> validate_blank([:starts_at, :ends_at], "must be blank for all-day events")
      |> validate_end_after_start(:start_date, :end_date, Date)
    else
      changeset
      |> validate_required([:starts_at, :ends_at])
      |> validate_blank([:start_date, :end_date], "must be blank for timed events")
      |> validate_end_after_start(:starts_at, :ends_at, DateTime)
    end
  end

  defp validate_blank(changeset, fields, message) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if is_nil(get_field(acc, field)), do: acc, else: add_error(acc, field, message)
    end)
  end

  defp validate_end_after_start(changeset, start_field, end_field, module) do
    start_value = get_field(changeset, start_field)
    end_value = get_field(changeset, end_field)

    if start_value && end_value && module.compare(end_value, start_value) != :gt do
      add_error(changeset, end_field, "must be after the start")
    else
      changeset
    end
  end
end

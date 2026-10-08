defmodule Salamendar.TimeZones do
  @moduledoc """
  Checks IANA time zone names (e.g. "America/Chicago") against the
  configured time zone database.
  """

  import Ecto.Changeset

  @doc """
  Returns true if `time_zone` is a zone the time zone database knows.
  """
  @spec valid?(term()) :: boolean()
  def valid?(time_zone) when is_binary(time_zone), do: match?({:ok, _}, DateTime.now(time_zone))
  def valid?(_), do: false

  @doc """
  Adds an error to `field` unless its new value is a valid time zone.
  """
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, time_zone ->
      if valid?(time_zone), do: [], else: [{field, "is not a valid time zone"}]
    end)
  end
end

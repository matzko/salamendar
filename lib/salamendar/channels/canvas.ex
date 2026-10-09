defmodule Salamendar.Channels.Canvas do
  @moduledoc """
  One of a channel's calendar canvases (`:month` or `:week`) and what was
  last rendered to it.
  """

  use Salamendar.Schema
  import Ecto.Changeset

  alias Salamendar.Channels.Channel

  @type t :: %__MODULE__{}
  @type kind :: :month | :week

  schema "channel_canvases" do
    belongs_to :channel, Channel
    field :kind, Ecto.Enum, values: [:month, :week]
    field :slack_canvas_id, :string
    field :rendered_period, :string
    field :content_hash, :string
    field :rendered_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(canvas, attrs) do
    canvas
    |> cast(attrs, [:kind, :slack_canvas_id, :rendered_period, :content_hash, :rendered_at])
    |> validate_required([:channel_id, :kind])
    |> assoc_constraint(:channel)
    |> check_constraint(:kind, name: :channel_canvases_kind)
    |> unique_constraint([:channel_id, :kind])
  end
end

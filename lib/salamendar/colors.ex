defmodule Salamendar.Colors do
  @moduledoc """
  The fixed palette that events are colored from.

  Colors are stored by key (`"red"`), never as hex, so the palette can be
  retuned in one place. Each has a text color that's readable on it (at
  least 4.5:1, WCAG AA) and an emoji for the Slack Home tab.

  The `users_color` CHECK constraint lists the keys too. Adding a color
  means a migration that replaces it; a test checks they match.
  """

  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Event

  @type color :: %{
          key: String.t(),
          name: String.t(),
          background: String.t(),
          text: String.t(),
          emoji: String.t()
        }

  @light "#ffffff"
  @dark "#1f1f1f"

  @palette [
    %{key: "red", name: "Red", background: "#d50000", text: @light, emoji: "🔴"},
    %{key: "orange", name: "Orange", background: "#ef6c00", text: @dark, emoji: "🟠"},
    %{key: "yellow", name: "Yellow", background: "#f6bf26", text: @dark, emoji: "🟡"},
    %{key: "green", name: "Green", background: "#0b8043", text: @light, emoji: "🟢"},
    %{key: "blue", name: "Blue", background: "#1a73e8", text: @light, emoji: "🔵"},
    %{key: "purple", name: "Purple", background: "#8e24aa", text: @light, emoji: "🟣"},
    %{key: "brown", name: "Brown", background: "#795548", text: @light, emoji: "🟤"},
    %{key: "graphite", name: "Graphite", background: "#616161", text: @light, emoji: "⚫"}
  ]

  @by_key Map.new(@palette, &{&1.key, &1})
  @keys Enum.map(@palette, & &1.key)
  @default "blue"

  @doc """
  The palette, in display order.
  """
  @spec all() :: [color()]
  def all, do: @palette

  @doc """
  Every color key, for validations and the CHECK constraints.
  """
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  The color for `key`, or nil.
  """
  @spec get(String.t() | nil) :: color() | nil
  def get(key), do: Map.get(@by_key, key)

  @doc """
  The color for events with nothing better to go on (e.g. an owner whose
  user row is gone).
  """
  @spec default() :: color()
  def default, do: Map.fetch!(@by_key, @default)

  @doc """
  `user`'s color: the one they picked, or one derived from their ID, so
  every user has a stable color without picking one.
  """
  @spec for_user(User.t()) :: color()
  def for_user(%User{color: key} = user) when is_binary(key), do: get(key) || derived(user)
  def for_user(%User{} = user), do: derived(user)

  @doc """
  The color `event` is shown in: its owner's color, or the default. The
  owner must be preloaded. (Labels, when they exist, will come first.)
  """
  @spec for_event(Event.t()) :: color()
  def for_event(%Event{owner: %User{} = owner}), do: for_user(owner)
  def for_event(%Event{}), do: default()

  defp derived(%User{id: id}), do: Enum.at(@palette, :erlang.phash2(id, length(@palette)))
end

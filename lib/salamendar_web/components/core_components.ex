defmodule SalamendarWeb.CoreComponents do
  @moduledoc """
  Shared UI components, styled by `assets/css/app.css`.

  Trimmed from what `mix phx.new` generates (no Tailwind, daisyUI or
  heroicons). Add components here as pages need them.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice. Clicking it dismisses it.

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["flash", "flash-#{@kind}"]}
      {@rest}
    >
      <p :if={@title} class="flash-title">{@title}</p>
      <p>{msg}</p>
      <button type="button" class="flash-close" aria-label="close">×</button>
    </div>
    """
  end

  @doc """
  Shows the element matching `selector`.
  """
  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector, time: 200, transition: {"fade-in", "fade-from", "fade-to"})
  end

  @doc """
  Hides the element matching `selector`.
  """
  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector, time: 200, transition: {"fade-out", "fade-to", "fade-from"})
  end
end

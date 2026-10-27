defmodule SalamendarWeb.CoreComponents do
  @moduledoc """
  Shared UI components, styled by `assets/css/app.css`.

  Trimmed from what `mix phx.new` generates (no Tailwind, daisyUI or
  heroicons). Add components here as pages need them.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
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
  Renders a button, or a link styled as one when given `href`, `navigate`
  or `patch`.

      <.button type="submit" variant="primary">Save</.button>
      <.button type="button" variant="danger" phx-click="delete">Delete</.button>
  """
  attr :variant, :string, values: [nil, "primary", "danger"], default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method name value disabled form type)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [
        "button",
        assigns.variant && "button-#{assigns.variant}",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  Renders a form input with its label and errors. Errors show only once the
  field has been used (`Phoenix.Component.used_input?/1`), as in
  `mix phx.new`.

  Types:

    * `"checkbox"`: a boolean, sent as `"true"` or `"false"`.
    * `"checkgroup"`: one checkbox per `options` entry (`{label, value}`),
      sent as a list. An empty hidden value keeps the list present when
      nothing is checked, so callers should drop `""`.
    * `"select"`: `options` as `{label, value}` pairs, or grouped as
      `{group, [{label, value}, ...]}` (rendered as `<optgroup>`s), after an
      optional `prompt` with an empty value.
    * `"textarea"`.
    * Anything else is an `<input type=...>`, such as `"text"`, `"date"` or
      `"datetime-local"`.

  `emoji` adds an emoji picker button and `:name` autocomplete to a text
  input or textarea (the `EmojiInput` hook in
  `assets/js/hooks/emoji_input.js`). Other types ignore it.

      <.input field={@form[:title]} label="Title" emoji />
      <.input field={@form[:channel_ids]} type="checkgroup" label="Channels" options={@options} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox checkgroup date datetime-local select text textarea hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:title]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"

  attr :options, :list,
    default: [],
    doc: "`{label, value}` pairs for checkgroup and select inputs"

  attr :prompt, :string, default: nil, doc: "the first, empty option of a select"
  attr :emoji, :boolean, default: false, doc: "emoji picker and autocomplete (text, textarea)"

  attr :rest, :global,
    include:
      ~w(autocomplete disabled form max maxlength min placeholder readonly required rows step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn ->
      if assigns.type == "checkgroup", do: field.name <> "[]", else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field">
      <label class="field-check">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} {@rest} />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "checkgroup"} = assigns) do
    assigns = assign(assigns, :selected, assigns.value |> List.wrap() |> Enum.map(&to_string/1))

    ~H"""
    <fieldset class="field" id={@id}>
      <legend :if={@label} class="field-label">{@label}</legend>
      <input type="hidden" name={@name} value="" disabled={@rest[:disabled]} />
      <label :for={{label, value} <- @options} class="field-check">
        <input
          type="checkbox"
          name={@name}
          value={value}
          checked={to_string(value) in @selected}
          {@rest}
        />
        {label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={["field-input", @errors != [] && "field-input-error"]}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["field", @emoji && "field-emoji"]} {emoji_hook(@emoji, @id)}>
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <.emoji_control emoji={@emoji} id={@id}>
        <textarea
          id={@id}
          name={@name}
          class={["field-input", @errors != [] && "field-input-error"]}
          {emoji_combobox(@emoji, @id)}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </.emoji_control>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    assigns = assign(assigns, :emoji, assigns.emoji and assigns.type == "text")

    ~H"""
    <div class={["field", @emoji && "field-emoji"]} {emoji_hook(@emoji, @id)}>
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <.emoji_control emoji={@emoji} id={@id}>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={["field-input", @errors != [] && "field-input-error"]}
          {emoji_combobox(@emoji, @id)}
          {@rest}
        />
      </.emoji_control>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp emoji_hook(true, id), do: [id: "#{id}-emoji", "phx-hook": "EmojiInput"]
  defp emoji_hook(false, _id), do: []

  # The input is a combobox for `:name` autocomplete. The hook sets
  # `aria-expanded` and `aria-activedescendant`, which re-renders would
  # otherwise reset.
  defp emoji_combobox(true, id) do
    [
      role: "combobox",
      "aria-autocomplete": "list",
      "aria-expanded": "false",
      "aria-controls": "#{id}-emoji-suggest",
      "phx-mounted": JS.ignore_attributes(["aria-expanded", "aria-activedescendant"])
    ]
  end

  defp emoji_combobox(false, _id), do: []

  attr :emoji, :boolean, required: true
  attr :id, :any, required: true
  slot :inner_block, required: true

  # The input, the picker button over its right edge, a popup the
  # `EmojiInput` hook draws into, and the autocomplete list. All but the
  # input are inside `phx-update="ignore"`, so re-renders (such as
  # `phx-change` validation) don't reset them while open.
  defp emoji_control(%{emoji: true} = assigns) do
    ~H"""
    <div class="field-emoji-control">
      {render_slot(@inner_block)}
      <div id={"#{@id}-emoji-ui"} phx-update="ignore">
        <button
          type="button"
          class="field-emoji-button"
          aria-label="Insert emoji"
          aria-haspopup="dialog"
          aria-expanded="false"
          aria-controls={"#{@id}-emoji-popup"}
        >
          🙂
        </button>
        <div id={"#{@id}-emoji-popup"} class="emoji-popup" hidden></div>
        <ul id={"#{@id}-emoji-suggest"} class="emoji-suggest" role="listbox" hidden></ul>
      </div>
    </div>
    """
  end

  defp emoji_control(assigns), do: ~H"{render_slot(@inner_block)}"

  defp error(assigns) do
    ~H"""
    <p class="field-error">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  Fills an error message's `%{...}` placeholders from its options.
  """
  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
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

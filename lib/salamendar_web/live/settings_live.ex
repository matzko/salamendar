defmodule SalamendarWeb.SettingsLive do
  @moduledoc """
  The settings page at `/settings`: the user's own color, and the labels
  they can use.

  The user's color is used for their unlabeled events, so changing it
  refreshes every channel their events are in. Labels come in two lists,
  shared and personal; rows the user may change (see
  `Salamendar.Labels.can_change?/2`) can be renamed, recolored or deleted
  in place, one at a time (`:editing`).

  Contexts check permissions again on every change, so a refused change
  (someone else changed or deleted the label meanwhile) just reloads the
  lists with a flash.
  """
  use SalamendarWeb, :live_view

  alias Salamendar.{Accounts, Calendar, Colors, Labels, Repo}
  alias Salamendar.Accounts.User
  alias Salamendar.Calendar.Changes
  alias Salamendar.Labels.Label
  alias Salamendar.Workers.PublishHome

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       editing: nil,
       edit_form: nil,
       new_forms: %{shared: new_form(:shared), personal: new_form(:personal)}
     )
     |> load_labels()}
  end

  @impl true
  def handle_event("set_color", %{"color" => key}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_color(user, key) do
      {:ok, user} ->
        :ok = Changes.broadcast(Calendar.owned_event_channel_ids(user), user.id)
        {:ok, _} = PublishHome.enqueue(user.slack_team_id, user.slack_user_id)
        {:noreply, assign(socket, current_user: user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't change your color.")}
    end
  end

  def handle_event("create", %{"scope" => scope, "label" => params}, socket)
      when scope in ["shared", "personal"] and is_map(params) do
    scope = String.to_existing_atom(scope)

    case Labels.create_label(socket.assigns.current_user, params, scope) do
      {:ok, label} ->
        {:noreply,
         socket
         |> put_new_form(scope, new_form(scope))
         |> put_flash(:info, "Added “#{label.name}”.")
         |> load_labels()}

      {:error, changeset} ->
        {:noreply, put_new_form(socket, scope, new_form(scope, params, changeset.errors))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find_label(socket, id) do
      %Label{} = label ->
        if Labels.can_change?(socket.assigns.current_user, label) do
          {:noreply,
           assign(socket,
             editing: label.id,
             edit_form: edit_form(%{"name" => label.name, "color" => label.color})
           )}
        else
          {:noreply, socket}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing: nil, edit_form: nil)}

  def handle_event("update", %{"label" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user

    with %Label{} = label <- find_label(socket, socket.assigns.editing),
         {:ok, label, channel_ids} <-
           Labels.update_label(user, label, Map.take(params, ["name", "color"])) do
      {:noreply,
       socket
       |> after_change(label, channel_ids)
       |> assign(editing: nil, edit_form: nil)
       |> load_labels()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, edit_form: edit_form(params, changeset.errors))}

      nil ->
        {:noreply, refused(socket, :not_found)}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %Label{} = label <- find_label(socket, id),
         {:ok, label, channel_ids} <- Labels.delete_label(user, label) do
      {:noreply,
       socket
       |> after_change(label, channel_ids)
       |> assign(editing: nil, edit_form: nil)
       |> put_flash(:info, "Deleted “#{label.name}”.")
       |> load_labels()}
    else
      nil -> {:noreply, refused(socket, :not_found)}
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  # Tells open calendars that the label's events changed. Personal labels'
  # events are all the user's own, which also reaches their own topic.
  defp after_change(socket, label, channel_ids) do
    user = socket.assigns.current_user
    :ok = Changes.broadcast(channel_ids, if(label.user_id, do: user.id))
    {:ok, _} = PublishHome.enqueue(user.slack_team_id, user.slack_user_id)
    socket
  end

  defp refused(socket, reason) do
    message =
      case reason do
        :forbidden -> "Only the person who made that label can change it."
        :not_found -> "That label was deleted."
      end

    socket
    |> assign(editing: nil, edit_form: nil)
    |> put_flash(:error, message)
    |> load_labels()
  end

  defp load_labels(socket) do
    %{shared: shared, mine: mine} = Labels.list_labels(socket.assigns.current_user)
    shared = Repo.preload(shared, :created_by)

    assign(socket,
      labels: %{shared: shared, personal: mine},
      counts: Labels.count_events(shared ++ mine)
    )
  end

  defp find_label(socket, id) do
    %{shared: shared, personal: personal} = socket.assigns.labels
    Enum.find(shared ++ personal, &(&1.id == id))
  end

  # Forms are built from params, as in `CalendarLive`, with the changeset's
  # errors.
  defp new_form(scope, params \\ %{}, errors \\ []),
    do: to_form(params, as: :label, id: "new-#{scope}", errors: errors)

  defp edit_form(params, errors \\ []),
    do: to_form(params, as: :label, id: "edit-label", errors: errors)

  defp put_new_form(socket, scope, form),
    do: update(socket, :new_forms, &Map.put(&1, scope, form))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="settings">
        <header class="settings-header">
          <h1>Settings</h1>
          <.link navigate={~p"/"}>Back to the calendar</.link>
        </header>

        <section aria-labelledby="your-color">
          <h2 id="your-color">Your color</h2>
          <p class="muted">Your events without a label are shown in this color.</p>
          <form id="color-form" phx-change="set_color">
            <.color_picker
              name="color"
              value={Colors.for_user(@current_user).key}
              legend="Your color"
            />
          </form>
        </section>

        <section aria-labelledby="labels">
          <h2 id="labels">Labels</h2>
          <p class="muted">
            A label's color is used for every event it's on, for everyone.
            Shared labels can go on anyone's events; yours only on your own.
          </p>

          <.label_list
            title="Shared"
            scope={:shared}
            labels={@labels.shared}
            counts={@counts}
            current_user={@current_user}
            editing={@editing}
            edit_form={@edit_form}
            new_form={@new_forms.shared}
          />

          <.label_list
            title="Mine"
            scope={:personal}
            labels={@labels.personal}
            counts={@counts}
            current_user={@current_user}
            editing={@editing}
            edit_form={@edit_form}
            new_form={@new_forms.personal}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :scope, :atom, required: true
  attr :labels, :list, required: true
  attr :counts, :map, required: true
  attr :current_user, User, required: true
  attr :editing, :any, required: true
  attr :edit_form, :any, required: true
  attr :new_form, Phoenix.HTML.Form, required: true

  defp label_list(assigns) do
    ~H"""
    <div class="label-list" id={"labels-#{@scope}"}>
      <h3>{@title}</h3>

      <ul>
        <li :for={label <- @labels} id={"label-#{label.id}"} class="label-row">
          <%= if @editing == label.id do %>
            <.form for={@edit_form} phx-submit="update" class="label-form">
              <.input field={@edit_form[:name]} label="Name" maxlength="50" emoji />
              <.color_picker
                name={@edit_form[:color].name}
                value={@edit_form[:color].value}
                legend="Color"
                errors={@edit_form[:color].errors}
              />
              <div class="label-form-actions">
                <.button type="submit" variant="primary">Save</.button>
                <.button type="button" phx-click="cancel_edit">Cancel</.button>
              </div>
            </.form>
          <% else %>
            <span class="swatch" style={"background: #{Colors.get(label.color).background}"}></span>
            <span class="label-name">{label.name}</span>
            <%= if Labels.can_change?(@current_user, label) do %>
              <span class="label-actions">
                <.button type="button" phx-click="edit" phx-value-id={label.id}>Edit</.button>
                <.button
                  type="button"
                  variant="danger"
                  phx-click="delete"
                  phx-value-id={label.id}
                  data-confirm={delete_confirmation(label, Map.get(@counts, label.id, 0))}
                >
                  Delete
                </.button>
              </span>
            <% else %>
              <span class="muted label-maker">Made by {maker_name(label)}</span>
            <% end %>
          <% end %>
        </li>
      </ul>

      <p :if={@labels == []} class="muted">No labels yet.</p>

      <.form for={@new_form} phx-submit="create" class="label-form label-new">
        <input type="hidden" name="scope" value={@scope} />
        <.input field={@new_form[:name]} label="New label" maxlength="50" emoji />
        <.color_picker
          name={@new_form[:color].name}
          value={@new_form[:color].value}
          legend="Color"
          errors={@new_form[:color].errors}
        />
        <.button type="submit">Add label</.button>
      </.form>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :legend, :string, required: true
  attr :errors, :list, default: []

  defp color_picker(assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.errors, &translate_error/1))

    ~H"""
    <fieldset class="field color-picker">
      <legend class="visually-hidden">{@legend}</legend>
      <label :for={color <- Colors.all()} class="color-option" title={color.name}>
        <input type="radio" name={@name} value={color.key} checked={color.key == @value} />
        <span class="swatch" style={"background: #{color.background}"}></span>
        <span class="visually-hidden">{color.name}</span>
      </label>
      <p :for={msg <- @errors} class="field-error">{msg}</p>
    </fieldset>
    """
  end

  defp delete_confirmation(label, count) do
    lose =
      case count do
        0 -> ""
        1 -> " 1 event will lose this color."
        n -> " #{n} events will lose this color."
      end

    shared =
      if is_nil(label.user_id) and count > 0,
        do: " Shared labels can be on anyone's events.",
        else: ""

    "Delete “#{label.name}”?" <> lose <> shared
  end

  defp maker_name(%Label{created_by: %User{name: name}}) when is_binary(name) and name != "",
    do: name

  defp maker_name(%Label{created_by: %User{slack_user_id: slack_user_id}}),
    do: slack_user_id
end

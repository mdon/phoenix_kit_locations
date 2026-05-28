defmodule PhoenixKitLocations.Web.LocationFormLive do
  @moduledoc "Create/edit form for locations with multilang, type toggles, and feature checkboxes."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.{Location, Space}
  alias PhoenixKitLocations.Spaces

  @translatable_fields ["name", "description", "public_notes"]
  @space_translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}
  @space_preserve_fields %{"status" => :status, "kind" => :kind, "parent_uuid" => :parent_uuid}

  # Feature keys are paired with a translatable label at render time via
  # `feature_label/1` — keeping the call site literal is what lets
  # `mix gettext.extract` (run in core) pick these up.
  @feature_keys ~w(
    wheelchair_accessible
    elevator
    parking
    public_transport
    loading_dock
    air_conditioning
    wifi
    restrooms
    security
    cctv
  )

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_location(action, params) do
      {:not_found, uuid} ->
        Logger.info("Location not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      {location, changeset, linked_type_uuids} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, location),
           action: action,
           location: location,
           all_types: safe_list_location_types(),
           linked_type_uuids: MapSet.new(linked_type_uuids),
           features: location.features || %{},
           feature_keys: @feature_keys,
           address_warning: nil
         )
         |> assign_form(changeset)
         |> mount_multilang()
         |> Attachments.mount_attachments(location)
         |> Attachments.allow_attachment_upload()
         |> assign_spaces_state(action, location)}
    end
  end

  # ── Spaces state ─────────────────────────────────────────────────

  # On :new, spaces don't exist yet (location not persisted) — show
  # nothing. On :edit, load the tree-walk list and select the first
  # space as the active tab (or :new for the blank-form tab when the
  # location has no spaces yet). The list query is rescued so a
  # missing migration (V122 not yet applied) doesn't blow up the form.
  defp assign_spaces_state(socket, :new, _location) do
    assign(socket,
      spaces: [],
      active_space_uuid: nil,
      space: nil,
      space_changeset: nil,
      space_form: nil
    )
  end

  defp assign_spaces_state(socket, :edit, location) do
    spaces = safe_list_spaces(location.uuid)

    active =
      case spaces do
        [] -> :new
        [first | _] -> first.uuid
      end

    assign_active_space(socket, spaces, active, location.uuid)
  end

  defp safe_list_spaces(location_uuid) do
    Spaces.list_for_location(location_uuid)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[LocationFormLive] list spaces failed: #{Exception.message(e)}")
      []
  end

  defp assign_active_space(socket, spaces, :new, location_uuid) do
    space = %Space{location_uuid: location_uuid, kind: "room", status: "active"}
    cs = Spaces.change_space(space)

    socket
    |> assign(spaces: spaces, active_space_uuid: :new, space: space)
    |> assign_space_form(cs)
  end

  defp assign_active_space(socket, spaces, uuid, _location_uuid) do
    case Enum.find(spaces, &(&1.uuid == uuid)) do
      nil ->
        # UUID no longer in the list (just deleted, etc.) — fall back to :new.
        assign_active_space(socket, spaces, :new, socket.assigns.location.uuid)

      space ->
        cs = Spaces.change_space(space)

        socket
        |> assign(spaces: spaces, active_space_uuid: uuid, space: space)
        |> assign_space_form(cs)
    end
  end

  defp assign_space_form(socket, %Ecto.Changeset{} = cs) do
    assign(socket, space_changeset: cs, space_form: to_form(cs, as: :space))
  end

  defp load_location(:new, _params) do
    location = %Location{}
    {location, Locations.change_location(location), []}
  end

  defp load_location(:edit, params) do
    case Locations.get_location(params["uuid"]) do
      nil ->
        {:not_found, params["uuid"]}

      location ->
        {location, Locations.change_location(location), safe_linked_type_uuids(location)}
    end
  end

  defp safe_linked_type_uuids(location) do
    Locations.linked_type_uuids(location.uuid)
  rescue
    error ->
      Logger.error("Failed to load linked types for #{location.uuid}: #{inspect(error)}")
      []
  end

  defp safe_list_location_types do
    Locations.list_location_types(status: "active")
  rescue
    error ->
      Logger.error("Failed to load location types: #{inspect(error)}")
      []
  end

  defp page_title(:new, _location), do: gettext("New Location")

  defp page_title(:edit, location),
    do: gettext("Edit %{name}", name: location.name)

  # Keeps the `:changeset` assign (for `<.translatable_field>`) and `:form`
  # (for core `<.input>` / `<.select>` / `<.textarea>` which want a
  # `Phoenix.HTML.FormField` via `@form[:field]`) in sync.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :location))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"location" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    params =
      params
      |> Map.put("features", socket.assigns.features)
      |> merge_running_changes(socket.assigns.changeset)

    changeset =
      socket.assigns.location
      |> Locations.change_location(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign_form(changeset) |> assign(:address_warning, nil)}
  end

  # The Location form renders as TWO `<.form>` elements (Public Info on
  # top, Files + Internal on the bottom, with the Spaces card sitting
  # between them) — both bound to the same `@form`. A `phx-change` from
  # either half only submits its own inputs, so a naive rebuild from
  # `socket.assigns.location` would clobber the OTHER form's
  # in-progress edits. We merge the running changeset's `changes` map
  # back in so every validate keeps the full edit picture.
  defp merge_running_changes(params, %Ecto.Changeset{changes: changes}) do
    existing =
      Map.new(changes, fn {k, v} -> {Atom.to_string(k), v} end)

    Map.merge(existing, params)
  end

  def handle_event("toggle_type", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_type_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_type_uuids, linked)}
  end

  def handle_event("toggle_feature", %{"key" => key}, socket) do
    features = socket.assigns.features
    current = Map.get(features, key, false)
    features = Map.put(features, key, !current)
    {:noreply, assign(socket, :features, features)}
  end

  # `phx-blur` payloads carry only event metadata (`%{"key" => ..., "value" => ...}`),
  # not the form's serialized params — Phoenix LV's `phx-change` is the only event
  # that serializes the form. Matching `%{"location" => params}` here crashed the LV
  # on every address-field blur with a FunctionClauseError, which auto-reconnected
  # the form and wiped every in-progress field. Read from the changeset instead,
  # which `phx-change="validate"` keeps up-to-date with each keystroke (no debounce
  # on `<.input>`).
  def handle_event("check_address", _params, socket) do
    changeset = socket.assigns.changeset

    exclude_uuid =
      if socket.assigns.action == :edit, do: socket.assigns.location.uuid, else: nil

    similar =
      Locations.find_similar_addresses(
        Ecto.Changeset.get_field(changeset, :address_line_1),
        Ecto.Changeset.get_field(changeset, :city),
        Ecto.Changeset.get_field(changeset, :postal_code),
        exclude_uuid
      )

    warning =
      if similar != [] do
        names = Enum.map_join(similar, ", ", & &1.name)
        gettext("Similar address found at: %{names}", names: names)
      end

    {:noreply, assign(socket, :address_warning, warning)}
  end

  def handle_event("save", %{"location" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    params =
      params
      |> Map.put("features", socket.assigns.features)
      |> Attachments.inject_attachment_data(socket)
      |> merge_running_changes(socket.assigns.changeset)

    save_location(socket, socket.assigns.action, params)
  end

  # ── Attachments (featured image modal + inline files dropzone) ──

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("remove_file", %{"uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, uuid)

  def handle_event("clear_featured_image", _params, socket),
    do: Attachments.clear_featured_image(socket)

  # ── Spaces (sub-form within the Location page on :edit) ─────────

  def handle_event("select_space", %{"uuid" => "new"}, socket) do
    {:noreply,
     assign_active_space(socket, socket.assigns.spaces, :new, socket.assigns.location.uuid)}
  end

  def handle_event("select_space", %{"uuid" => uuid}, socket) do
    {:noreply,
     assign_active_space(socket, socket.assigns.spaces, uuid, socket.assigns.location.uuid)}
  end

  def handle_event("validate_space", %{"space" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @space_translatable_fields,
        changeset: socket.assigns.space_changeset,
        preserve_fields: @space_preserve_fields
      )

    cs =
      socket.assigns.space
      |> Spaces.change_space(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_space_form(socket, cs)}
  end

  def handle_event("save_space", %{"space" => params}, socket) do
    params =
      params
      |> merge_translatable_params(socket, @space_translatable_fields,
        changeset: socket.assigns.space_changeset,
        preserve_fields: @space_preserve_fields
      )
      |> Map.put("location_uuid", socket.assigns.location.uuid)
      |> normalize_parent_uuid()

    result =
      case socket.assigns.active_space_uuid do
        :new -> Spaces.create_space(params, actor_opts(socket))
        _uuid -> Spaces.update_space(socket.assigns.space, params, actor_opts(socket))
      end

    handle_space_save_result(socket, result)
  end

  def handle_event("delete_space", _params, socket) do
    case socket.assigns.active_space_uuid do
      :new ->
        # No persisted row — just reset the blank form.
        {:noreply,
         assign_active_space(socket, socket.assigns.spaces, :new, socket.assigns.location.uuid)}

      _uuid ->
        case Spaces.delete_space(socket.assigns.space, actor_opts(socket)) do
          {:ok, _} ->
            spaces = safe_list_spaces(socket.assigns.location.uuid)

            next_active =
              case spaces do
                [] -> :new
                [first | _] -> first.uuid
              end

            {:noreply,
             socket
             |> put_flash(:info, gettext("Space deleted."))
             |> assign_active_space(spaces, next_active, socket.assigns.location.uuid)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete space."))}
        end
    end
  end

  # Form params arrive with `""` for the empty parent <select> option;
  # map that to `nil` so context-side validation doesn't try to look up
  # the empty-string "uuid". Same shape catalogue uses for its picker.
  defp normalize_parent_uuid(%{"parent_uuid" => ""} = params),
    do: Map.put(params, "parent_uuid", nil)

  defp normalize_parent_uuid(params), do: params

  defp handle_space_save_result(socket, {:ok, saved}) do
    spaces = safe_list_spaces(socket.assigns.location.uuid)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Space saved."))
     |> assign_active_space(spaces, saved.uuid, socket.assigns.location.uuid)}
  end

  defp handle_space_save_result(socket, {:error, %Ecto.Changeset{} = cs}) do
    {:noreply, assign_space_form(socket, Map.put(cs, :action, :validate))}
  end

  defp handle_space_save_result(socket, {:error, reason}) do
    {:noreply, put_flash(socket, :error, Errors.message(reason))}
  end

  defp save_location(socket, :new, params) do
    case Locations.create_location(params, actor_opts(socket)) do
      {:ok, location} ->
        _ = Attachments.maybe_rename_pending_folder(socket, location)
        sync_types_and_redirect(socket, location.uuid, gettext("Location created."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_location(socket, :edit, params) do
    case Locations.update_location(socket.assigns.location, params, actor_opts(socket)) do
      {:ok, location} ->
        sync_types_and_redirect(socket, location.uuid, gettext("Location updated."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # Defensive catch-all for unmatched messages — e.g. future PubSub
  # broadcasts, multilang hook fall-throughs. Logs at :debug per the
  # workspace sync precedent at AGENTS.md:678-680.
  def handle_info(msg, socket) do
    Logger.debug("[LocationFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp sync_types_and_redirect(socket, location_uuid, message) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    case Locations.sync_location_types(location_uuid, type_uuids, actor_opts(socket)) do
      {:ok, _sync_state} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Paths.index())}

      {:error, _} ->
        Logger.error("Failed to sync location types for #{location_uuid}")

        {:noreply,
         socket
         |> put_flash(:warning, Errors.message(:type_assignment_failed))
         |> push_navigate(to: Paths.index())}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Folder-scoped media selector (featured-image picker). Inline
           files dropzone in the Files card below uses the LV upload
           channel directly — modal is featured-image-only for now. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="location-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.admin_page_header
        back={Paths.index()}
        title={@page_title}
        subtitle={if @action == :new, do: gettext("Add a new location."), else: gettext("Update location details.")}
      />

      <%!-- Two `<.form>` blocks bound to the same `@form` so the Spaces
           card can sit between them without HTML's no-nested-forms
           rule biting. Both have phx-change="validate" / phx-submit="save".
           See `merge_running_changes/2` for why the validate / save
           handlers carry forward the running changeset's `changes`. --%>
      <.form
        for={@form}
        id="location-form-top"
        action="#"
        phx-change="validate"
        phx-submit="save"
      >
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- PUBLIC INFORMATION                                     --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg">
          <%!-- Translatable fields (name, description, public notes) --%>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class="card-body pb-0 pt-4"
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-0 flex flex-col gap-5"
          >
            <:skeleton>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-14"></div></div>
                <div class="skeleton h-12 w-full rounded-lg"></div>
              </div>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-24"></div></div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-20"></div></div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
            </:skeleton>
            <div class="card-body pt-0 flex flex-col gap-5">
              <.translatable_field
                field_name="name"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Name")}
                placeholder={gettext("e.g., Main Office, Downtown Showroom")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Description")}
                type="textarea"
                placeholder={gettext("Brief description of this location...")}
                class="w-full"
              />

              <.translatable_field
                field_name="public_notes"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:public_notes}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Public Notes")}
                type="textarea"
                placeholder={gettext("e.g., Bell is broken — knock loudly, entrance from side street...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <.section_heading icon="hero-map-pin">{gettext("Address")}</.section_heading>

            <div :if={@address_warning} class="alert alert-warning text-sm py-2">
              <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0" />
              <span>{@address_warning}</span>
            </div>

            <.input
              field={@form[:address_line_1]}
              type="text"
              label={gettext("Address Line 1")}
              placeholder={gettext("Street address, P.O. box")}
              phx-blur="check_address"
            />

            <.input
              field={@form[:address_line_2]}
              type="text"
              label={gettext("Address Line 2")}
              placeholder={gettext("Apartment, suite, unit, building, floor")}
            />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:city]}
                type="text"
                label={gettext("City")}
                phx-blur="check_address"
              />
              <.input field={@form[:state]} type="text" label={gettext("State / Region")} />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:postal_code]}
                type="text"
                label={gettext("Postal Code")}
                phx-blur="check_address"
              />
              <.input field={@form[:country]} type="text" label={gettext("Country")} />
            </div>

            <div class="divider my-0"></div>

            <.section_heading icon="hero-envelope">{gettext("Contact")}</.section_heading>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.input
                field={@form[:phone]}
                type="tel"
                label={gettext("Phone")}
                placeholder={gettext("+1 234 567 890")}
              />
              <.input
                field={@form[:email]}
                type="email"
                label={gettext("Email")}
                placeholder={gettext("location@example.com")}
              />
              <.input
                field={@form[:website]}
                type="url"
                label={gettext("Website")}
                placeholder={gettext("https://...")}
              />
            </div>

            <div class="divider my-0"></div>

            <.section_heading icon="hero-check-circle">{gettext("Features & Amenities")}</.section_heading>

            <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
              <label
                :for={key <- @feature_keys}
                class="flex items-center gap-2 cursor-pointer select-none"
                phx-click="toggle_feature"
                phx-value-key={key}
              >
                <input type="checkbox" class="checkbox checkbox-sm checkbox-primary" checked={Map.get(@features, key, false)} tabindex="-1" />
                <span class="label-text text-sm">{feature_label(key)}</span>
              </label>
            </div>
          </div>
        </div>
      </.form>

      <%!-- ═══════════════════════════════════════════════════════ --%>
      <%!-- SPACES (rooms / floors / zones) — edit mode only       --%>
      <%!-- Sits between the two halves of the Location form so it  --%>
      <%!-- visually reads as a subdivision of the address above.   --%>
      <%!-- ═══════════════════════════════════════════════════════ --%>
      <%= if @action == :edit do %>
        {render_spaces_section(assigns)}
      <% end %>

      <.form
        for={@form}
        id="location-form-bottom"
        action="#"
        phx-change="validate"
        phx-submit="save"
      >
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- FILES & FEATURED IMAGE                                --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-4">
            <div class="flex items-center justify-between">
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-photo" class="w-4 h-4" /> {gettext("Featured Image")}
              </h2>
              <span class="text-xs text-base-content/50">
                {gettext("Shown alongside this location in listings.")}
              </span>
            </div>

            <%= if @featured_image_file do %>
              <div class="flex items-center gap-4">
                <a
                  href={URLSigner.signed_url(@featured_image_uuid, "original")}
                  target="_blank"
                  rel="noopener"
                  class="shrink-0"
                  title={gettext("Open original")}
                >
                  <img
                    src={URLSigner.signed_url(@featured_image_uuid, "thumbnail")}
                    alt={@featured_image_file.original_file_name}
                    class="w-24 h-24 rounded-md object-cover bg-base-200 border border-base-300"
                  />
                </a>
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium truncate">{@featured_image_file.original_file_name}</p>
                  <p class="text-xs text-base-content/50">{Attachments.format_file_size(@featured_image_file.size)}</p>
                </div>
                <div class="flex flex-col gap-2">
                  <button type="button" phx-click="open_featured_image_picker" class="btn btn-sm btn-outline">
                    {gettext("Change")}
                  </button>
                  <button
                    type="button"
                    phx-click="clear_featured_image"
                    phx-disable-with={gettext("Removing...")}
                    class="btn btn-sm btn-ghost"
                  >
                    {gettext("Remove")}
                  </button>
                </div>
              </div>
            <% else %>
              <div class="flex items-center justify-between py-4 border border-dashed border-base-300 rounded-md px-4">
                <div class="flex items-center gap-3 text-base-content/60">
                  <.icon name="hero-photo" class="w-6 h-6" />
                  <span class="text-sm">{gettext("No featured image set.")}</span>
                </div>
                <button type="button" phx-click="open_featured_image_picker" class="btn btn-sm btn-primary">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Set featured image")}
                </button>
              </div>
            <% end %>

            <div class="divider my-0"></div>

            <div class="flex flex-col gap-0.5">
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-paper-clip" class="w-4 h-4" /> {gettext("Attached Files")}
                <span :if={@files_state.files != []} class="badge badge-sm badge-ghost ml-1">
                  {length(@files_state.files)}
                </span>
              </h2>
              <p class="text-xs text-base-content/50">
                {gettext("Floor plans, brochures, certificates. Any file type is accepted.")}
              </p>
            </div>

            <label
              for={@uploads.attachment_files.ref}
              class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
              phx-drop-target={@uploads.attachment_files.ref}
            >
              <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-base-content/40" />
              <div class="text-sm text-base-content/60">
                <span class="font-medium text-primary">{gettext("Click to upload")}</span>
                <span>{gettext(" or drag & drop")}</span>
              </div>
              <.live_file_input upload={@uploads.attachment_files} class="hidden" />
            </label>

            <div :if={@uploads.attachment_files.entries != []} class="flex flex-col gap-2">
              <div
                :for={entry <- @uploads.attachment_files.entries}
                class="flex items-center gap-3 rounded-md border border-base-300 bg-base-100 p-2"
              >
                <.icon name="hero-cloud-arrow-up" class="w-4 h-4 text-base-content/60 shrink-0" />
                <div class="flex-1 min-w-0">
                  <p class="text-sm truncate">{entry.client_name}</p>
                  <progress class="progress progress-primary w-full h-1 mt-1" value={entry.progress} max="100"></progress>
                </div>
                <span class="text-xs text-base-content/50 tabular-nums">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-xs btn-square"
                  title={gettext("Cancel")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>

            <p :for={err <- upload_errors(@uploads.attachment_files)} class="text-xs text-error">
              {Attachments.upload_error_message(err)}
            </p>

            <%= if @files_state.files == [] do %>
              <div class="flex flex-col items-center gap-2 py-10 text-center border border-dashed border-base-300 rounded-md">
                <.icon name="hero-paper-clip" class="w-8 h-8 text-base-content/30" />
                <p class="text-sm text-base-content/50">{gettext("No files attached yet.")}</p>
              </div>
            <% else %>
              <ul class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <li
                  :for={file <- @files_state.files}
                  class="flex items-center gap-3 rounded-md border border-base-300 bg-base-200/30 p-3"
                >
                  <%= if file.file_type == "image" do %>
                    <a
                      href={URLSigner.signed_url(file.uuid, "original")}
                      target="_blank"
                      rel="noopener"
                      class="shrink-0"
                    >
                      <img
                        src={URLSigner.signed_url(file.uuid, "thumbnail")}
                        alt={file.original_file_name}
                        class="w-14 h-14 rounded object-cover bg-base-200 border border-base-300"
                      />
                    </a>
                  <% else %>
                    <a
                      href={URLSigner.signed_url(file.uuid, "original")}
                      target="_blank"
                      rel="noopener"
                      class="shrink-0 flex items-center justify-center w-14 h-14 rounded bg-base-200 border border-base-300 text-base-content/60"
                      title={gettext("Download")}
                    >
                      <.icon name={Attachments.file_icon(file)} class="w-6 h-6" />
                    </a>
                  <% end %>
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium truncate" title={file.original_file_name}>
                      {file.original_file_name}
                    </p>
                    <p class="text-xs text-base-content/50">
                      {Attachments.format_file_size(file.size)} · {file.file_type}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="remove_file"
                    phx-value-uuid={file.uuid}
                    phx-disable-with={gettext("Removing...")}
                    data-confirm={gettext("Remove this file from the location? If it's not attached to any other resource, it will be moved to trash (admins can restore).")}
                    class="btn btn-ghost btn-xs btn-square"
                    title={gettext("Remove from location")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- INTERNAL                                               --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-5">
            <.section_heading icon="hero-lock-closed">{gettext("Internal")}</.section_heading>
            <p class="text-sm text-base-content/50 -mt-3">
              {gettext("This information is only visible to administrators.")}
            </p>

            <.textarea
              field={@form[:notes]}
              label={gettext("Internal Notes")}
              rows="3"
              placeholder={gettext("Notes only visible to admins...")}
              class="min-h-[5rem]"
            />

            <.select
              field={@form[:status]}
              label={gettext("Status")}
              options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
              class="transition-colors focus-within:select-primary"
            />

            <%!-- Location types --%>
            <div :if={@all_types != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <.section_heading icon="hero-tag">{gettext("Location Types")}</.section_heading>
              <p class="text-sm text-base-content/50 -mt-2">
                {gettext("Click to toggle. A location can have multiple types.")}
              </p>

              <div class="flex flex-wrap gap-2">
                <label
                  :for={t <- @all_types}
                  class={[
                    "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                    if(MapSet.member?(@linked_type_uuids, t.uuid),
                      do: "badge-primary",
                      else: "badge-ghost hover:badge-outline"
                    )
                  ]}
                  phx-click="toggle_type"
                  phx-value-uuid={t.uuid}
                >
                  <.icon
                    :if={MapSet.member?(@linked_type_uuids, t.uuid)}
                    name="hero-check"
                    class="h-3.5 w-3.5"
                  />
                  {t.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.index()} class="btn btn-ghost">{gettext("Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                disabled={@uploads.attachment_files.entries != []}
                phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
              >
                {cond do
                  @uploads.attachment_files.entries != [] -> gettext("Waiting for uploads...")
                  @action == :new -> gettext("Create Location")
                  true -> gettext("Save Changes")
                end}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  # The Spaces section is its own `<.form>` element — a sibling of the
  # two halves of the Location form, NOT nested (HTML forbids nested
  # forms). Each space has its own validate/save cycle; the Location's
  # Save button doesn't bundle space changes.
  defp render_spaces_section(assigns) do
    assigns =
      assigns
      |> assign(
        :space_lang_data,
        space_lang_data(assigns[:space_changeset], assigns.current_lang, assigns.multilang_enabled)
      )
      |> assign(:parent_options, parent_options(assigns.spaces, assigns[:active_space_uuid]))
      |> assign(:kind_options, kind_options())

    ~H"""
    <div class="card bg-base-100 shadow-lg mt-6">
      <div class="card-body flex flex-col gap-4">
        <div class="flex flex-col gap-0.5">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-squares-2x2" class="w-4 h-4" /> {gettext("Spaces")}
            <span :if={@spaces != []} class="badge badge-sm badge-ghost ml-1">
              {length(@spaces)}
            </span>
          </h2>
          <p class="text-xs text-base-content/50">
            {gettext("Break this location into rooms, floors, or zones inside the building above.")}
          </p>
        </div>

        <%!-- Tab strip only when there's something to switch between.
             When the location has no spaces yet, the form below stands
             alone as the "add the first space" form — a single +Add
             tab on its own reads as awkward chrome. --%>
        <div
          :if={@spaces != []}
          role="tablist"
          class="tabs tabs-bordered overflow-x-auto flex-nowrap"
        >
          <button
            :for={s <- @spaces}
            type="button"
            phx-click="select_space"
            phx-value-uuid={s.uuid}
            class={[
              "tab whitespace-nowrap",
              if(@active_space_uuid == s.uuid, do: "tab-active", else: "")
            ]}
            title={space_tab_label(s, @spaces)}
          >
            <span class="text-xs">{space_tab_label(s, @spaces)}</span>
          </button>
          <button
            type="button"
            phx-click="select_space"
            phx-value-uuid="new"
            class={[
              "tab whitespace-nowrap",
              if(@active_space_uuid == :new, do: "tab-active", else: "")
            ]}
          >
            <.icon name="hero-plus" class="w-4 h-4 mr-1" />
            <span class="text-xs">{gettext("Add space")}</span>
          </button>
        </div>

        <.form
          for={@space_form}
          id="location-space-form"
          action="#"
          phx-change="validate_space"
          phx-submit="save_space"
          class="flex flex-col gap-4"
        >
          <%!-- Kind / Parent / Status on one row keeps the form short. --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <.select
              field={@space_form[:kind]}
              label={gettext("Kind")}
              options={@kind_options}
            />
            <.select
              field={@space_form[:parent_uuid]}
              label={gettext("Parent space")}
              options={@parent_options}
            />
            <.select
              field={@space_form[:status]}
              label={gettext("Status")}
              options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
            />
          </div>

          <%!-- HTML5 `required` is intentionally NOT set — clicking
               Add Space with an empty name should reach the LV so the
               server-side "Name can't be blank" error renders in the
               field below, not a browser tooltip on top of it. --%>
          <.translatable_field
            field_name="name"
            form_prefix="space"
            changeset={@space_changeset}
            schema_field={:name}
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            primary_language={@primary_language}
            lang_data={@space_lang_data}
            label={gettext("Name")}
            placeholder={gettext("e.g., Floor 2, Conference Room, Storage Zone A")}
            class="w-full"
          />

          <.translatable_field
            field_name="description"
            form_prefix="space"
            changeset={@space_changeset}
            schema_field={:description}
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            primary_language={@primary_language}
            lang_data={@space_lang_data}
            label={gettext("Description")}
            type="textarea"
            placeholder={gettext("Brief description of this space...")}
            class="w-full"
          />

          <%!-- Internal notes is admin-only and rarely set — collapse
               into a details/summary to keep the form short by default. --%>
          <details class="text-sm">
            <summary class="cursor-pointer text-base-content/60 select-none">
              {gettext("Internal notes (admin-only)")}
            </summary>
            <div class="mt-2">
              <.textarea
                field={@space_form[:notes]}
                label={nil}
                rows="2"
                placeholder={gettext("Admin-only notes...")}
                class="min-h-[4rem]"
              />
            </div>
          </details>

          <div class="flex justify-between items-center pt-2">
            <button
              :if={@active_space_uuid != :new}
              type="button"
              phx-click="delete_space"
              data-confirm={gettext("Delete this space and any of its sub-spaces? This cannot be undone.")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4 mr-1" /> {gettext("Delete")}
            </button>
            <div :if={@active_space_uuid == :new} />

            <button
              type="submit"
              class="btn btn-primary btn-sm phx-submit-loading:opacity-75"
              phx-disable-with={gettext("Saving...")}
            >
              {if @active_space_uuid == :new, do: gettext("Add Space"), else: gettext("Save Space")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # Small local component — keeps the five section headings in the
  # form template identical in shape (icon + label) without repeating
  # the `<h2>` chrome five times.
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp section_heading(assigns) do
    ~H"""
    <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
      <.icon name={@icon} class="h-4 w-4" />
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # Translatable feature labels. Each literal string is picked up by
  # `mix gettext.extract` (run in core). Falls back to the raw key so
  # unknown feature keys render *something* instead of crashing.
  defp feature_label("wheelchair_accessible"), do: gettext("Wheelchair Accessible")
  defp feature_label("elevator"), do: gettext("Elevator")
  defp feature_label("parking"), do: gettext("Parking")
  defp feature_label("public_transport"), do: gettext("Public Transport Nearby")
  defp feature_label("loading_dock"), do: gettext("Loading Dock")
  defp feature_label("air_conditioning"), do: gettext("Air Conditioning")
  defp feature_label("wifi"), do: gettext("Wi-Fi")
  defp feature_label("restrooms"), do: gettext("Restrooms")
  defp feature_label("security"), do: gettext("24/7 Security")
  defp feature_label("cctv"), do: gettext("CCTV")
  defp feature_label(key), do: key

  # ── Space helpers ────────────────────────────────────────────────

  # Translatable kind labels — each literal is picked up by
  # `mix gettext.extract`. Stored value is always the lowercase string
  # from `Space.kinds()`.
  defp kind_label("floor"), do: gettext("Floor")
  defp kind_label("room"), do: gettext("Room")
  defp kind_label("hall"), do: gettext("Hall")
  defp kind_label("suite"), do: gettext("Suite")
  defp kind_label("section"), do: gettext("Section")
  defp kind_label("zone"), do: gettext("Zone")
  defp kind_label("aisle"), do: gettext("Aisle")
  defp kind_label("shelf"), do: gettext("Shelf")
  defp kind_label("corner"), do: gettext("Corner")
  defp kind_label(other), do: other

  defp kind_options do
    Enum.map(Space.kinds(), fn k -> {kind_label(k), k} end)
  end

  # Builds "Kind: Name" labels with " → " breadcrumb prefix for nested
  # spaces. Bounded walk so a corrupted parent chain can't spin forever.
  defp space_tab_label(%Space{} = space, spaces) do
    own = "#{kind_label(space.kind)}: #{space.name || gettext("(unnamed)")}"

    case breadcrumb_prefix(space.parent_uuid, spaces, 32) do
      "" -> own
      prefix -> "#{prefix} → #{own}"
    end
  end

  defp breadcrumb_prefix(nil, _spaces, _hops_remaining), do: ""
  defp breadcrumb_prefix(_uuid, _spaces, 0), do: "…"

  defp breadcrumb_prefix(uuid, spaces, hops_remaining) do
    case Enum.find(spaces, &(&1.uuid == uuid)) do
      nil ->
        ""

      parent ->
        own = "#{kind_label(parent.kind)}: #{parent.name || gettext("(unnamed)")}"

        case breadcrumb_prefix(parent.parent_uuid, spaces, hops_remaining - 1) do
          "" -> own
          prefix -> "#{prefix} → #{own}"
        end
    end
  end

  # Parent picker options: all spaces in this location EXCEPT the
  # active one. Indirect cycles are blocked by `Spaces.update_space/3`
  # at save time — we don't try to compute descendants here to keep
  # render cheap.
  defp parent_options(spaces, active_uuid) do
    root = {gettext("— None (top level) —"), ""}

    children =
      spaces
      |> Enum.reject(fn s -> s.uuid == active_uuid end)
      |> Enum.map(fn s -> {space_tab_label(s, spaces), s.uuid} end)

    [root | children]
  end

  # Mirrors `get_lang_data/3` from MultilangForm but tolerant of a nil
  # changeset (on :new the spaces state is not initialised). Returns
  # an empty map when no changeset — the translatable_field component
  # treats that as "no overrides," falling back to primary values.
  defp space_lang_data(nil, _current_lang, _multilang_enabled), do: %{}

  defp space_lang_data(changeset, current_lang, multilang_enabled),
    do: get_lang_data(changeset, current_lang, multilang_enabled)
end

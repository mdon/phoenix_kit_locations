defmodule PhoenixKitLocations.Web.LocationFormLive do
  @moduledoc "Create/edit form for locations with multilang, type toggles, and feature checkboxes."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.LanguageSwitcher, only: [language_switcher: 1]
  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]
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

  # ── Spaces state — staged drafts ─────────────────────────────────

  # Spaces commit together with the Location: clicking "+ Add space"
  # appends an in-memory draft; edits update the draft's working
  # changeset; nothing touches the DB until the global Save / Create
  # button fires. The drafts list is the single source of truth for
  # both new (`persisted?: false`) and existing (`persisted?: true`)
  # spaces; existing ones marked `deleted: true` are persisted as
  # deletions on save.
  #
  # The list query is rescued so a missing migration (V122 not yet
  # applied on the host) leaves the Spaces card empty rather than
  # crashing the whole form.
  defp assign_spaces_state(socket, :new, _location) do
    assign(socket, space_drafts: [], active_floor_id: nil, active_room_id: nil)
  end

  defp assign_spaces_state(socket, :edit, location) do
    drafts =
      location.uuid
      |> safe_list_spaces()
      |> Enum.map(&persisted_draft/1)

    active_floor =
      case Enum.find(drafts, &(&1.space.kind == "floor")) do
        nil -> nil
        d -> d.id
      end

    assign(socket,
      space_drafts: drafts,
      active_floor_id: active_floor,
      active_room_id: nil
    )
  end

  defp safe_list_spaces(location_uuid) do
    Spaces.list_for_location(location_uuid)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[LocationFormLive] list spaces failed: #{Exception.message(e)}")
      []
  end

  # Draft shape:
  #
  #   %{
  #     id: String.t(),                  # tab key (DB uuid for persisted, "new-<uuid>" otherwise)
  #     persisted?: boolean(),
  #     space: Space.t(),                # base struct the changeset casts on top of
  #     changeset: Ecto.Changeset.t(),   # working changeset; cleared/replaced on validate_space
  #     deleted: boolean(),              # true => issue a delete on global save (persisted only)
  #     current_lang: String.t() | nil   # draft-local active language for the multilang selector
  #                                      # rendered inside the floor / room form. nil falls back
  #                                      # to the page's `:primary_language`. Lets the user edit,
  #                                      # say, Floor 1 in English while Floor 2 is on Spanish
  #                                      # without each form's selector dragging the others along.
  #   }
  defp persisted_draft(%Space{} = space) do
    %{
      id: space.uuid,
      persisted?: true,
      space: space,
      changeset: Spaces.change_space(space),
      deleted: false,
      current_lang: nil
    }
  end

  # A fresh draft for an as-yet-unsaved space. `kind` is either "floor"
  # (top-level tab) or "room" (child of a floor). `parent_uuid` is the
  # floor's id for rooms, nil for floors. `location_uuid` may be nil on
  # :new — we resolve it at global-save time once the parent Location
  # has its UUID.
  defp new_draft(location_uuid, kind, parent_uuid \\ nil) when kind in ["floor", "room"] do
    space = %Space{
      location_uuid: location_uuid,
      kind: kind,
      parent_uuid: parent_uuid,
      status: "active"
    }

    %{
      id: "new-" <> Ecto.UUID.generate(),
      persisted?: false,
      space: space,
      changeset: Spaces.change_space(space),
      deleted: false,
      current_lang: nil
    }
  end

  # Falls back to the page's primary language when the draft has no
  # per-form lang override yet. `safe` — both args may be nil on a
  # multilang-disabled host; the renderer treats nil as the
  # single-language default.
  defp draft_current_lang(%{current_lang: lang}, _primary) when is_binary(lang), do: lang
  defp draft_current_lang(_, primary), do: primary

  # Splits drafts by view-context. Floors are top-level tabs; rooms
  # live under the active floor.
  defp floor_drafts(drafts) do
    drafts |> Enum.filter(&(&1.space.kind == "floor")) |> Enum.reject(& &1.deleted)
  end

  defp room_drafts_of(drafts, floor_id) when is_binary(floor_id) do
    drafts
    |> Enum.filter(fn d ->
      d.space.kind == "room" and parent_id_of(d) == floor_id and not d.deleted
    end)
  end

  defp room_drafts_of(_drafts, _floor_id), do: []

  # A room's parent is whatever's currently in the changeset — apply
  # the changes so the rooms list reflects live in-progress parent
  # picks (e.g. a brand new floor draft's id) before save.
  defp parent_id_of(%{changeset: cs}),
    do: Ecto.Changeset.get_field(cs, :parent_uuid)

  defp find_draft(drafts, id), do: Enum.find(drafts, &(&1.id == id))

  defp update_draft(drafts, id, fun) when is_function(fun, 1) do
    Enum.map(drafts, fn d -> if d.id == id, do: fun.(d), else: d end)
  end

  # First non-deleted floor draft's id (or nil if none) — used after a
  # delete to pick the next active tab.
  defp first_visible_floor_id(drafts) do
    case floor_drafts(drafts) do
      [] -> nil
      [first | _] -> first.id
    end
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

  # ── Spaces (staged drafts — commit on global save) ─────────────

  # Two-level model: floor tabs at the top, rooms inside the active
  # floor. Floors are always root (`parent_uuid == nil`); rooms always
  # carry their floor's id as `parent_uuid`. Both kinds stage as
  # in-memory drafts and only persist when the Location's bottom
  # Save / Create button fires.

  def handle_event("add_floor", _params, socket) do
    location_uuid = socket.assigns.location && socket.assigns.location.uuid
    draft = new_draft(location_uuid, "floor")
    drafts = socket.assigns.space_drafts ++ [draft]

    {:noreply,
     assign(socket,
       space_drafts: drafts,
       active_floor_id: draft.id,
       active_room_id: nil
     )}
  end

  def handle_event("add_room", _params, socket) do
    case socket.assigns.active_floor_id do
      nil ->
        # Shouldn't happen — the Add room button is only rendered
        # inside an active floor tab. Defensive no-op.
        {:noreply, socket}

      floor_id ->
        location_uuid = socket.assigns.location && socket.assigns.location.uuid
        draft = new_draft(location_uuid, "room", floor_id)
        drafts = socket.assigns.space_drafts ++ [draft]

        {:noreply,
         assign(socket,
           space_drafts: drafts,
           active_room_id: draft.id
         )}
    end
  end

  # NavTabs sends the clicked tab id as `phx-value-tab` (the core
  # component's convention) — accept either key for backwards-compat
  # in case any other call site still uses `phx-value-id`.
  def handle_event("select_floor", %{"tab" => id}, socket),
    do: do_select_floor(socket, id)

  def handle_event("select_floor", %{"id" => id}, socket),
    do: do_select_floor(socket, id)

  defp do_select_floor(socket, id) do
    case find_draft(socket.assigns.space_drafts, id) do
      %{deleted: false, space: %{kind: "floor"}} ->
        {:noreply, assign(socket, active_floor_id: id, active_room_id: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_room", %{"id" => id}, socket) do
    case find_draft(socket.assigns.space_drafts, id) do
      %{deleted: false, space: %{kind: "room"}} ->
        {:noreply, assign(socket, active_room_id: id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_room_editor", _params, socket) do
    {:noreply, assign(socket, active_room_id: nil)}
  end

  # Per-form language switch — only affects the active draft, NOT the
  # page-level multilang_tabs at the top of the form. Lets each
  # floor/room form be on its own language independently.
  def handle_event("switch_space_language", %{"language" => lang}, socket) do
    id = socket.assigns.active_room_id || socket.assigns.active_floor_id

    case find_draft(socket.assigns.space_drafts, id) do
      nil ->
        {:noreply, socket}

      _draft ->
        drafts =
          update_draft(socket.assigns.space_drafts, id, &Map.put(&1, :current_lang, lang))

        {:noreply, assign(socket, space_drafts: drafts)}
    end
  end

  # Editing the active draft (room takes precedence over floor — when
  # both an editor is open AND the floor form is visible, the open
  # editor is the one the user is typing into). The form's phx-change
  # only fires for the one being typed in, so this single handler
  # routes both via the active-id chain.
  #
  # merge_translatable_params reads `current_lang` from socket assigns,
  # but spaces forms have per-draft language state — so we feed it a
  # shadow socket whose `:current_lang` is the active draft's chosen
  # language. The original socket is untouched.
  def handle_event("validate_space", %{"space" => params}, socket) do
    id = socket.assigns.active_room_id || socket.assigns.active_floor_id

    case find_draft(socket.assigns.space_drafts, id) do
      nil ->
        {:noreply, socket}

      draft ->
        draft_socket = with_draft_lang(socket, draft)

        params =
          merge_translatable_params(params, draft_socket, @space_translatable_fields,
            changeset: draft.changeset,
            preserve_fields: @space_preserve_fields
          )

        cs =
          draft.space
          |> Spaces.change_space(params)
          |> Map.put(:action, :validate)

        drafts = update_draft(socket.assigns.space_drafts, id, &Map.put(&1, :changeset, cs))

        {:noreply, assign(socket, space_drafts: drafts)}
    end
  end

  # Builds a "shadow" socket whose `:current_lang` matches the draft's
  # per-form active language. Used at the validate_space boundary so
  # `merge_translatable_params` keys its multilang merge against the
  # draft-local lang instead of the page-level one. Doesn't mutate
  # the real socket — `merge_translatable_params` only reads.
  defp with_draft_lang(socket, draft) do
    lang = draft_current_lang(draft, socket.assigns[:primary_language])
    %{socket | assigns: Map.put(socket.assigns, :current_lang, lang)}
  end

  # Marks the active floor for delete and cascades to all of its room
  # drafts (new ones drop entirely; persisted ones get queued for the
  # CASCADE that fires in `Spaces.delete_space/2`). Keeps the visible
  # state consistent with what the global save will commit.
  def handle_event("delete_floor", _params, socket) do
    case find_draft(socket.assigns.space_drafts, socket.assigns.active_floor_id) do
      %{space: %{kind: "floor"}} = floor ->
        drafts = cascade_delete_floor(socket.assigns.space_drafts, floor)
        next_floor = first_visible_floor_id(drafts)

        {:noreply,
         assign(socket,
           space_drafts: drafts,
           active_floor_id: next_floor,
           active_room_id: nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_room", %{"id" => id}, socket) do
    case find_draft(socket.assigns.space_drafts, id) do
      %{space: %{kind: "room"}, persisted?: false} ->
        # Never reached the DB — drop entirely.
        drafts = Enum.reject(socket.assigns.space_drafts, &(&1.id == id))

        active_room =
          if socket.assigns.active_room_id == id, do: nil, else: socket.assigns.active_room_id

        {:noreply, assign(socket, space_drafts: drafts, active_room_id: active_room)}

      %{space: %{kind: "room"}, persisted?: true} ->
        drafts = update_draft(socket.assigns.space_drafts, id, &Map.put(&1, :deleted, true))

        active_room =
          if socket.assigns.active_room_id == id, do: nil, else: socket.assigns.active_room_id

        {:noreply, assign(socket, space_drafts: drafts, active_room_id: active_room)}

      _ ->
        {:noreply, socket}
    end
  end

  defp cascade_delete_floor(drafts, %{id: floor_id, persisted?: floor_persisted?}) do
    Enum.reduce(drafts, [], fn d, acc ->
      cond do
        d.id == floor_id and floor_persisted? ->
          [Map.put(d, :deleted, true) | acc]

        d.id == floor_id ->
          # New floor — drop completely.
          acc

        d.space.kind == "room" and parent_id_of(d) == floor_id and d.persisted? ->
          # Persisted room of this floor — queue for the cascaded delete
          # so the UI hides it now even though the DB CASCADE fires
          # only when the floor's delete is committed.
          [Map.put(d, :deleted, true) | acc]

        d.space.kind == "room" and parent_id_of(d) == floor_id ->
          # New room of a deleted floor — drop completely.
          acc

        true ->
          [d | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp save_location(socket, :new, params) do
    case Locations.create_location(params, actor_opts(socket)) do
      {:ok, location} ->
        _ = Attachments.maybe_rename_pending_folder(socket, location)

        flash = persist_space_drafts(socket.assigns.space_drafts, location.uuid, socket)
        sync_types_and_redirect(socket, location.uuid, gettext("Location created."), flash)

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_location(socket, :edit, params) do
    case Locations.update_location(socket.assigns.location, params, actor_opts(socket)) do
      {:ok, location} ->
        flash = persist_space_drafts(socket.assigns.space_drafts, location.uuid, socket)
        sync_types_and_redirect(socket, location.uuid, gettext("Location updated."), flash)

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # Two-pass save: floors first (no parent_uuid concerns), then rooms
  # with parent_uuid translated via id_map for any new floors created
  # in pass 1. Rooms whose floor is also being deleted are skipped —
  # the DB CASCADE handles them when the floor delete fires.
  #
  # Best-effort: per-draft failures log + surface as a warning flash on
  # the redirect; we don't roll back the Location save.
  defp persist_space_drafts([], _location_uuid, _socket), do: nil

  defp persist_space_drafts(drafts, location_uuid, socket) do
    opts = actor_opts(socket)

    {floors, rooms} = Enum.split_with(drafts, &(&1.space.kind == "floor"))

    deleting_floor_ids =
      floors
      |> Enum.filter(&(&1.persisted? and &1.deleted))
      |> MapSet.new(& &1.id)

    {floor_errors, id_map} = persist_floor_drafts(floors, location_uuid, opts)

    room_errors =
      persist_room_drafts(rooms, deleting_floor_ids, id_map, location_uuid, opts)

    case floor_errors ++ room_errors do
      [] -> nil
      errors -> {:warning, draft_error_summary(errors)}
    end
  end

  defp persist_floor_drafts(floors, location_uuid, opts) do
    Enum.reduce(floors, {[], %{}}, fn floor, {errors, id_map} ->
      case persist_floor(floor, location_uuid, opts) do
        :ok -> {errors, id_map}
        {:created, new_uuid} -> {errors, Map.put(id_map, floor.id, new_uuid)}
        {:error, _, _} = err -> {[err | errors], id_map}
      end
    end)
  end

  defp persist_floor(%{persisted?: true, deleted: true} = floor, _loc, opts) do
    case Spaces.delete_space(floor.space, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, floor.id, reason}
    end
  end

  defp persist_floor(%{persisted?: false, deleted: true}, _loc, _opts), do: :ok

  defp persist_floor(%{persisted?: false} = floor, location_uuid, opts) do
    attrs =
      floor.changeset
      |> Ecto.Changeset.apply_changes()
      |> space_to_attrs()
      |> Map.put("location_uuid", location_uuid)
      |> Map.put("parent_uuid", nil)

    case Spaces.create_space(attrs, opts) do
      {:ok, saved} -> {:created, saved.uuid}
      {:error, reason} -> {:error, floor.id, reason}
    end
  end

  defp persist_floor(%{persisted?: true, changeset: %{changes: changes}}, _loc, _opts)
       when map_size(changes) == 0,
       do: :ok

  defp persist_floor(%{persisted?: true} = floor, _loc, opts) do
    attrs = floor.changeset |> Ecto.Changeset.apply_changes() |> space_to_attrs()

    case Spaces.update_space(floor.space, attrs, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, floor.id, reason}
    end
  end

  defp persist_room_drafts(rooms, deleting_floor_ids, id_map, location_uuid, opts) do
    Enum.reduce(rooms, [], fn room, errors ->
      parent_id = parent_id_of(room)

      cond do
        parent_id in deleting_floor_ids ->
          # Floor's delete will CASCADE this room (for persisted ones)
          # or it was never staged (for new ones).
          errors

        true ->
          case persist_room(room, id_map, location_uuid, opts) do
            :ok -> errors
            {:error, _, _} = err -> [err | errors]
          end
      end
    end)
  end

  defp persist_room(%{persisted?: true, deleted: true} = room, _id_map, _loc, opts) do
    case Spaces.delete_space(room.space, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, room.id, reason}
    end
  end

  defp persist_room(%{persisted?: false, deleted: true}, _id_map, _loc, _opts), do: :ok

  defp persist_room(%{persisted?: false} = room, id_map, location_uuid, opts) do
    parent_uuid = resolve_parent_uuid(parent_id_of(room), id_map)

    attrs =
      room.changeset
      |> Ecto.Changeset.apply_changes()
      |> space_to_attrs()
      |> Map.put("location_uuid", location_uuid)
      |> Map.put("parent_uuid", parent_uuid)

    case Spaces.create_space(attrs, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, room.id, reason}
    end
  end

  defp persist_room(%{persisted?: true, changeset: %{changes: changes}}, _id_map, _loc, _opts)
       when map_size(changes) == 0,
       do: :ok

  defp persist_room(%{persisted?: true} = room, id_map, _loc, opts) do
    parent_uuid = resolve_parent_uuid(parent_id_of(room), id_map)

    attrs =
      room.changeset
      |> Ecto.Changeset.apply_changes()
      |> space_to_attrs()
      |> Map.put("parent_uuid", parent_uuid)

    case Spaces.update_space(room.space, attrs, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, room.id, reason}
    end
  end

  # Translates a draft id ("new-XXX") to its newly created DB uuid via
  # the floor pass's id_map. Real persisted uuids pass through unchanged.
  defp resolve_parent_uuid(nil, _id_map), do: nil
  defp resolve_parent_uuid(uuid, id_map), do: Map.get(id_map, uuid, uuid)

  # Extracts the params shape `Spaces.{create,update}_space` expects
  # from the effective Space struct (base + applied changes). We pass
  # all relevant fields explicitly so the underlying cast/3 sees them
  # — passing only the changes map would lose default values from the
  # draft's base struct (e.g. `kind` from new_draft/3).
  defp space_to_attrs(%Space{} = s) do
    %{
      "kind" => s.kind,
      "name" => s.name,
      "description" => s.description,
      "notes" => s.notes,
      "status" => s.status,
      "position" => s.position,
      "data" => s.data || %{}
    }
  end

  defp draft_error_summary(errors) do
    gettext("Location saved, but %{count} space(s) failed to save.", count: length(errors))
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

  defp sync_types_and_redirect(socket, location_uuid, message, draft_flash \\ nil) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    flash_overrides =
      case draft_flash do
        nil -> [{:info, message}]
        {kind, msg} -> [{kind, msg}]
      end

    case Locations.sync_location_types(location_uuid, type_uuids, actor_opts(socket)) do
      {:ok, _sync_state} ->
        {:noreply,
         flash_overrides
         |> Enum.reduce(socket, fn {k, m}, s -> put_flash(s, k, m) end)
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
      <%!-- SPACES (rooms / floors / zones)                        --%>
      <%!-- Sits between the two halves of the Location form so it  --%>
      <%!-- visually reads as a subdivision of the address above.   --%>
      <%!-- Drafts only commit when the global Save / Create button --%>
      <%!-- fires — on both :new and :edit.                         --%>
      <%!-- ═══════════════════════════════════════════════════════ --%>
      {render_spaces_section(assigns)}

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

  # The Spaces card. Two levels:
  #   - Top tab strip: one tab per Floor draft + a trailing "+ Add floor".
  #   - Inside the active Floor tab: the floor's own form + a list of
  #     its Rooms with inline edit/delete and a "+ Add room" button.
  # Editing a Room replaces the rooms list with the room's form (so
  # only one form is "open" at a time and the single validate_space
  # handler can route via active_room_id || active_floor_id).
  defp render_spaces_section(assigns) do
    floors = floor_drafts(assigns.space_drafts)
    active_floor = if assigns.active_floor_id, do: find_draft(assigns.space_drafts, assigns.active_floor_id), else: nil
    active_floor = if active_floor && active_floor.deleted, do: nil, else: active_floor

    active_room =
      if assigns.active_room_id,
        do: find_draft(assigns.space_drafts, assigns.active_room_id),
        else: nil

    active_room = if active_room && active_room.deleted, do: nil, else: active_room

    rooms_for_floor =
      if active_floor, do: room_drafts_of(assigns.space_drafts, active_floor.id), else: []

    assigns =
      assigns
      |> assign(:floor_tabs, floors)
      |> assign(:active_floor, active_floor)
      |> assign(:active_room, active_room)
      |> assign(:rooms_for_floor, rooms_for_floor)

    ~H"""
    <div class="card bg-base-100 shadow-lg mt-6">
      <div class="card-body flex flex-col gap-4">
        <div class="flex flex-col gap-0.5">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-squares-2x2" class="w-4 h-4" /> {gettext("Spaces")}
            <span :if={@floor_tabs != []} class="badge badge-sm badge-ghost ml-1">
              {length(@floor_tabs)} {ngettext("floor", "floors", length(@floor_tabs))}
            </span>
          </h2>
          <p class="text-xs text-base-content/50">
            {gettext("Add floors to this location, then list the rooms inside each. Changes save together with the location below.")}
          </p>
        </div>

        <%!-- Floor tabs via the core `<.nav_tabs>` component. The "+ Add
             floor" button can't ride inside the tab strip itself (the
             component takes a fixed list), so it sits beside it in the
             flex container — clicking it appends a new draft tab. --%>
        <div class="flex flex-wrap items-center gap-2">
          <.nav_tabs
            :if={@floor_tabs != []}
            active_tab={@active_floor_id || ""}
            on_change="select_floor"
            tabs={floor_nav_tab_maps(@floor_tabs)}
          />
          <button
            type="button"
            phx-click="add_floor"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4 mr-1" />
            {gettext("Add floor")}
          </button>
        </div>

        <%!-- Empty state — no floors yet. --%>
        <div :if={@floor_tabs == []} class="text-sm text-base-content/50 py-4">
          {gettext("No floors yet. Click \"Add floor\" above to start breaking down this location.")}
        </div>

        <%!-- Active floor view. Renders the floor's own form, then
             either the rooms list OR (when a room is being edited)
             the room editor in its place. --%>
        <%= if @active_floor do %>
          <%= if @active_room do %>
            {render_room_editor(assigns)}
          <% else %>
            {render_floor_view(assigns)}
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # The active floor's form + its rooms list. Only rendered when no
  # room editor is open (the room editor replaces the rooms list).
  defp render_floor_view(assigns) do
    floor = assigns.active_floor
    draft_lang = draft_current_lang(floor, assigns.primary_language)

    assigns =
      assigns
      |> assign(:floor_form, to_form(floor.changeset, as: :space))
      |> assign(:floor_changeset, floor.changeset)
      |> assign(:floor, floor)
      |> assign(:floor_lang, draft_lang)
      |> assign(
        :floor_lang_data,
        space_lang_data(floor.changeset, draft_lang, assigns.multilang_enabled)
      )

    ~H"""
    <%!-- Per-floor language selector — independent from the page-
         level multilang_tabs above. Switching this only re-keys the
         translatable inputs in THIS floor's form via `switch_space_language`. --%>
    <.draft_language_strip
      :if={@multilang_enabled and match?([_, _ | _], @language_tabs)}
      language_tabs={@language_tabs}
      current_lang={@floor_lang}
    />

    <.form
      for={@floor_form}
      id="location-floor-form"
      action="#"
      phx-change="validate_space"
      class="flex flex-col gap-4"
    >
      <.translatable_field
        field_name="name"
        form_prefix="space"
        changeset={@floor_changeset}
        schema_field={:name}
        multilang_enabled={@multilang_enabled}
        current_lang={@floor_lang}
        primary_language={@primary_language}
        lang_data={@floor_lang_data}
        label={gettext("Floor name")}
        placeholder={gettext("e.g., Ground Floor, Floor 2, Basement")}
        class="w-full"
      />

      <.translatable_field
        field_name="description"
        form_prefix="space"
        changeset={@floor_changeset}
        schema_field={:description}
        multilang_enabled={@multilang_enabled}
        current_lang={@floor_lang}
        primary_language={@primary_language}
        lang_data={@floor_lang_data}
        label={gettext("Description")}
        type="textarea"
        placeholder={gettext("Brief description of this floor...")}
        class="w-full"
      />

      <details class="text-sm">
        <summary class="cursor-pointer text-base-content/60 select-none">
          {gettext("Internal notes (admin-only)")}
        </summary>
        <div class="mt-2">
          <.textarea
            field={@floor_form[:notes]}
            label={nil}
            rows="2"
            placeholder={gettext("Admin-only notes...")}
            class="min-h-[4rem]"
          />
        </div>
      </details>

      <div class="flex justify-end pt-2">
        <button
          type="button"
          phx-click="delete_floor"
          data-confirm={
            if @floor.persisted?,
              do: gettext("Mark this floor and its rooms for deletion? The change applies when you save the location."),
              else: gettext("Discard this unsaved floor and any rooms inside it?")
          }
          class="btn btn-ghost btn-sm text-error"
        >
          <.icon name="hero-trash" class="w-4 h-4 mr-1" />
          {if @floor.persisted?, do: gettext("Remove floor"), else: gettext("Discard floor")}
        </button>
      </div>
    </.form>

    <div class="divider my-0"></div>

    <%!-- Rooms list — outside the floor's <.form> so the room
         action buttons don't accidentally submit the floor form. --%>
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-base-content/70 flex items-center gap-1.5">
          <.icon name="hero-rectangle-stack" class="w-4 h-4" /> {gettext("Rooms on this floor")}
          <span :if={@rooms_for_floor != []} class="badge badge-xs badge-ghost ml-1">
            {length(@rooms_for_floor)}
          </span>
        </h3>
        <button type="button" phx-click="add_room" class="btn btn-ghost btn-xs">
          <.icon name="hero-plus" class="w-3.5 h-3.5 mr-1" /> {gettext("Add room")}
        </button>
      </div>

      <p :if={@rooms_for_floor == []} class="text-xs text-base-content/50 py-2">
        {gettext("No rooms on this floor yet.")}
      </p>

      <ul :if={@rooms_for_floor != []} class="flex flex-col gap-1.5">
        <li
          :for={r <- @rooms_for_floor}
          class="flex items-center gap-2 border border-base-300 rounded-md px-3 py-2"
        >
          <span class={["flex-1 text-sm", if(!r.persisted?, do: "italic", else: "")]}>
            {room_row_label(r)}
          </span>
          <button
            type="button"
            phx-click="edit_room"
            phx-value-id={r.id}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="delete_room"
            phx-value-id={r.id}
            data-confirm={
              if r.persisted?,
                do: gettext("Mark this room for deletion?"),
                else: gettext("Discard this unsaved room?")
            }
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # The room editor — replaces the rooms list when a room is being
  # edited. Single form bound to the active room's changeset.
  defp render_room_editor(assigns) do
    room = assigns.active_room
    draft_lang = draft_current_lang(room, assigns.primary_language)

    assigns =
      assigns
      |> assign(:room_form, to_form(room.changeset, as: :space))
      |> assign(:room_changeset, room.changeset)
      |> assign(:room, room)
      |> assign(:room_lang, draft_lang)
      |> assign(
        :room_lang_data,
        space_lang_data(room.changeset, draft_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex items-center justify-between text-sm text-base-content/60">
      <button
        type="button"
        phx-click="close_room_editor"
        class="btn btn-ghost btn-xs"
      >
        <.icon name="hero-arrow-left" class="w-3.5 h-3.5 mr-1" /> {gettext("Back to floor")}
      </button>
      <span>{gettext("Editing room")}</span>
    </div>

    <%!-- Per-room language selector — independent from the floor's
         and the page's. --%>
    <.draft_language_strip
      :if={@multilang_enabled and match?([_, _ | _], @language_tabs)}
      language_tabs={@language_tabs}
      current_lang={@room_lang}
    />

    <.form
      for={@room_form}
      id="location-room-form"
      action="#"
      phx-change="validate_space"
      class="flex flex-col gap-4"
    >
      <.translatable_field
        field_name="name"
        form_prefix="space"
        changeset={@room_changeset}
        schema_field={:name}
        multilang_enabled={@multilang_enabled}
        current_lang={@room_lang}
        primary_language={@primary_language}
        lang_data={@room_lang_data}
        label={gettext("Room name")}
        placeholder={gettext("e.g., Conference Room A, Storage, Office 3B")}
        class="w-full"
      />

      <.translatable_field
        field_name="description"
        form_prefix="space"
        changeset={@room_changeset}
        schema_field={:description}
        multilang_enabled={@multilang_enabled}
        current_lang={@room_lang}
        primary_language={@primary_language}
        lang_data={@room_lang_data}
        label={gettext("Description")}
        type="textarea"
        placeholder={gettext("Brief description of this room...")}
        class="w-full"
      />

      <details class="text-sm">
        <summary class="cursor-pointer text-base-content/60 select-none">
          {gettext("Internal notes (admin-only)")}
        </summary>
        <div class="mt-2">
          <.textarea
            field={@room_form[:notes]}
            label={nil}
            rows="2"
            placeholder={gettext("Admin-only notes...")}
            class="min-h-[4rem]"
          />
        </div>
      </details>

      <div class="flex justify-between items-center pt-2">
        <button
          type="button"
          phx-click="delete_room"
          phx-value-id={@room.id}
          data-confirm={
            if @room.persisted?,
              do: gettext("Mark this room for deletion?"),
              else: gettext("Discard this unsaved room?")
          }
          class="btn btn-ghost btn-sm text-error"
        >
          <.icon name="hero-trash" class="w-4 h-4 mr-1" />
          {if @room.persisted?, do: gettext("Remove room"), else: gettext("Discard room")}
        </button>
        <button
          type="button"
          phx-click="close_room_editor"
          class="btn btn-ghost btn-sm"
        >
          {gettext("Done")}
        </button>
      </div>
    </.form>
    """
  end

  # Per-form language strip used inside floor / room editors. Wraps
  # the core <.language_switcher> with the right click event so the
  # switch updates only the active draft's `current_lang` — NOT the
  # page-level `:current_lang` that drives the Location's own
  # multilang_tabs at the top of the form.
  attr :language_tabs, :list, required: true
  attr :current_lang, :string, required: true

  defp draft_language_strip(assigns) do
    ~H"""
    <div class="mb-1">
      <.language_switcher
        languages={@language_tabs}
        current_language={@current_lang}
        on_click="switch_space_language"
        show_flags={true}
        show_primary={true}
        primary_divider={true}
        variant={:tabs}
        size={:sm}
      />
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

  # Builds the maps `<.nav_tabs>` consumes for the floor strip. The
  # `italic` flag isn't part of the core component's vocabulary, so
  # non-persisted drafts get marked with a `*` suffix instead.
  defp floor_nav_tab_maps(floors) do
    Enum.map(floors, fn f ->
      label =
        if f.persisted?, do: floor_tab_label(f), else: "#{floor_tab_label(f)} *"

      %{id: f.id, label: label}
    end)
  end

  # Floor tab label — pulls the live name from the draft's working
  # changeset so the tab reflects what the user is typing right now.
  defp floor_tab_label(draft) do
    space = Ecto.Changeset.apply_changes(draft.changeset)

    cond do
      space.name && space.name != "" -> space.name
      draft.persisted? -> gettext("(unnamed floor)")
      true -> gettext("New floor")
    end
  end

  # Room row label — same idea as floor_tab_label for the rooms list.
  defp room_row_label(draft) do
    space = Ecto.Changeset.apply_changes(draft.changeset)

    cond do
      space.name && space.name != "" -> space.name
      draft.persisted? -> gettext("(unnamed room)")
      true -> gettext("New room")
    end
  end

  # Mirrors `get_lang_data/3` from MultilangForm but tolerant of a nil
  # changeset (on :new no drafts exist). Returns an empty map when no
  # changeset — the translatable_field component treats that as "no
  # overrides," falling back to primary values.
  defp space_lang_data(nil, _current_lang, _multilang_enabled), do: %{}

  defp space_lang_data(changeset, current_lang, multilang_enabled),
    do: get_lang_data(changeset, current_lang, multilang_enabled)
end

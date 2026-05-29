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
         |> Attachments.init()
         |> Attachments.allow_attachment_upload()
         |> Attachments.mount(scope: location_scope(), resource: location)
         |> assign_spaces_state(action, location)
         |> mount_space_scopes()}
    end
  end

  # The Location's scope key for the Files card. Constant — there's
  # only ever one Location per page.
  defp location_scope, do: "location"

  # Walks existing space drafts (post-mount of :edit) and mounts an
  # attachments scope for each. New drafts (added by user clicks) get
  # their scopes mounted on-the-fly in `add_floor` / `add_room`.
  defp mount_space_scopes(socket) do
    Enum.reduce(socket.assigns.space_drafts, socket, fn d, s ->
      Attachments.mount(s, scope: d.id, resource: d.space)
    end)
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
    # Validate space drafts up front. If any have errors, stop here:
    # don't save the location, mark each failing draft's changeset
    # with `action: :validate` so inline errors render, and jump the
    # active tab to the first failing draft so the user sees it. This
    # is the standard required-field flow — same as if a regular
    # form field failed validation.
    {validated_drafts, invalid_drafts} =
      validate_drafts_for_save(socket.assigns.space_drafts)

    case invalid_drafts do
      [] ->
        params =
          merge_translatable_params(params, socket, @translatable_fields,
            changeset: socket.assigns.changeset,
            preserve_fields: @preserve_fields
          )

        params =
          params
          |> Map.put("features", socket.assigns.features)
          |> Attachments.inject_attachment_data(socket, location_scope())
          |> merge_running_changes(socket.assigns.changeset)

        save_location(socket, socket.assigns.action, params)

      [first | _] ->
        {focus_floor, focus_room} = active_focus_for_invalid(first)

        {:noreply,
         socket
         |> assign(
           space_drafts: validated_drafts,
           active_floor_id: focus_floor,
           active_room_id: focus_room
         )
         |> put_flash(:error, invalid_drafts_flash(invalid_drafts, validated_drafts))}
    end
  end

  # Rebuilds each draft's changeset with full Space-validation rules
  # so blank names, etc. surface as errors. Orphan-blank floors are
  # skipped (they're silently dropped on actual save) so we don't
  # block on those. Deleted drafts are skipped (they're going away).
  defp validate_drafts_for_save(drafts) do
    {floors, rooms} = Enum.split_with(drafts, &(&1.space.kind == "floor"))

    orphan_blank_floor_ids =
      floors
      |> Enum.filter(&orphan_blank_floor?(&1, rooms))
      |> MapSet.new(& &1.id)

    updated =
      Enum.map(drafts, fn d ->
        cond do
          d.deleted -> d
          d.id in orphan_blank_floor_ids -> d
          true -> validate_draft_for_save(d)
        end
      end)

    invalid = Enum.filter(updated, &draft_has_errors?/1)
    {updated, invalid}
  end

  defp validate_draft_for_save(%{changeset: cs} = draft) do
    # Rebuild the changeset against the full applied attrs so
    # validate_required/etc. fire. Cast on top of draft.space so
    # `changes` stays a delta from the persisted baseline (matters
    # for the "any changes?" check in persist_floor/persist_room).
    attrs = cs |> Ecto.Changeset.apply_changes() |> space_to_attrs()

    rebuilt =
      draft.space
      |> Spaces.change_space(attrs)
      |> Map.put(:action, :validate)

    %{draft | changeset: rebuilt}
  end

  defp draft_has_errors?(%{deleted: true}), do: false

  defp draft_has_errors?(%{changeset: cs}),
    do: cs.action == :validate and not cs.valid?

  # When blocking the save, jump to the first failing draft's tab so
  # the user actually sees the inline error. For a room, that means
  # opening its parent floor and then expanding the room editor.
  defp active_focus_for_invalid(%{space: %{kind: "floor"}, id: id}), do: {id, nil}

  defp active_focus_for_invalid(%{space: %{kind: "room"}} = draft),
    do: {parent_id_of(draft), draft.id}

  # Builds a flash that names the specific failing draft(s) and the
  # specific issue. Examples:
  #
  #   "Floor 2 needs a name."
  #   "Floor \"Storage\" needs a name."   (when the floor was typed-named
  #                                        but another required field failed)
  #   "Floor 2 needs a name and Room 1 in Floor 2 needs a name."
  #
  # Identifying a draft: use the typed name if present; otherwise fall
  # back to a position label (1-indexed) within the kind's visible
  # siblings. Rooms include their parent floor in the label so the
  # user can find them in the right tab.
  defp invalid_drafts_flash(invalid_drafts, all_drafts) do
    problems =
      Enum.map(invalid_drafts, fn d ->
        describe_draft_problem(d, all_drafts)
      end)

    join_sentence(problems) <> "."
  end

  defp describe_draft_problem(draft, all_drafts) do
    identifier = identify_draft(draft, all_drafts)
    fields = invalid_field_keys(draft.changeset)

    cond do
      :name in fields ->
        gettext("%{label} needs a name", label: identifier)

      fields == [] ->
        gettext("%{label} needs attention", label: identifier)

      true ->
        first_field = hd(fields)

        gettext("%{label} has an invalid %{field}",
          label: identifier,
          field: humanize_field(first_field)
        )
    end
  end

  defp invalid_field_keys(%Ecto.Changeset{errors: errors}),
    do: errors |> Keyword.keys() |> Enum.uniq()

  # Convert :name → "name", :parent_uuid → "parent". Just a quick
  # humanizer for the generic-error path; specific fields can grow
  # better labels here as needed.
  defp humanize_field(:name), do: gettext("name")
  defp humanize_field(:description), do: gettext("description")
  defp humanize_field(:status), do: gettext("status")
  defp humanize_field(:parent_uuid), do: gettext("parent space")
  defp humanize_field(field), do: to_string(field)

  defp identify_draft(%{space: %{kind: "floor"}} = draft, all_drafts) do
    case typed_name(draft) do
      nil ->
        floors = visible_drafts_of_kind(all_drafts, "floor")
        position = (Enum.find_index(floors, &(&1.id == draft.id)) || 0) + 1
        gettext("Floor %{n}", n: position)

      name ->
        gettext(~s(Floor "%{name}"), name: name)
    end
  end

  defp identify_draft(%{space: %{kind: "room"}} = draft, all_drafts) do
    parent_id = parent_id_of(draft)

    floor_label =
      case Enum.find(all_drafts, &(&1.id == parent_id and not &1.deleted)) do
        nil -> gettext("(unknown floor)")
        floor -> identify_draft(floor, all_drafts)
      end

    case typed_name(draft) do
      nil ->
        rooms =
          all_drafts
          |> Enum.filter(
            &(&1.space.kind == "room" and parent_id_of(&1) == parent_id and not &1.deleted)
          )

        position = (Enum.find_index(rooms, &(&1.id == draft.id)) || 0) + 1
        gettext("Room %{n} in %{floor}", n: position, floor: floor_label)

      name ->
        gettext(~s(Room "%{name}" in %{floor}), name: name, floor: floor_label)
    end
  end

  defp typed_name(%{changeset: cs}) do
    case Ecto.Changeset.get_field(cs, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp visible_drafts_of_kind(drafts, kind),
    do: Enum.filter(drafts, &(&1.space.kind == kind and not &1.deleted))

  defp join_sentence([]), do: ""
  defp join_sentence([only]), do: only
  defp join_sentence([a, b]), do: gettext("%{a} and %{b}", a: a, b: b)

  defp join_sentence(list) do
    last = List.last(list)
    init = list |> Enum.drop(-1) |> Enum.join(", ")
    gettext("%{init}, and %{last}", init: init, last: last)
  end

  # ── Attachments (featured image modal + inline files dropzone) ──
  # All events take a `scope` via phx-value-scope so multiple Files
  # cards on the same page route to their own state.

  def handle_event("open_featured_image_picker", %{"scope" => scope}, socket),
    do: Attachments.open_featured_image_picker(socket, scope)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("remove_file", %{"scope" => scope, "uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, scope, uuid)

  def handle_event("clear_featured_image", %{"scope" => scope}, socket),
    do: Attachments.clear_featured_image(socket, scope)

  # Marks which Files card the next upload is for. Wired to phx-click
  # on each dropzone label.
  def handle_event("set_active_upload_scope", %{"scope" => scope}, socket),
    do: {:noreply, Attachments.set_active_upload_scope(socket, scope)}

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
     socket
     |> assign(
       space_drafts: drafts,
       active_floor_id: draft.id,
       active_room_id: nil
     )
     |> Attachments.mount(scope: draft.id, resource: draft.space)}
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
         socket
         |> assign(
           space_drafts: drafts,
           active_room_id: draft.id
         )
         |> Attachments.mount(scope: draft.id, resource: draft.space)}
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
  # state consistent with what the global save will commit. Also frees
  # the attachment scopes for any drafts that were entirely dropped
  # (no need to keep their state around — they're gone).
  def handle_event("delete_floor", _params, socket) do
    case find_draft(socket.assigns.space_drafts, socket.assigns.active_floor_id) do
      %{space: %{kind: "floor"}} = floor ->
        old_ids = MapSet.new(socket.assigns.space_drafts, & &1.id)
        drafts = cascade_delete_floor(socket.assigns.space_drafts, floor)
        kept_ids = MapSet.new(drafts, & &1.id)
        dropped = MapSet.difference(old_ids, kept_ids)

        next_floor = first_visible_floor_id(drafts)

        socket =
          socket
          |> assign(
            space_drafts: drafts,
            active_floor_id: next_floor,
            active_room_id: nil
          )
          |> forget_dropped_scopes(dropped)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_room", %{"id" => id}, socket) do
    case find_draft(socket.assigns.space_drafts, id) do
      %{space: %{kind: "room"}, persisted?: false} ->
        # Never reached the DB — drop entirely + free its scope state.
        drafts = Enum.reject(socket.assigns.space_drafts, &(&1.id == id))

        active_room =
          if socket.assigns.active_room_id == id, do: nil, else: socket.assigns.active_room_id

        {:noreply,
         socket
         |> assign(space_drafts: drafts, active_room_id: active_room)
         |> Attachments.forget_scope(id)}

      %{space: %{kind: "room"}, persisted?: true} ->
        # Keep the scope state — the user can still see the files
        # were attached to this room until they hit Save. The deletion
        # commits then; the row + cascaded folder go away with it.
        drafts = update_draft(socket.assigns.space_drafts, id, &Map.put(&1, :deleted, true))

        active_room =
          if socket.assigns.active_room_id == id, do: nil, else: socket.assigns.active_room_id

        {:noreply, assign(socket, space_drafts: drafts, active_room_id: active_room)}

      _ ->
        {:noreply, socket}
    end
  end

  defp forget_dropped_scopes(socket, %MapSet{} = dropped) do
    Enum.reduce(dropped, socket, fn id, s -> Attachments.forget_scope(s, id) end)
  end

  defp cascade_delete_floor(drafts, %{id: floor_id, persisted?: floor_persisted?}) do
    drafts
    |> Enum.reduce([], fn d, acc ->
      case classify_for_floor_delete(d, floor_id, floor_persisted?) do
        :keep -> [d | acc]
        :drop -> acc
        :mark_deleted -> [Map.put(d, :deleted, true) | acc]
      end
    end)
    |> Enum.reverse()
  end

  # The floor itself: queue for delete if persisted, drop if new.
  defp classify_for_floor_delete(%{id: id, persisted?: true}, id, _floor_persisted?),
    do: :mark_deleted

  defp classify_for_floor_delete(%{id: id}, id, _floor_persisted?), do: :drop

  # A room of the floor: same persisted-vs-new split as above. The DB
  # CASCADE fires only when the floor's delete is committed; we mark the
  # rooms here so the UI hides them immediately.
  defp classify_for_floor_delete(
         %{space: %{kind: "room"}, persisted?: true} = d,
         floor_id,
         _floor_persisted?
       ) do
    if parent_id_of(d) == floor_id, do: :mark_deleted, else: :keep
  end

  defp classify_for_floor_delete(%{space: %{kind: "room"}} = d, floor_id, _floor_persisted?) do
    if parent_id_of(d) == floor_id, do: :drop, else: :keep
  end

  defp classify_for_floor_delete(_d, _floor_id, _floor_persisted?), do: :keep

  defp save_location(socket, :new, params) do
    case Locations.create_location(params, actor_opts(socket)) do
      {:ok, location} ->
        location_folder = Attachments.state(socket, location_scope()).folder_uuid
        _ = Attachments.maybe_rename_pending_folder_for(location_folder, location)

        {flash, failed_ids} =
          persist_space_drafts(socket.assigns.space_drafts, location.uuid, socket)

        finish_save(socket, location, gettext("Location created."), flash, failed_ids)

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_location(socket, :edit, params) do
    case Locations.update_location(socket.assigns.location, params, actor_opts(socket)) do
      {:ok, location} ->
        {flash, failed_ids} =
          persist_space_drafts(socket.assigns.space_drafts, location.uuid, socket)

        finish_save(socket, location, gettext("Location updated."), flash, failed_ids)

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # Decides whether to redirect (full success) or stay on the page
  # (partial failure). Staying preserves the in-memory drafts that
  # failed so the user can fix them and retry instead of losing all
  # their typing.
  defp finish_save(socket, location, success_msg, nil, _failed_ids) do
    sync_types_and_redirect(socket, location.uuid, success_msg)
  end

  defp finish_save(socket, location, _success_msg, {kind, msg}, failed_ids) do
    fresh_persisted =
      location.uuid |> safe_list_spaces() |> Enum.map(&persisted_draft/1)

    failed_drafts =
      Enum.filter(socket.assigns.space_drafts, fn d -> MapSet.member?(failed_ids, d.id) end)

    new_drafts = fresh_persisted ++ failed_drafts

    {:noreply,
     socket
     |> assign(:location, location)
     |> put_flash(kind, msg)
     |> assign(space_drafts: new_drafts)
     |> reseat_active_tabs(new_drafts)
     |> remount_space_scopes(fresh_persisted)}
  end

  # After a partial save we may have swapped the active floor / room
  # ids out from under the user (e.g. their previously-active floor
  # just succeeded so its old draft id is gone, replaced by a new
  # persisted draft). Bounce the active ids to whatever still exists
  # in the new drafts list.
  defp reseat_active_tabs(socket, drafts) do
    ids = MapSet.new(drafts, & &1.id)

    active_floor =
      if socket.assigns.active_floor_id in ids,
        do: socket.assigns.active_floor_id,
        else: first_visible_floor_id(drafts)

    active_room =
      if socket.assigns.active_room_id in ids,
        do: socket.assigns.active_room_id,
        else: nil

    assign(socket, active_floor_id: active_floor, active_room_id: active_room)
  end

  # The freshly-reloaded persisted drafts need their attachment scopes
  # mounted (their UUIDs are different from the draft-ids they had
  # in memory pre-save). The previously-failed drafts keep using
  # their original scope keys — those are untouched.
  defp remount_space_scopes(socket, fresh_persisted) do
    Enum.reduce(fresh_persisted, socket, fn d, s ->
      Attachments.mount(s, scope: d.id, resource: d.space)
    end)
  end

  # Two-pass save: floors first (no parent_uuid concerns), then rooms
  # with parent_uuid translated via id_map for any new floors created
  # in pass 1. Rooms whose floor is also being deleted are skipped —
  # the DB CASCADE handles them when the floor delete fires.
  #
  # Best-effort: per-draft failures log + surface as a warning flash on
  # the redirect; we don't roll back the Location save.
  defp persist_space_drafts([], _location_uuid, _socket), do: {nil, MapSet.new()}

  defp persist_space_drafts(drafts, location_uuid, socket) do
    opts = actor_opts(socket)

    {floors, rooms} = Enum.split_with(drafts, &(&1.space.kind == "floor"))

    deleting_floor_ids =
      floors
      |> Enum.filter(&(&1.persisted? and &1.deleted))
      |> MapSet.new(& &1.id)

    # Pre-compute which blank-name new floors are ORPHANS — i.e. have
    # no in-memory room drafts pointing at them. Those are almost
    # certainly abandoned "+ Add floor" clicks and we silent-skip them.
    # Blank-name floors that DO have rooms under them are NOT skipped
    # — we let validation surface "name can't be blank" so the user
    # knows to either name the floor or discard the rooms.
    orphan_blank_floor_ids =
      floors
      |> Enum.filter(&orphan_blank_floor?(&1, rooms))
      |> MapSet.new(& &1.id)

    {floor_errors, id_map} =
      persist_floor_drafts(floors, orphan_blank_floor_ids, location_uuid, opts, socket)

    # Rooms parented to a deleting-persisted floor are skipped (DB
    # CASCADE handles them) and rooms parented to an orphan-blank
    # floor are skipped (their parent silently dropped). Rooms whose
    # parent floor SURVIVED to a save attempt but failed validation
    # are handled inside persist_room/5 — it suppresses the cascade
    # error so the user only sees the root cause (the floor's blank
    # name).
    skip_parent_floor_ids = MapSet.union(deleting_floor_ids, orphan_blank_floor_ids)

    room_errors =
      persist_room_drafts(rooms, skip_parent_floor_ids, id_map, location_uuid, opts, socket)

    errors = floor_errors ++ room_errors
    failed_ids = MapSet.new(errors, fn {:error, id, _reason} -> id end)

    flash =
      case errors do
        [] -> nil
        _ -> {:warning, draft_error_summary(errors)}
      end

    {flash, failed_ids}
  end

  # True for a new, not-deleted floor draft with a blank name and no
  # in-memory room drafts pointing at it. Such drafts come from
  # accidental "+ Add floor" clicks and are safe to silently drop on
  # save without leaving the user wondering "where did my data go?"
  defp orphan_blank_floor?(%{persisted?: false, deleted: false, changeset: cs} = floor, rooms) do
    blank_changeset_name?(cs) and
      not Enum.any?(rooms, fn r -> parent_id_of(r) == floor.id and not r.deleted end)
  end

  defp orphan_blank_floor?(_floor, _rooms), do: false

  defp blank_changeset_name?(cs) do
    name = Ecto.Changeset.get_field(cs, :name)
    is_nil(name) or (is_binary(name) and String.trim(name) == "")
  end

  defp persist_floor_drafts(floors, orphan_blank_floor_ids, location_uuid, opts, socket) do
    Enum.reduce(floors, {[], %{}}, fn floor, acc ->
      step_floor_draft(floor, orphan_blank_floor_ids, location_uuid, opts, socket, acc)
    end)
  end

  # Silent skip on orphan-blank floors (abandoned, no children to orphan).
  defp step_floor_draft(floor, orphan_blank_floor_ids, location_uuid, opts, socket, acc) do
    if floor.id in orphan_blank_floor_ids do
      acc
    else
      apply_floor_persist_result(floor, location_uuid, opts, socket, acc)
    end
  end

  defp apply_floor_persist_result(floor, location_uuid, opts, socket, {errors, id_map}) do
    case persist_floor(floor, location_uuid, opts, socket) do
      :ok -> {errors, id_map}
      {:created, new_uuid} -> {errors, Map.put(id_map, floor.id, new_uuid)}
      {:error, _, _} = err -> {[err | errors], id_map}
    end
  end

  defp persist_floor(%{persisted?: true, deleted: true} = floor, _loc, opts, _socket) do
    case Spaces.delete_space(floor.space, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, floor.id, reason}
    end
  end

  defp persist_floor(%{persisted?: false, deleted: true}, _loc, _opts, _socket), do: :ok

  # Orphan-blank floors are silently skipped UPSTREAM in
  # persist_floor_drafts/5. Anything that reaches persist_floor/4 here
  # is either non-blank (will save) or blank-but-has-children (will
  # surface "name can't be blank" so the user fixes it).
  defp persist_floor(%{persisted?: false} = floor, location_uuid, opts, socket) do
    attrs =
      floor.changeset
      |> Ecto.Changeset.apply_changes()
      |> space_to_attrs()
      |> Map.put("location_uuid", location_uuid)
      |> Map.put("parent_uuid", nil)
      |> Attachments.inject_attachment_data(socket, floor.id)

    case Spaces.create_space(attrs, opts) do
      {:ok, saved} ->
        st = Attachments.state(socket, floor.id)
        _ = Attachments.maybe_rename_pending_folder_for(st.folder_uuid, saved)
        {:created, saved.uuid}

      {:error, reason} ->
        {:error, floor.id, reason}
    end
  end

  defp persist_floor(%{persisted?: true, changeset: cs} = floor, _loc, opts, socket) do
    has_field_changes? = map_size(cs.changes) > 0
    has_attachment_changes? = scope_has_attachment_changes?(socket, floor.id, floor.space)

    if has_field_changes? or has_attachment_changes? do
      attrs =
        cs
        |> Ecto.Changeset.apply_changes()
        |> space_to_attrs()
        |> Attachments.inject_attachment_data(socket, floor.id)

      case Spaces.update_space(floor.space, attrs, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, floor.id, reason}
      end
    else
      :ok
    end
  end

  defp persist_room_drafts(rooms, deleting_floor_ids, id_map, location_uuid, opts, socket) do
    Enum.reduce(rooms, [], fn room, errors ->
      step_room_draft(room, deleting_floor_ids, id_map, location_uuid, opts, socket, errors)
    end)
  end

  # Floor's delete will CASCADE this room (for persisted ones) or it
  # was never staged (for new ones).
  defp step_room_draft(room, deleting_floor_ids, id_map, location_uuid, opts, socket, errors) do
    if parent_id_of(room) in deleting_floor_ids do
      errors
    else
      case persist_room(room, id_map, location_uuid, opts, socket) do
        :ok -> errors
        {:error, _, _} = err -> [err | errors]
      end
    end
  end

  defp persist_room(%{persisted?: true, deleted: true} = room, _id_map, _loc, opts, _socket) do
    case Spaces.delete_space(room.space, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, room.id, reason}
    end
  end

  defp persist_room(%{persisted?: false, deleted: true}, _id_map, _loc, _opts, _socket), do: :ok

  defp persist_room(%{persisted?: false} = room, id_map, location_uuid, opts, socket) do
    parent_id = parent_id_of(room)
    parent_uuid = resolve_parent_uuid(parent_id, id_map)

    attrs =
      room.changeset
      |> Ecto.Changeset.apply_changes()
      |> space_to_attrs()
      |> Map.put("location_uuid", location_uuid)
      |> Map.put("parent_uuid", parent_uuid)
      |> Attachments.inject_attachment_data(socket, room.id)

    cond do
      # Blank-name new room is treated as abandoned and silently dropped.
      blank_required_field?(attrs) ->
        :ok

      # Parent floor didn't persist (probably needs a name). Don't try
      # `Spaces.create_space/2` — its FK would surface as
      # `:parent_in_other_location` which is misleading. Report a
      # purpose-built error so the user can see this room is held up
      # by its parent rather than silently disappearing.
      parent_uuid != nil and draft_id?(parent_uuid) ->
        {:error, room.id, :parent_floor_unsaved}

      true ->
        case Spaces.create_space(attrs, opts) do
          {:ok, saved} ->
            st = Attachments.state(socket, room.id)
            _ = Attachments.maybe_rename_pending_folder_for(st.folder_uuid, saved)
            :ok

          {:error, reason} ->
            {:error, room.id, reason}
        end
    end
  end

  defp draft_id?(id) when is_binary(id), do: String.starts_with?(id, "new-")
  defp draft_id?(_), do: false

  defp persist_room(%{persisted?: true, changeset: cs} = room, id_map, _loc, opts, socket) do
    has_field_changes? = map_size(cs.changes) > 0
    has_attachment_changes? = scope_has_attachment_changes?(socket, room.id, room.space)

    if has_field_changes? or has_attachment_changes? do
      parent_uuid = resolve_parent_uuid(parent_id_of(room), id_map)

      attrs =
        cs
        |> Ecto.Changeset.apply_changes()
        |> space_to_attrs()
        |> Map.put("parent_uuid", parent_uuid)
        |> Attachments.inject_attachment_data(socket, room.id)

      case Spaces.update_space(room.space, attrs, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, room.id, reason}
      end
    else
      :ok
    end
  end

  # Detects whether a persisted draft's attachment state has changed
  # against its persisted baseline — without this, "Save Changes" on a
  # location whose only edit was a new featured image would no-op (the
  # changeset has no field changes).
  defp scope_has_attachment_changes?(socket, scope, %Space{} = space) do
    st = Attachments.state(socket, scope)
    data = space.data || %{}

    Map.get(data, "files_folder_uuid") != st.folder_uuid or
      Map.get(data, "featured_image_uuid") != st.featured_image_uuid
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

  defp blank_required_field?(attrs) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)
    is_nil(name) or (is_binary(name) and String.trim(name) == "")
  end

  # Distills the list of `{:error, draft_id, reason}` tuples into a
  # single short flash. Most validation errors are caught up-front
  # by `validate_drafts_for_save/1` now, so this only surfaces if a
  # save reached the DB and failed there (e.g. a constraint violation
  # the schema validator missed). Kind-aware so it reads naturally:
  # "1 floor: <msg>; 2 rooms: <msg>" instead of just "3 failed".
  defp draft_error_summary(errors_with_drafts) when is_list(errors_with_drafts) do
    details =
      errors_with_drafts
      |> Enum.map(fn {:error, _id, reason} -> format_draft_error_reason(reason) end)
      |> Enum.frequencies()
      |> Enum.map_join("; ", fn
        {msg, 1} -> msg
        {msg, n} -> "#{n}× #{msg}"
      end)

    gettext("Location saved, but %{count} space(s) failed: %{details}",
      count: length(errors_with_drafts),
      details: details
    )
  end

  defp format_draft_error_reason(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, " / ")}" end)
  end

  defp format_draft_error_reason(reason) when is_atom(reason),
    do: Errors.message(reason)

  defp format_draft_error_reason(reason),
    do: inspect(reason)

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
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <%!-- Tiny JS hook that pushes `set_active_upload_scope` on
           `dragenter` so drag-and-drop uploads route to the right
           folder even when the user hasn't clicked the dropzone first.
           Inline because the registration must run BEFORE LiveSocket
           is constructed (the spread `{...window.PhoenixKitHooks}` in
           the parent app's app.js captures whatever's there at that
           moment). Idempotency guard so LV re-renders don't try to
           re-register. --%>
      <script>
        window.PhoenixKitHooks = window.PhoenixKitHooks || {};
        window.PhoenixKitHooks.PkLocationsUploadScope = window.PhoenixKitHooks.PkLocationsUploadScope || {
          mounted() {
            const push = () => {
              const scope = this.el.dataset.scope;
              if (scope) this.pushEvent("set_active_upload_scope", { scope: scope });
            };
            // `dragenter` fires when a file is dragged INTO the dropzone
            // — well before the actual `drop` event the upload listens
            // for. By the time the drop hits, the server has already
            // received the scope and set `:active_upload_scope`.
            this.el.addEventListener("dragenter", push);
          }
        };
      </script>

      <%!-- Folder-scoped media selector (featured-image picker). The
           dropzone in each Files card uses the LV upload channel
           directly — modal is featured-image-only. `scope_folder_id`
           pulls the folder of whichever scope opened the modal (set
           on click in `open_featured_image_picker/2`). --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="location-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={Attachments.state(%{assigns: assigns}, @media_selector_scope).folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.admin_page_header
        title={@page_title}
        subtitle={if @action == :new, do: gettext("Add a new location."), else: gettext("Update location details.")}
      />

      <%!-- Form content capped at 5xl (matches AI module pattern). --%>
      <div class="max-w-5xl mx-auto w-full">
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
            />

            <.input
              field={@form[:address_line_2]}
              type="text"
              label={gettext("Address Line 2")}
              placeholder={gettext("Apartment, suite, unit, building, floor")}
            />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input field={@form[:city]} type="text" label={gettext("City")} />
              <.input field={@form[:state]} type="text" label={gettext("State / Region")} />
            </div>

            <%!-- `check_address` reads all 3 address fields off the
                 changeset; one blur on postal_code (the natural
                 "I'm done with the address" point) does the same job
                 as binding to all three. --%>
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
        <%!-- FILES & FEATURED IMAGE — Location scope                --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-4">
            <.files_card_body
              scope={location_scope()}
              state={Attachments.state(%{assigns: assigns}, location_scope())}
              uploads={@uploads}
              featured_subtitle={gettext("Shown alongside this location in listings.")}
              files_subtitle={gettext("Floor plans, brochures, certificates. Any file type is accepted.")}
              remove_file_confirm={gettext("Remove this file from the location? If it's not attached to any other resource, it will be moved to trash (admins can restore).")}
            />
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

    active_floor =
      if assigns.active_floor_id,
        do: find_draft(assigns.space_drafts, assigns.active_floor_id),
        else: nil

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
    <%!-- The Spaces card visually nests under the Location: a subtle
         inset (mx-2) + side accent borders + a tinted background make
         it clear where the section starts and ends, instead of looking
         like just another sibling card stacked beside Public Info /
         Files / Internal. --%>
    <div class="card bg-base-200/40 shadow-lg mt-6 mx-2 border-l-4 border-r-4 border-primary/40">
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
            rows="2"
            placeholder={gettext("Admin-only notes...")}
            class="min-h-[4rem]"
          />
        </div>
      </details>

      <%!-- Per-floor Files + Featured image. Scoped by the floor's
           draft id so this dropzone routes uploads to the floor's
           folder, independent of other Files cards on the page. --%>
      <div class="border-t border-base-300 pt-4 flex flex-col gap-4">
        <.files_card_body
          scope={@floor.id}
          state={Attachments.state(%{assigns: assigns}, @floor.id)}
          uploads={@uploads}
          featured_subtitle={gettext("Shown for this floor.")}
          files_subtitle={gettext("Floor plans, photos, anything specific to this floor.")}
          remove_file_confirm={gettext("Remove this file from the floor?")}
        />
      </div>

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
            rows="2"
            placeholder={gettext("Admin-only notes...")}
            class="min-h-[4rem]"
          />
        </div>
      </details>

      <%!-- Per-room Files + Featured image — independent scope. --%>
      <div class="border-t border-base-300 pt-4 flex flex-col gap-4">
        <.files_card_body
          scope={@room.id}
          state={Attachments.state(%{assigns: assigns}, @room.id)}
          uploads={@uploads}
          featured_subtitle={gettext("Shown for this room.")}
          files_subtitle={gettext("Photos, layouts, anything specific to this room.")}
          remove_file_confirm={gettext("Remove this file from the room?")}
        />
      </div>

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

  # Reusable Files + Featured Image card body. Renders the same UI
  # for Location, floors, and rooms — each instance scoped by the
  # `scope` attr, which is forwarded as `phx-value-scope` on every
  # event button. The single shared upload config is owned by the
  # parent LV; each dropzone here also sets `:active_upload_scope`
  # on click so the upload routes to the right folder.
  attr(:scope, :string, required: true)
  attr(:state, :map, required: true, doc: "Map from `Attachments.state/2`")
  attr(:uploads, :map, required: true)
  attr(:featured_subtitle, :string, default: nil)
  attr(:files_subtitle, :string, default: nil)
  attr(:remove_file_confirm, :string, default: nil)

  defp files_card_body(assigns) do
    assigns =
      assigns
      |> Phoenix.Component.assign_new(:featured_subtitle, fn ->
        gettext("Shown alongside this item in listings.")
      end)
      |> Phoenix.Component.assign_new(:files_subtitle, fn ->
        gettext("Floor plans, brochures, certificates. Any file type is accepted.")
      end)
      |> Phoenix.Component.assign_new(:remove_file_confirm, fn ->
        gettext(
          "Remove this file? If it's not attached to any other resource, it will be moved to trash (admins can restore)."
        )
      end)

    ~H"""
    <div class="flex items-center justify-between">
      <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
        <.icon name="hero-photo" class="w-4 h-4" /> {gettext("Featured Image")}
      </h2>
      <span class="text-xs text-base-content/50">{@featured_subtitle}</span>
    </div>

    <%= if @state.featured_image_file do %>
      <div class="flex items-center gap-4">
        <a
          href={URLSigner.signed_url(@state.featured_image_uuid, "original")}
          target="_blank"
          rel="noopener"
          class="shrink-0"
          title={gettext("Open original")}
        >
          <img
            src={URLSigner.signed_url(@state.featured_image_uuid, "thumbnail")}
            alt={@state.featured_image_file.original_file_name}
            class="w-24 h-24 rounded-md object-cover bg-base-200 border border-base-300"
          />
        </a>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium truncate">{@state.featured_image_file.original_file_name}</p>
          <p class="text-xs text-base-content/50">{Attachments.format_file_size(@state.featured_image_file.size)}</p>
        </div>
        <div class="flex flex-col gap-2">
          <button
            type="button"
            phx-click="open_featured_image_picker"
            phx-value-scope={@scope}
            class="btn btn-sm btn-outline"
          >
            {gettext("Change")}
          </button>
          <button
            type="button"
            phx-click="clear_featured_image"
            phx-value-scope={@scope}
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
        <button
          type="button"
          phx-click="open_featured_image_picker"
          phx-value-scope={@scope}
          class="btn btn-sm btn-primary"
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Set featured image")}
        </button>
      </div>
    <% end %>

    <div class="divider my-0"></div>

    <div class="flex flex-col gap-0.5">
      <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
        <.icon name="hero-paper-clip" class="w-4 h-4" /> {gettext("Attached Files")}
        <span :if={@state.files != []} class="badge badge-sm badge-ghost ml-1">
          {length(@state.files)}
        </span>
      </h2>
      <p class="text-xs text-base-content/50">{@files_subtitle}</p>
    </div>

    <%!-- Dropzone: phx-click covers the click path; the JS hook
         (registered at the top of the page render) sets the scope
         on `dragenter` so drag-and-drop uploads route to the right
         folder without requiring a prior click. The label also
         forwards clicks to the hidden <input type=file>. --%>
    <label
      id={"pk-locations-dropzone-#{@scope}"}
      for={@uploads.attachment_files.ref}
      class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
      phx-click="set_active_upload_scope"
      phx-value-scope={@scope}
      phx-drop-target={@uploads.attachment_files.ref}
      phx-hook="PkLocationsUploadScope"
      data-scope={@scope}
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

    <%= if @state.files == [] do %>
      <div class="flex flex-col items-center gap-2 py-10 text-center border border-dashed border-base-300 rounded-md">
        <.icon name="hero-paper-clip" class="w-8 h-8 text-base-content/30" />
        <p class="text-sm text-base-content/50">{gettext("No files attached yet.")}</p>
      </div>
    <% else %>
      <ul class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <li
          :for={file <- @state.files}
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
            phx-value-scope={@scope}
            phx-value-uuid={file.uuid}
            phx-disable-with={gettext("Removing...")}
            data-confirm={@remove_file_confirm}
            class="btn btn-ghost btn-xs btn-square"
            title={gettext("Remove")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </li>
      </ul>
    <% end %>
    """
  end

  # Per-form language strip used inside floor / room editors. Wraps
  # the core <.language_switcher> with the right click event so the
  # switch updates only the active draft's `current_lang` — NOT the
  # page-level `:current_lang` that drives the Location's own
  # multilang_tabs at the top of the form.
  attr(:language_tabs, :list, required: true)
  attr(:current_lang, :string, required: true)

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

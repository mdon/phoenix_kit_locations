defmodule PhoenixKitLocations.Web.Components.PlacePicker do
  @moduledoc """
  LiveComponent for picking a Location, and optionally a Space inside
  it, in one widget — a search-combobox for the Location half and the
  existing `SpaceTree` (read-only picker mode) for the Space half.

  Drop one into any LiveView. Each instance owns its own search/tree
  state; the parent only reacts to one message:

      {:place_picker_select, id, %{location_uuid: uuid, space_uuid: uuid_or_nil}}

  `space_uuid` is `nil` when the user picks "Use this location (no
  specific space)" instead of drilling into the tree. The tree stays
  open after a selection, so a consumer can immediately pick a
  different node without re-searching for the Location.

  ## Two halves

    * **Location** — a search-combobox mirroring
      `PhoenixKitCatalogue.Web.Components.ItemPicker`: type to filter,
      click a result to select. Locations are typically few, so
      filtering happens in Elixir over `Locations.list_locations/1`'s
      full result rather than a dedicated search function (unlike
      `Catalogue.search_items/2`).
    * **Space** — once a Location is picked, its tree
      (`Spaces.list_tree/1`) renders through `SpaceTree.space_tree/1`
      with `show_actions={false}` — the same read-only mode built for
      this purpose. Selecting a node, or the "Use this location"
      button above the tree, sends the `:place_picker_select` message.

  ## Attrs

    * `:id` (required) — unique DOM/component id, echoed back in every
      `:place_picker_select` message.
    * `:location_type_uuid` — restricts the Location search to this
      type. Resolve the uuid yourself via
      `Locations.get_location_type_by_name/1` first — this component
      doesn't resolve type names itself, keeping its own API small.
      `nil` (default) searches every active Location.
    * `:selected_location_uuid`, `:selected_space_uuid` — optional,
      default `nil`. `:selected_space_uuid` seeds the tree's initial
      highlight (`space_tree/1`'s `selected_uuid`); from then on this
      component keeps it in sync itself as the user picks a node (and
      clears it back to `nil` on `select_location`/`clear_location`/
      "Use this location") — a consumer doesn't need to echo the attr
      back just to see the highlight update. `:selected_location_uuid`
      is accepted for symmetry but not currently consumed — the
      Location half is always driven by the search-combobox in this
      version.
    * `:locale` — when given, Location names (search results and the
      selected-location heading) show the translated name, same
      `_name`/`name` fallback chain as `Spaces.full_path/2`. `nil`
      (default) always shows the primary-language name. Space names
      inside the tree are not translated — `SpaceTree` itself doesn't
      support that (existing limitation, unrelated to this component).

  ## Usage

      type = Locations.get_location_type_by_name("Warehouse")

      <.live_component
        module={PhoenixKitLocations.Web.Components.PlacePicker}
        id="picker-1"
        location_type_uuid={type && type.uuid}
      />
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitLocations.Web.Components.SpaceTree, only: [space_tree: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Spaces

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       matches: [],
       open: false,
       selected_location: nil,
       tree: [],
       expanded: MapSet.new(),
       location_type_uuid: nil,
       selected_location_uuid: nil,
       selected_space_uuid: nil,
       locale: nil
     )}
  end

  # ─────────────────────────────────────────────────────────────────
  # Events — Location search
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("location_query_change", %{"value" => value}, socket) do
    {:noreply, socket |> assign(:query, value) |> assign(:open, true) |> run_search()}
  end

  def handle_event("open", _params, socket) do
    socket =
      if socket.assigns.matches == [] and socket.assigns.query == "" do
        run_search(assign(socket, :open, true))
      else
        assign(socket, :open, true)
      end

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("select_location", %{"uuid" => uuid}, socket) do
    case Locations.get_location(uuid) do
      nil ->
        {:noreply, socket}

      %Location{} = location ->
        {:noreply,
         socket
         |> assign(:selected_location, location)
         |> assign(:tree, Spaces.list_tree(location.uuid))
         |> assign(:expanded, MapSet.new())
         |> assign(:selected_space_uuid, nil)
         |> assign(:open, false)
         |> assign(:query, "")
         |> assign(:matches, [])}
    end
  end

  def handle_event("clear_location", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_location, nil)
     |> assign(:tree, [])
     |> assign(:expanded, MapSet.new())
     |> assign(:selected_space_uuid, nil)
     |> assign(:query, "")
     |> assign(:matches, [])
     |> assign(:open, false)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Events — Space tree, read-only picker mode. Names match
  # `SpaceTree.space_tree/1`'s own event-name defaults — it targets
  # `@myself` for us, since we pass `myself={@myself}` below.
  # ─────────────────────────────────────────────────────────────────

  def handle_event("toggle_space_node", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("select_space", %{"uuid" => uuid}, socket) do
    {:noreply, send_selection(socket, uuid)}
  end

  def handle_event("select_location_only", _params, socket) do
    {:noreply, send_selection(socket, nil)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Search
  # ─────────────────────────────────────────────────────────────────

  defp run_search(socket) do
    matches =
      [status: "active", type_uuid: socket.assigns.location_type_uuid]
      |> Locations.list_locations()
      |> filter_by_query(socket.assigns.query)

    assign(socket, :matches, matches)
  end

  defp filter_by_query(locations, query) do
    case String.trim(query || "") do
      "" ->
        locations

      trimmed ->
        needle = String.downcase(trimmed)
        Enum.filter(locations, &String.contains?(String.downcase(&1.name), needle))
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Selection messaging
  # ─────────────────────────────────────────────────────────────────

  # Notifies the parent and mirrors the pick into local state so the
  # tree's highlight (`selected_uuid={@selected_space_uuid}`) updates
  # immediately — the caller doesn't have to echo the attr back in.
  #
  # `select_space`/`select_location_only` only render once a Location
  # is selected, so a normal click can't reach here with
  # `selected_location: nil` — this clause guards a stale queued event
  # racing a `clear_location` click instead (mirrors `ItemPicker`'s own
  # `select` handler no-op-ing on an unresolvable uuid).
  defp send_selection(
         %{assigns: %{selected_location: %Location{} = location}} = socket,
         space_uuid
       ) do
    send(
      self(),
      {:place_picker_select, socket.assigns.id,
       %{location_uuid: location.uuid, space_uuid: space_uuid}}
    )

    assign(socket, :selected_space_uuid, space_uuid)
  end

  defp send_selection(socket, _space_uuid), do: socket

  # ─────────────────────────────────────────────────────────────────
  # Display helpers
  # ─────────────────────────────────────────────────────────────────

  defp location_display_name(%Location{name: name}, nil), do: name

  defp location_display_name(%Location{data: data, name: name}, locale) do
    translation = Multilang.get_language_data(data, locale)
    Map.get(translation, "_name") || Map.get(translation, "name") || name
  end

  defp location_subtitle(%Location{address_line_1: line1, city: city}) do
    [line1, city]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  # ─────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="relative w-full" phx-click-away={JS.push("close", target: @myself)}>
      <div class="flex flex-col gap-2">
        <div :if={@selected_location} class="flex items-center justify-between gap-2">
          <span class="text-sm font-medium truncate flex items-center gap-1">
            <.icon name="hero-map-pin" class="w-4 h-4 shrink-0 text-base-content/50" />
            {location_display_name(@selected_location, @locale)}
          </span>
          <button
            type="button"
            phx-click="clear_location"
            phx-target={@myself}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Change")}
          </button>
        </div>

        <button
          :if={@selected_location}
          type="button"
          phx-click="select_location_only"
          phx-target={@myself}
          class="btn btn-ghost btn-sm justify-start"
        >
          <.icon name="hero-check" class="w-4 h-4 mr-1" />
          {gettext("Use this location (no specific space)")}
        </button>

        <.space_tree
          :if={@selected_location}
          tree={@tree}
          expanded={@expanded}
          selected_uuid={@selected_space_uuid}
          myself={@myself}
          show_actions={false}
        />

        <input
          :if={!@selected_location}
          id={"#{@id}-input"}
          type="text"
          role="combobox"
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-listbox"}
          aria-autocomplete="list"
          autocomplete="off"
          value={@query}
          placeholder={gettext("Search locations…")}
          phx-target={@myself}
          phx-change="location_query_change"
          phx-debounce="300"
          phx-focus="open"
          class="input input-sm w-full"
        />
      </div>

      <ul
        :if={!@selected_location and @open and @matches != []}
        id={"#{@id}-listbox"}
        role="listbox"
        class="absolute z-50 mt-1 w-full max-h-64 overflow-y-auto bg-base-100 border border-base-300 rounded-box shadow-lg"
      >
        <li
          :for={location <- @matches}
          role="option"
          class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-base-200"
          phx-click="select_location"
          phx-value-uuid={location.uuid}
          phx-target={@myself}
        >
          <div class="min-w-0 flex-1">
            <div class="font-medium text-sm truncate">
              {location_display_name(location, @locale)}
            </div>
            <div
              :if={location_subtitle(location) != ""}
              class="text-xs text-base-content/50 truncate"
            >
              {location_subtitle(location)}
            </div>
          </div>
        </li>
      </ul>

      <div
        :if={!@selected_location and @open and @matches == [] and @query != ""}
        class="absolute z-50 mt-1 w-full bg-base-100 border border-base-300 rounded-box shadow-lg px-3 py-2 text-sm text-base-content/50"
      >
        {gettext("No locations found")}
      </div>
    </div>
    """
  end
end

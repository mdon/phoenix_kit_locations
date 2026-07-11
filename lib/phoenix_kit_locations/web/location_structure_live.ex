defmodule PhoenixKitLocations.Web.LocationStructureLive do
  @moduledoc """
  The "Structure" tab of a Location's admin page — mounts the Location,
  loads its Space tree via `Spaces.list_tree/1`, and renders it through
  `SpaceTree.space_tree/1` next to `LocationTabs.location_tabs/1` (the
  shared tab header with `LocationFormLive`'s "Details" tab).

  This is the mount + read-only skeleton: only expand/collapse
  (`toggle_space_node`) and node selection (`select_space`, which just
  highlights the node for now) are wired here. CRUD
  (create/rename/reorder/delete) and the detail panel underneath the
  tree are added by later tasks in the same plan.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitLocations.Web.Components.LocationTabs, only: [location_tabs: 1]
  import PhoenixKitLocations.Web.Components.SpaceTree, only: [space_tree: 1]

  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Spaces

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case Locations.get_location(uuid) do
      nil ->
        Logger.info("Location not found for structure: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      location ->
        {:ok,
         assign(socket,
           location: location,
           tree: Spaces.list_tree(location.uuid),
           expanded: MapSet.new(),
           selected_uuid: nil,
           page_title: page_title(location)
         )}
    end
  end

  defp page_title(location), do: gettext("%{name} — Structure", name: location.name)

  @impl true
  def handle_event("toggle_space_node", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("select_space", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :selected_uuid, uuid)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <.admin_page_header title={@location.name} />

      <div class="max-w-5xl mx-auto w-full flex flex-col gap-4">
        <.location_tabs location={@location} active={:structure} />

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <.space_tree
              tree={@tree}
              expanded={@expanded}
              selected_uuid={@selected_uuid}
              myself={nil}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end

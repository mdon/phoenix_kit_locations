defmodule PhoenixKitLocations.Web.LocationStructureLive do
  @moduledoc """
  The "Structure" tab of a Location's admin page — mounts the Location,
  loads its Space tree via `Spaces.list_tree/1`, and renders it through
  `SpaceTree.space_tree/1` next to `LocationTabs.location_tabs/1` (the
  shared tab header with `LocationFormLive`'s "Details" tab).

  Besides the mount + read-only tree render (expand/collapse via
  `toggle_space_node`, node selection via `select_space`), this module
  owns the tree's CRUD surface: creating a root or child space through
  a small inline form below the tree, inline rename, sibling reorder
  (move up/down), and hard delete. Every mutating call commits straight
  to `Spaces` — the "immediate commit" model (orchestrator decision #4
  at the top of the plan): no staged drafts, no separate save step.

  The detail panel underneath the tree (multilang name/description,
  status, notes, attachments) is added by a later task in the same
  plan.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitLocations.Web.Components.LocationTabs, only: [location_tabs: 1]
  import PhoenixKitLocations.Web.Components.SpaceTree, only: [space_tree: 1]

  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.Space
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
           renaming_uuid: nil,
           renaming_text: "",
           adding_parent_uuid: nil,
           new_space_form: nil,
           page_title: page_title(location)
         )}
    end
  end

  defp page_title(location), do: gettext("%{name} — Structure", name: location.name)

  # ── Expand / select (mount skeleton) ─────────────────────────────

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

  # ── Add root / child space ───────────────────────────────────────

  def handle_event("open_add_root", _params, socket) do
    {:noreply, assign(socket, adding_parent_uuid: :root, new_space_form: new_space_form())}
  end

  def handle_event("open_add_child", %{"parent_uuid" => parent_uuid}, socket) do
    {:noreply, assign(socket, adding_parent_uuid: parent_uuid, new_space_form: new_space_form())}
  end

  def handle_event("cancel_add_space", _params, socket) do
    {:noreply, assign(socket, adding_parent_uuid: nil, new_space_form: nil)}
  end

  def handle_event("validate_new_space", %{"space" => params}, socket) do
    changeset =
      %Space{}
      |> Spaces.change_space(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_space_form, to_form(changeset, as: :space))}
  end

  def handle_event("create_space", %{"space" => params}, socket) do
    location = socket.assigns.location
    parent_uuid = normalize_parent_uuid(socket.assigns.adding_parent_uuid)
    attrs = Map.merge(params, %{"location_uuid" => location.uuid, "parent_uuid" => parent_uuid})

    case Spaces.create_space(attrs, actor_opts(socket)) do
      {:ok, space} ->
        {:noreply,
         socket
         |> assign(:tree, Spaces.list_tree(location.uuid))
         |> assign(:expanded, expand_parent(socket.assigns.expanded, parent_uuid))
         |> assign(:adding_parent_uuid, nil)
         |> assign(:new_space_form, nil)
         |> assign(:selected_uuid, space.uuid)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_space_form, to_form(changeset, as: :space))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # ── Inline rename ────────────────────────────────────────────────

  def handle_event("start_rename_space", %{"uuid" => uuid}, socket) do
    case Spaces.get_space(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:space_not_found))}

      space ->
        {:noreply, assign(socket, renaming_uuid: uuid, renaming_text: space.name)}
    end
  end

  def handle_event("rename_space_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :renaming_text, name)}
  end

  def handle_event("cancel_rename_space", _params, socket) do
    {:noreply, assign(socket, renaming_uuid: nil, renaming_text: "")}
  end

  def handle_event("rename_space", %{"uuid" => uuid, "name" => name}, socket) do
    case Spaces.get_space(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(:space_not_found))
         |> assign(renaming_uuid: nil, renaming_text: "")}

      space ->
        {:noreply, submit_rename(socket, space, name)}
    end
  end

  # ── Reorder ───────────────────────────────────────────────────────

  def handle_event("move_space_up", %{"uuid" => uuid}, socket) do
    {:noreply, move_sibling(socket, uuid, -1)}
  end

  def handle_event("move_space_down", %{"uuid" => uuid}, socket) do
    {:noreply, move_sibling(socket, uuid, 1)}
  end

  # ── Delete ────────────────────────────────────────────────────────

  def handle_event("delete_space", %{"uuid" => uuid}, socket) do
    case Spaces.get_space(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:space_not_found))}

      space ->
        {:noreply, submit_delete(socket, space, uuid)}
    end
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
              renaming_uuid={@renaming_uuid}
              renaming_text={@renaming_text}
              myself={nil}
            />
          </div>
        </div>

        <div :if={@adding_parent_uuid} class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <.icon name="hero-plus" class="w-4 h-4" />
              {add_space_heading(@tree, @adding_parent_uuid)}
            </h2>

            <.form
              for={@new_space_form}
              id="new-space-form"
              action="#"
              phx-change="validate_new_space"
              phx-submit="create_space"
              class="flex flex-col gap-4"
            >
              <div class="flex flex-col sm:flex-row gap-4">
                <.select
                  field={@new_space_form[:kind]}
                  label={gettext("Kind")}
                  options={Enum.map(Space.kinds(), &{Space.kind_label(&1), &1})}
                  class="sm:w-48"
                />
                <.input
                  field={@new_space_form[:name]}
                  type="text"
                  label={gettext("Name")}
                  required
                  class="flex-1"
                />
              </div>

              <div class="flex items-center gap-2">
                <button type="submit" class="btn btn-primary btn-sm">
                  {gettext("Add")}
                </button>
                <button type="button" phx-click="cancel_add_space" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp new_space_form, do: to_form(Spaces.change_space(%Space{}), as: :space)

  defp normalize_parent_uuid(:root), do: nil
  defp normalize_parent_uuid(uuid) when is_binary(uuid), do: uuid

  defp expand_parent(expanded, nil), do: expanded
  defp expand_parent(expanded, parent_uuid), do: MapSet.put(expanded, parent_uuid)

  defp add_space_heading(_tree, :root), do: gettext("Add root space")

  defp add_space_heading(tree, parent_uuid) do
    case find_node(tree, parent_uuid) do
      nil -> gettext("Add space")
      node -> gettext("Add space under %{name}", name: node.name)
    end
  end

  defp submit_rename(socket, space, name) do
    case Spaces.update_space(space, %{"name" => name}, actor_opts(socket)) do
      {:ok, _updated} ->
        socket
        |> assign(:tree, Spaces.list_tree(socket.assigns.location.uuid))
        |> assign(renaming_uuid: nil, renaming_text: "")

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, gettext("Failed to rename space"))

      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp submit_delete(socket, space, uuid) do
    case Spaces.delete_space(space, actor_opts(socket)) do
      {:ok, _deleted} ->
        selected_uuid =
          if socket.assigns.selected_uuid == uuid, do: nil, else: socket.assigns.selected_uuid

        socket
        |> assign(:tree, Spaces.list_tree(socket.assigns.location.uuid))
        |> assign(:selected_uuid, selected_uuid)

      {:error, _changeset} ->
        put_flash(socket, :error, gettext("Failed to delete space"))
    end
  end

  defp move_sibling(socket, uuid, direction) do
    case locate(socket.assigns.tree, uuid) do
      nil ->
        put_flash(socket, :error, Errors.message(:space_not_found))

      {siblings, index} ->
        target = index + direction

        if target in 0..(length(siblings) - 1) do
          apply_reorder(socket, siblings, index, target)
        else
          socket
        end
    end
  end

  defp apply_reorder(socket, siblings, index, target) do
    location = socket.assigns.location
    parent_uuid = siblings |> hd() |> Map.get(:parent_uuid)
    reordered_uuids = siblings |> Enum.map(& &1.uuid) |> swap(index, target)

    case Spaces.reorder_siblings(location.uuid, parent_uuid, reordered_uuids, actor_opts(socket)) do
      {:ok, :reordered} -> assign(socket, :tree, Spaces.list_tree(location.uuid))
      {:error, reason} -> put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp swap(list, i, j) do
    vi = Enum.at(list, i)
    vj = Enum.at(list, j)

    list
    |> List.replace_at(i, vj)
    |> List.replace_at(j, vi)
  end

  defp find_node(tree, uuid) do
    case locate(tree, uuid) do
      {siblings, index} -> Enum.at(siblings, index)
      nil -> nil
    end
  end

  # Recursively finds `uuid`'s containing sibling list and its index
  # within it — shared by the reorder handlers (need the full ordered
  # sibling group to hand `Spaces.reorder_siblings/4`) and
  # `find_node/2` (needs just the node). Returns `nil` if `uuid` isn't
  # anywhere in `tree`.
  defp locate(tree, uuid) do
    case Enum.find_index(tree, &(&1.uuid == uuid)) do
      nil -> Enum.find_value(tree, &locate(&1.children, uuid))
      index -> {tree, index}
    end
  end
end

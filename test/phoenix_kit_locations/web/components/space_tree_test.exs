defmodule PhoenixKitLocations.Web.Components.SpaceTreeTest do
  @moduledoc """
  Pure `render_component/2` tests for `SpaceTree.space_tree/1` (and,
  transitively, the recursive `space_tree_node/1`) — no DB needed. The
  component only ever reads the `%Space{}` node shape produced by
  `Spaces.list_tree/1` (`node.kind`/`node.uuid`/`node.name`/
  `node.status`/`node.children` — never `node.space.kind`, see the
  component moduledoc), so fixture trees below are built by hand with
  plain struct literals rather than through the `Spaces` context.

  Every assign the component template reads via `@foo` is supplied
  explicitly through `base_assigns/1` — `render_component/2` invokes
  the target function directly (bypassing the `<.space_tree .../>`
  HEEx call-site, which is what normally fills in `attr` defaults), so
  relying on declared defaults being merged in automatically here would
  be unsafe.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitLocations.Schemas.Space
  alias PhoenixKitLocations.Web.Components.SpaceTree

  defp space_node(attrs) do
    struct!(Space, Map.merge(%{status: "active", children: []}, attrs))
  end

  # Floor 1 (root)
  #   └─ Zone A
  #        └─ Shelf 1 (inactive)
  defp three_level_tree do
    shelf = space_node(%{uuid: "shelf-1", kind: "shelf", name: "Shelf 1", status: "inactive"})
    zone = space_node(%{uuid: "zone-1", kind: "zone", name: "Zone A", children: [shelf]})
    floor = space_node(%{uuid: "floor-1", kind: "floor", name: "Floor 1", children: [zone]})
    [floor]
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        tree: [],
        expanded: MapSet.new(),
        selected_uuid: nil,
        renaming_uuid: nil,
        renaming_text: "",
        myself: nil,
        on_select: "select_space",
        on_toggle: "toggle_space_node",
        on_add_root: "open_add_root",
        show_actions: true
      },
      overrides
    )
  end

  defp render_tree(overrides) do
    render_component(&SpaceTree.space_tree/1, base_assigns(overrides))
  end

  defp count_occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  describe "empty tree" do
    test "renders the empty-state message" do
      html = render_tree(%{})
      assert html =~ "No spaces yet."
    end

    test "shows the add-root button when show_actions is true (default)" do
      html = render_tree(%{})
      assert html =~ "Add root space"
      assert html =~ ~s(phx-click="open_add_root")
    end

    test "hides the add-root button when show_actions is false" do
      html = render_tree(%{show_actions: false})
      refute html =~ "Add root space"
    end
  end

  describe "nested rendering" do
    test "renders only the root when nothing is expanded" do
      html = render_tree(%{tree: three_level_tree()})

      assert html =~ "Floor 1"
      refute html =~ "Zone A"
      refute html =~ "Shelf 1"
    end

    test "renders down to a leaf once every ancestor is expanded" do
      html =
        render_tree(%{
          tree: three_level_tree(),
          expanded: MapSet.new(["floor-1", "zone-1"])
        })

      assert html =~ "Floor 1"
      assert html =~ "Zone A"
      assert html =~ "Shelf 1"
    end

    test "expanding only the parent stops one level short of the grandchild" do
      html = render_tree(%{tree: three_level_tree(), expanded: MapSet.new(["floor-1"])})

      assert html =~ "Zone A"
      refute html =~ "Shelf 1"
    end

    test "renders each node's translated kind label and an inactive badge" do
      html =
        render_tree(%{
          tree: three_level_tree(),
          expanded: MapSet.new(["floor-1", "zone-1"])
        })

      assert html =~ Space.kind_label("shelf")
      assert html =~ "Inactive"
    end

    test "highlights the selected node" do
      html = render_tree(%{tree: three_level_tree(), selected_uuid: "floor-1"})
      assert html =~ "bg-primary/10"
    end
  end

  describe "show_actions — picker mode" do
    test "true (default) renders rename/reorder/add-child/delete controls" do
      html = render_tree(%{tree: three_level_tree()})

      assert html =~ ~s(phx-click="start_rename_space")
      assert html =~ ~s(phx-click="open_add_child")
      assert html =~ ~s(phx-click="delete_space")
    end

    test "false hides rename/reorder/add-child/delete but keeps select + expand/collapse" do
      html =
        render_tree(%{
          tree: three_level_tree(),
          expanded: MapSet.new(["floor-1"]),
          show_actions: false
        })

      refute html =~ ~s(phx-click="start_rename_space")
      refute html =~ ~s(phx-click="open_add_child")
      refute html =~ ~s(phx-click="delete_space")
      refute html =~ ~s(phx-click="move_space_up")
      refute html =~ ~s(phx-click="move_space_down")

      # Select + expand/collapse survive picker mode — only the CRUD
      # affordances are hidden.
      assert html =~ ~s(phx-value-uuid="floor-1")
      assert html =~ ~s(phx-click="toggle_space_node")
    end
  end

  describe "sibling position — move up/down button visibility" do
    test "first sibling hides move-up, last hides move-down, middle shows both" do
      siblings = [
        space_node(%{uuid: "s-1", kind: "floor", name: "Floor 1"}),
        space_node(%{uuid: "s-2", kind: "floor", name: "Floor 2"}),
        space_node(%{uuid: "s-3", kind: "floor", name: "Floor 3"})
      ]

      html = render_tree(%{tree: siblings})

      # One delete button per node, but only 2 move-up + 2 move-down —
      # the first sibling has no move-up, the last has no move-down.
      assert count_occurrences(html, ~s(phx-click="delete_space")) == 3
      assert count_occurrences(html, ~s(phx-click="move_space_up")) == 2
      assert count_occurrences(html, ~s(phx-click="move_space_down")) == 2
    end

    test "a lone sibling hides both move-up and move-down" do
      html = render_tree(%{tree: [space_node(%{uuid: "solo", kind: "floor", name: "Solo"})]})

      refute html =~ ~s(phx-click="move_space_up")
      refute html =~ ~s(phx-click="move_space_down")
    end
  end
end

defmodule PhoenixKitLocations.SpacesTest do
  @moduledoc """
  Context-level tests for `PhoenixKitLocations.Spaces` — cross-row
  invariants (same-Location parent, cycle prevention on reparenting),
  tree assembly (`list_tree/1`), sibling reordering (including the
  root-level `is_nil` regression guarded in `sibling_position_query/3`),
  and cascade delete.

  Promised by the moduledoc in
  `test/phoenix_kit_locations/schemas/space_test.exs`, which covers
  only the schema-level changeset contract.
  """

  use PhoenixKitLocations.DataCase, async: true

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Spaces

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_location(attrs \\ %{}) do
    {:ok, l} = Locations.create_location(Map.merge(%{name: "Test Location"}, attrs))
    l
  end

  # String-keyed attrs throughout — `Spaces.update_space/3` internally
  # does `Map.put_new(attrs, "location_uuid", ...)`, so atom-keyed attrs
  # passed to it would raise `Ecto.CastError` on mixed keys. Keeping
  # every call site here string-keyed (matching how `LocationStructureLive`
  # actually calls this context) avoids the trap entirely.
  #
  # No default for `attrs` — every call site below sets at least
  # `kind`/`name` explicitly, so a bare default would be dead code.
  defp create_space(location_uuid, attrs) do
    base = %{"location_uuid" => location_uuid, "kind" => "floor", "name" => "Space"}
    {:ok, space} = Spaces.create_space(Map.merge(base, attrs))
    space
  end

  defp positions_by_uuid(location_uuid) do
    location_uuid
    |> Spaces.list_for_location()
    |> Map.new(&{&1.uuid, &1.position})
  end

  # ═══════════════════════════════════════════════════════════════════
  # create_space/2
  # ═══════════════════════════════════════════════════════════════════

  describe "create_space/2 — new kinds" do
    test "persists a space for each of the new kinds (zone, section, aisle, shelf)" do
      location = create_location()

      for kind <- ~w(zone section aisle shelf) do
        assert {:ok, space} =
                 Spaces.create_space(%{
                   "location_uuid" => location.uuid,
                   "kind" => kind,
                   "name" => "#{kind} 1"
                 })

        assert space.kind == kind
        assert Spaces.get_space(space.uuid).kind == kind
      end
    end
  end

  describe "create_space/2 — same-Location parent invariant" do
    test "rejects a parent that lives in a different Location" do
      loc1 = create_location(%{name: "Location 1"})
      loc2 = create_location(%{name: "Location 2"})
      parent = create_space(loc1.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      assert {:error, :parent_in_other_location} =
               Spaces.create_space(%{
                 "location_uuid" => loc2.uuid,
                 "parent_uuid" => parent.uuid,
                 "kind" => "room",
                 "name" => "Room X"
               })
    end

    test "accepts a parent that lives in the same Location" do
      location = create_location()
      parent = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      assert {:ok, child} =
               Spaces.create_space(%{
                 "location_uuid" => location.uuid,
                 "parent_uuid" => parent.uuid,
                 "kind" => "room",
                 "name" => "Room 1"
               })

      assert child.parent_uuid == parent.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # update_space/3 — cycle prevention (reparenting)
  # ═══════════════════════════════════════════════════════════════════

  describe "update_space/3 — cycle prevention" do
    test "rejects reparenting a space to itself (direct self-loop)" do
      location = create_location()
      a = create_space(location.uuid, %{"kind" => "floor", "name" => "A"})

      assert {:error, :cycle} = Spaces.update_space(a, %{"parent_uuid" => a.uuid})
    end

    test "rejects reparenting a space under its own descendant (indirect cycle)" do
      location = create_location()
      a = create_space(location.uuid, %{"kind" => "floor", "name" => "A"})

      b =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "B",
          "parent_uuid" => a.uuid
        })

      c =
        create_space(location.uuid, %{
          "kind" => "zone",
          "name" => "C",
          "parent_uuid" => b.uuid
        })

      # Chain is A -> B -> C. Reparenting A under C would create a cycle.
      assert {:error, :cycle} = Spaces.update_space(a, %{"parent_uuid" => c.uuid})

      # Rejected before persisting — A's parent is unchanged.
      assert Spaces.get_space(a.uuid).parent_uuid == nil
    end

    test "allows reparenting within the same Location when no cycle would result" do
      location = create_location()
      a = create_space(location.uuid, %{"kind" => "floor", "name" => "A"})
      b = create_space(location.uuid, %{"kind" => "floor", "name" => "B"})

      c =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "C",
          "parent_uuid" => a.uuid
        })

      assert {:ok, updated} = Spaces.update_space(c, %{"parent_uuid" => b.uuid})
      assert updated.parent_uuid == b.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # list_tree/1
  # ═══════════════════════════════════════════════════════════════════

  describe "list_tree/1" do
    test "assembles a 3-level tree (floor -> zone -> shelf) with nested, ordered :children" do
      location = create_location()
      floor = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone_b =
        create_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone B",
          "parent_uuid" => floor.uuid,
          "position" => 1
        })

      zone_a =
        create_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid,
          "position" => 0
        })

      shelf =
        create_space(location.uuid, %{
          "kind" => "shelf",
          "name" => "Shelf 1",
          "parent_uuid" => zone_a.uuid
        })

      assert [floor_node] = Spaces.list_tree(location.uuid)
      assert floor_node.uuid == floor.uuid
      assert floor_node.kind == "floor"

      assert [zone_a_node, zone_b_node] = floor_node.children
      assert zone_a_node.uuid == zone_a.uuid
      assert zone_b_node.uuid == zone_b.uuid

      assert [shelf_node] = zone_a_node.children
      assert shelf_node.uuid == shelf.uuid
      assert shelf_node.kind == "shelf"
      assert shelf_node.children == []

      assert zone_b_node.children == []
    end

    test "returns [] for a Location with no spaces" do
      location = create_location()
      assert Spaces.list_tree(location.uuid) == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # reorder_siblings/4
  # ═══════════════════════════════════════════════════════════════════

  describe "reorder_siblings/4 — root level (parent_uuid: nil)" do
    test "rewrites positions for root-level siblings (regression: is_nil match, not == ^nil)" do
      location = create_location()
      f1 = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})
      f2 = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 2"})
      f3 = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 3"})

      assert {:ok, :reordered} =
               Spaces.reorder_siblings(location.uuid, nil, [f3.uuid, f1.uuid, f2.uuid])

      positions = positions_by_uuid(location.uuid)

      assert positions[f3.uuid] == 0
      assert positions[f1.uuid] == 1
      assert positions[f2.uuid] == 2
    end
  end

  describe "reorder_siblings/4 — non-root" do
    test "rewrites positions for children under a specific parent" do
      location = create_location()
      floor = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      r1 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 1",
          "parent_uuid" => floor.uuid
        })

      r2 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 2",
          "parent_uuid" => floor.uuid
        })

      assert {:ok, :reordered} =
               Spaces.reorder_siblings(location.uuid, floor.uuid, [r2.uuid, r1.uuid])

      positions = positions_by_uuid(location.uuid)

      assert positions[r2.uuid] == 0
      assert positions[r1.uuid] == 1
    end

    test "does not touch positions outside the (location, parent) sibling group" do
      location = create_location()

      floor =
        create_space(location.uuid, %{
          "kind" => "floor",
          "name" => "Floor 1",
          "position" => 5
        })

      r1 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 1",
          "parent_uuid" => floor.uuid
        })

      r2 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 2",
          "parent_uuid" => floor.uuid
        })

      assert {:ok, :reordered} =
               Spaces.reorder_siblings(location.uuid, floor.uuid, [r2.uuid, r1.uuid])

      assert positions_by_uuid(location.uuid)[floor.uuid] == 5
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # delete_space/2
  # ═══════════════════════════════════════════════════════════════════

  describe "delete_space/2 — CASCADE" do
    test "hard-deletes a space and cascades through multiple levels of descendants" do
      location = create_location()
      floor = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        create_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      shelf =
        create_space(location.uuid, %{
          "kind" => "shelf",
          "name" => "Shelf 1",
          "parent_uuid" => zone.uuid
        })

      assert {:ok, _deleted} = Spaces.delete_space(floor)

      assert Spaces.get_space(floor.uuid) == nil
      assert Spaces.get_space(zone.uuid) == nil
      assert Spaces.get_space(shelf.uuid) == nil
    end

    test "leaves unrelated siblings intact" do
      location = create_location()
      floor = create_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      r1 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 1",
          "parent_uuid" => floor.uuid
        })

      r2 =
        create_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 2",
          "parent_uuid" => floor.uuid
        })

      assert {:ok, _} = Spaces.delete_space(r1)

      assert Spaces.get_space(r1.uuid) == nil
      assert Spaces.get_space(r2.uuid).uuid == r2.uuid
    end
  end
end

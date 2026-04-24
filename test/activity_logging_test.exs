defmodule PhoenixKitLocations.ActivityLoggingTest do
  @moduledoc """
  End-to-end assertions that every mutating public API call in
  `PhoenixKitLocations.Locations` writes the expected activity row
  with the right action, resource, actor, and metadata.

  If any of these regress silently (typoed action string, missing
  metadata key, wrong module name, forgetting to log a new mutation),
  these tests fail.
  """

  use PhoenixKitLocations.DataCase, async: true

  alias PhoenixKitLocations.Locations

  @actor Ecto.UUID.generate()

  describe "location type mutations" do
    test "create_location_type logs location_type.created" do
      {:ok, type} = Locations.create_location_type(%{name: "Showroom"}, actor_uuid: @actor)

      row =
        assert_activity_logged("location_type.created",
          resource_uuid: type.uuid,
          actor_uuid: @actor,
          metadata_has: %{"name" => "Showroom", "status" => "active"}
        )

      assert row.module == "locations"
      assert row.mode == "manual"
      assert row.resource_type == "location_type"
    end

    test "update_location_type logs location_type.updated" do
      {:ok, type} = Locations.create_location_type(%{name: "Old"})
      {:ok, _} = Locations.update_location_type(type, %{name: "New"}, actor_uuid: @actor)

      assert_activity_logged("location_type.updated",
        resource_uuid: type.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "New"}
      )
    end

    test "delete_location_type logs location_type.deleted" do
      {:ok, type} = Locations.create_location_type(%{name: "DeleteMe"})
      {:ok, _} = Locations.delete_location_type(type, actor_uuid: @actor)

      assert_activity_logged("location_type.deleted",
        resource_uuid: type.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "DeleteMe"}
      )
    end

    test "failed create does not log" do
      {:error, _cs} = Locations.create_location_type(%{}, actor_uuid: @actor)
      refute_activity_logged("location_type.created", actor_uuid: @actor)
    end
  end

  describe "location mutations" do
    test "create_location logs location.created" do
      {:ok, location} =
        Locations.create_location(
          %{name: "HQ", city: "Springfield", status: "active"},
          actor_uuid: @actor
        )

      row =
        assert_activity_logged("location.created",
          resource_uuid: location.uuid,
          actor_uuid: @actor,
          metadata_has: %{"name" => "HQ", "city" => "Springfield", "status" => "active"}
        )

      assert row.resource_type == "location"
      assert row.module == "locations"
    end

    test "update_location logs location.updated" do
      {:ok, location} = Locations.create_location(%{name: "Old"})

      {:ok, _} =
        Locations.update_location(location, %{name: "New", city: "Boston"}, actor_uuid: @actor)

      assert_activity_logged("location.updated",
        resource_uuid: location.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "New", "city" => "Boston"}
      )
    end

    test "delete_location logs location.deleted" do
      {:ok, location} = Locations.create_location(%{name: "DeleteMe", city: "X"})
      {:ok, _} = Locations.delete_location(location, actor_uuid: @actor)

      assert_activity_logged("location.deleted",
        resource_uuid: location.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "DeleteMe"}
      )
    end

    test "failed create does not log" do
      {:error, _cs} = Locations.create_location(%{}, actor_uuid: @actor)
      refute_activity_logged("location.created", actor_uuid: @actor)
    end

    test "metadata is PII-audited (no email, phone, notes)" do
      {:ok, location} =
        Locations.create_location(
          %{
            name: "PII Test",
            email: "secret@example.com",
            phone: "+1 555 0100",
            notes: "admin-only sensitive notes"
          },
          actor_uuid: @actor
        )

      row =
        assert_activity_logged("location.created",
          resource_uuid: location.uuid,
          actor_uuid: @actor
        )

      metadata = row.metadata
      refute Map.has_key?(metadata, "email")
      refute Map.has_key?(metadata, "phone")
      refute Map.has_key?(metadata, "notes")
    end
  end

  describe "type assignment mutations" do
    test "sync_location_types logs location.types_synced with diff metadata" do
      {:ok, location} = Locations.create_location(%{name: "L"})
      {:ok, t1} = Locations.create_location_type(%{name: "A"})
      {:ok, t2} = Locations.create_location_type(%{name: "B"})

      {:ok, :synced} =
        Locations.sync_location_types(location.uuid, [t1.uuid, t2.uuid], actor_uuid: @actor)

      row =
        assert_activity_logged("location.types_synced",
          resource_uuid: location.uuid,
          actor_uuid: @actor
        )

      assert row.metadata["types_from"] == []
      assert Enum.sort(row.metadata["types_to"]) == Enum.sort([t1.uuid, t2.uuid])
    end

    test "sync_location_types does NOT log when set is unchanged" do
      {:ok, location} = Locations.create_location(%{name: "L"})
      {:ok, t} = Locations.create_location_type(%{name: "A"})

      {:ok, :synced} = Locations.sync_location_types(location.uuid, [t.uuid], actor_uuid: @actor)

      {:ok, :unchanged} =
        Locations.sync_location_types(location.uuid, [t.uuid], actor_uuid: @actor)

      # Exactly one synced entry, not two
      all = list_activities()
      synced = Enum.filter(all, &(&1.action == "location.types_synced"))
      assert length(synced) == 1
    end

    test "add_location_type logs location.type_added" do
      {:ok, location} = Locations.create_location(%{name: "L"})
      {:ok, type} = Locations.create_location_type(%{name: "T"})

      {:ok, _} = Locations.add_location_type(location.uuid, type.uuid, actor_uuid: @actor)

      assert_activity_logged("location.type_added",
        resource_uuid: location.uuid,
        actor_uuid: @actor,
        metadata_has: %{"type_uuid" => type.uuid}
      )
    end

    test "add_location_type is idempotent — does not log a second time" do
      {:ok, location} = Locations.create_location(%{name: "L"})
      {:ok, type} = Locations.create_location_type(%{name: "T"})

      {:ok, _} = Locations.add_location_type(location.uuid, type.uuid, actor_uuid: @actor)
      {:ok, _} = Locations.add_location_type(location.uuid, type.uuid, actor_uuid: @actor)

      added =
        list_activities()
        |> Enum.filter(&(&1.action == "location.type_added"))

      assert length(added) == 1
    end

    test "remove_location_type logs location.type_removed (only when a row was actually deleted)" do
      {:ok, location} = Locations.create_location(%{name: "L"})
      {:ok, type} = Locations.create_location_type(%{name: "T"})

      {:ok, _} = Locations.add_location_type(location.uuid, type.uuid, actor_uuid: @actor)

      {:ok, 1} = Locations.remove_location_type(location.uuid, type.uuid, actor_uuid: @actor)

      assert_activity_logged("location.type_removed",
        resource_uuid: location.uuid,
        actor_uuid: @actor,
        metadata_has: %{"type_uuid" => type.uuid}
      )

      # Re-running remove on absent row is a no-op and does not log again
      {:ok, 0} = Locations.remove_location_type(location.uuid, type.uuid, actor_uuid: @actor)

      removed =
        list_activities()
        |> Enum.filter(&(&1.action == "location.type_removed"))

      assert length(removed) == 1
    end
  end

  describe "module toggle" do
    test "log_module_toggle(:enabled) writes locations_module.enabled" do
      Locations.log_module_toggle(:enabled, actor_uuid: @actor)

      row =
        assert_activity_logged("locations_module.enabled",
          actor_uuid: @actor,
          metadata_has: %{"module_key" => "locations"}
        )

      assert row.resource_type == "module"
      assert row.resource_uuid == nil
    end

    test "log_module_toggle(:disabled) writes locations_module.disabled" do
      Locations.log_module_toggle(:disabled, actor_uuid: @actor)

      assert_activity_logged("locations_module.disabled",
        actor_uuid: @actor,
        metadata_has: %{"module_key" => "locations"}
      )
    end
  end

  describe "no spurious logging" do
    test "query functions (list, get, count) do not log activity" do
      {:ok, _} = Locations.create_location(%{name: "L"}, actor_uuid: @actor)

      Locations.list_locations()
      Locations.get_location(Ecto.UUID.generate())
      Locations.count_locations()
      Locations.list_location_types()
      Locations.count_location_types()
      Locations.get_location_by(:name, "L")
      Locations.has_type?(Ecto.UUID.generate(), Ecto.UUID.generate())
      Locations.find_similar_addresses("x", "y", "z")

      # Only the create fired an event
      entries = list_activities()
      assert length(entries) == 1
      assert hd(entries).action == "location.created"
    end
  end
end

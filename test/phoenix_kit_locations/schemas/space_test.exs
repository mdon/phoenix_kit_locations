defmodule PhoenixKitLocations.Schemas.SpaceTest do
  @moduledoc """
  Schema-level tests for the V122 Space schema. Pins the changeset
  contract: required fields, kind/status whitelists, length caps,
  self-parent guard, kinds/statuses helpers.

  The "child belongs to same Location as parent" cross-row invariant
  is context-layer (`Spaces.validate_parent_location/1`) and tested
  separately under `test/spaces_test.exs` (integration, when DB is
  available).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Schemas.Space

  describe "changeset/2 — required fields" do
    test "accepts a minimal valid floor changeset" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "Floor 1"
        })

      assert cs.valid?
    end

    test "rejects missing location_uuid" do
      cs = Space.changeset(%Space{}, %{"kind" => "floor", "name" => "Floor 1"})

      refute cs.valid?
      assert {"can't be blank", [validation: :required]} = cs.errors[:location_uuid]
    end

    test "rejects missing kind" do
      cs = Space.changeset(%Space{}, %{"location_uuid" => Ecto.UUID.generate(), "name" => "X"})

      refute cs.valid?
      assert {"can't be blank", [validation: :required]} = cs.errors[:kind]
    end

    test "rejects missing name" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor"
        })

      refute cs.valid?
      assert {"can't be blank", [validation: :required]} = cs.errors[:name]
    end
  end

  describe "changeset/2 — kind whitelist" do
    test "accepts floor" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1"
        })

      assert cs.valid?
    end

    test "accepts room" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "room",
          "name" => "R1"
        })

      assert cs.valid?
    end

    test "accepts zone" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "zone",
          "name" => "Z1"
        })

      assert cs.valid?
    end

    test "accepts section" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "section",
          "name" => "S1"
        })

      assert cs.valid?
    end

    test "accepts aisle" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "aisle",
          "name" => "A1"
        })

      assert cs.valid?
    end

    test "accepts shelf" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "shelf",
          "name" => "SH1"
        })

      assert cs.valid?
    end

    test "rejects kinds outside the app-layer @kinds (even if the DB CHECK would allow them)" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "hall",
          "name" => "H1"
        })

      refute cs.valid?

      assert {"is invalid",
              [validation: :inclusion, enum: ~w(floor room zone section aisle shelf)]} =
               cs.errors[:kind]
    end

    test "rejects garbage kinds" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "garbage",
          "name" => "X"
        })

      refute cs.valid?
      assert cs.errors[:kind]
    end
  end

  describe "changeset/2 — status whitelist" do
    test "accepts active (default)" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1",
          "status" => "active"
        })

      assert cs.valid?
    end

    test "accepts inactive" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1",
          "status" => "inactive"
        })

      assert cs.valid?
    end

    test "rejects unknown status" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1",
          "status" => "archived"
        })

      refute cs.valid?
      assert cs.errors[:status]
    end
  end

  describe "changeset/2 — length caps" do
    test "rejects name over 255 chars" do
      long_name = String.duplicate("a", 256)

      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => long_name
        })

      refute cs.valid?
      assert cs.errors[:name]
    end

    test "rejects empty name (min: 1)" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => ""
        })

      refute cs.valid?
      # Either "can't be blank" (required) or length error — both pin the
      # same intent: blank names are rejected.
      assert cs.errors[:name]
    end

    test "rejects description over 2000 chars" do
      long_desc = String.duplicate("a", 2001)

      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1",
          "description" => long_desc
        })

      refute cs.valid?
      assert cs.errors[:description]
    end

    test "rejects notes over 5000 chars" do
      long_notes = String.duplicate("a", 5001)

      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "floor",
          "name" => "F1",
          "notes" => long_notes
        })

      refute cs.valid?
      assert cs.errors[:notes]
    end
  end

  describe "changeset/2 — self-parent guard" do
    test "rejects setting parent_uuid to the space's own uuid" do
      uuid = Ecto.UUID.generate()

      cs =
        Space.changeset(%Space{uuid: uuid}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "room",
          "name" => "R1",
          "parent_uuid" => uuid
        })

      refute cs.valid?
      assert {"cannot be its own parent", _} = cs.errors[:parent_uuid]
    end

    test "allows parent_uuid different from self" do
      cs =
        Space.changeset(%Space{uuid: Ecto.UUID.generate()}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "room",
          "name" => "R1",
          "parent_uuid" => Ecto.UUID.generate()
        })

      assert cs.valid?
    end

    test "allows new spaces (uuid not yet assigned) with any parent_uuid" do
      cs =
        Space.changeset(%Space{}, %{
          "location_uuid" => Ecto.UUID.generate(),
          "kind" => "room",
          "name" => "R1",
          "parent_uuid" => Ecto.UUID.generate()
        })

      assert cs.valid?
    end
  end

  describe "kinds/0 + statuses/0" do
    test "kinds/0 returns the app-layer whitelist" do
      assert Space.kinds() == ~w(floor room zone section aisle shelf)
    end

    test "statuses/0 returns active + inactive" do
      assert Space.statuses() == ~w(active inactive)
    end
  end

  describe "kind_label/1 and kind_icon/1" do
    test "kind_label/1 returns a human-readable label for each known kind" do
      assert Space.kind_label("floor") == "Floor"
      assert Space.kind_label("room") == "Room"
      assert Space.kind_label("zone") == "Zone"
      assert Space.kind_label("section") == "Section"
      assert Space.kind_label("aisle") == "Aisle"
      assert Space.kind_label("shelf") == "Shelf"
    end

    test "kind_label/1 falls back to the raw kind string for unknown kinds" do
      assert Space.kind_label("hall") == "hall"
      assert Space.kind_label("garbage") == "garbage"
    end

    test "kind_icon/1 returns a heroicon name for each known kind" do
      assert Space.kind_icon("floor") == "hero-building-office-2"
      assert Space.kind_icon("room") == "hero-squares-2x2"
      assert Space.kind_icon("zone") == "hero-map"
      assert Space.kind_icon("section") == "hero-view-columns"
      assert Space.kind_icon("aisle") == "hero-arrows-right-left"
      assert Space.kind_icon("shelf") == "hero-archive-box"
    end

    test "kind_icon/1 falls back to a generic cube icon for unknown kinds" do
      assert Space.kind_icon("hall") == "hero-cube"
      assert Space.kind_icon("garbage") == "hero-cube"
    end
  end
end

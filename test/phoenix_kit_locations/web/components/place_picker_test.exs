defmodule PhoenixKitLocations.Web.Components.PlacePickerTest do
  @moduledoc """
  Drives `PlacePicker` LiveComponent events through
  `PlacePickerHarnessLive` (a minimal host — `PlacePicker` has no real
  production consumer yet, see the harness's moduledoc), mirroring how
  `ItemPickerEventsTest` drives `ItemPicker` through a real host LV in
  the catalogue module.

  Every interactive element in `PlacePicker`'s template carries
  `phx-target={@myself}` (it's a LiveComponent), so every event below
  goes through `element(view, selector) |> render_*()` rather than
  `render_*(view, event, value)` directly — the latter would dispatch
  to the harness LiveView itself and miss the component entirely.
  """

  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Spaces

  defp harness_path(opts \\ []) do
    case Keyword.get(opts, :location_type_uuid) do
      nil -> "/en/admin/locations/__test__/place-picker"
      uuid -> "/en/admin/locations/__test__/place-picker?location_type_uuid=#{uuid}"
    end
  end

  defp search_input, do: "#harness-picker-input"

  defp search(view, query),
    do: view |> element(search_input()) |> render_change(%{"value" => query})

  defp select_location_option(view, location) do
    view
    |> element(~s([phx-click="select_location"][phx-value-uuid="#{location.uuid}"]))
    |> render_click()
  end

  defp fixture_space(location_uuid, attrs) do
    base = %{"location_uuid" => location_uuid, "kind" => "floor", "name" => "Space"}
    {:ok, space} = Spaces.create_space(Map.merge(base, attrs))
    space
  end

  describe "mount" do
    test "renders the location search combobox", %{conn: conn} do
      {:ok, _view, html} = live(conn, harness_path())

      assert html =~ ~s(role="combobox")
      assert html =~ "Search locations"
      refute html =~ "selected-place"
    end
  end

  describe "search + select a location" do
    test "typing a substring narrows matches to locations whose name contains it",
         %{conn: conn} do
      match = fixture_location(%{name: "Central Warehouse"})
      _decoy = fixture_location(%{name: "Downtown Office"})

      {:ok, view, _html} = live(conn, harness_path())

      rendered = search(view, "Warehouse")

      assert rendered =~ match.name
      refute rendered =~ "Downtown Office"
    end

    test "selecting a match swaps the combobox for its Space tree", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      rendered = select_location_option(view, location)

      assert rendered =~ location.name
      refute has_element?(view, search_input())
      # No selection message yet — picking the *Location* alone isn't
      # a place selection; that requires a Space or "Use this location".
      refute has_element?(view, "#selected-place")
    end
  end

  describe "location_type_uuid filter" do
    test "excludes locations that don't have the given type assigned", %{conn: conn} do
      type = fixture_location_type()
      matching = fixture_location(%{name: "Match Loc"})
      {:ok, _} = Locations.add_location_type(matching.uuid, type.uuid)
      _other = fixture_location(%{name: "Other Loc"})

      {:ok, view, _html} = live(conn, harness_path(location_type_uuid: type.uuid))

      rendered = search(view, "Loc")

      assert rendered =~ "Match Loc"
      refute rendered =~ "Other Loc"
    end

    test "with no location_type_uuid, every active location matches", %{conn: conn} do
      type = fixture_location_type()
      a = fixture_location(%{name: "Loc A"})
      {:ok, _} = Locations.add_location_type(a.uuid, type.uuid)
      b = fixture_location(%{name: "Loc B"})

      {:ok, view, _html} = live(conn, harness_path())

      rendered = search(view, "Loc")

      assert rendered =~ a.name
      assert rendered =~ b.name
    end
  end

  describe "selecting a Space in the tree sends {:place_picker_select, ...} to the host" do
    test "a root-level node sends its location_uuid + space_uuid", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{floor.uuid}"]))
      |> render_click()

      assert has_element?(view, "#selected-place")
      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ floor.uuid
    end

    test "a nested child is unreachable until its ancestor is expanded via toggle_space_node",
         %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      zone_select_selector = ~s([phx-click="select_space"][phx-value-uuid="#{zone.uuid}"])
      refute has_element?(view, zone_select_selector)

      view
      |> element(~s([phx-click="toggle_space_node"][phx-value-uuid="#{floor.uuid}"]))
      |> render_click()

      assert has_element?(view, zone_select_selector)
      view |> element(zone_select_selector) |> render_click()

      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ zone.uuid
    end

    test "re-selecting a different Space updates the message instead of accumulating",
         %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      a = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor A"})
      b = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor B"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{a.uuid}"]))
      |> render_click()

      assert view |> element("#selected-space-uuid") |> render() =~ a.uuid

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{b.uuid}"]))
      |> render_click()

      assert view |> element("#selected-space-uuid") |> render() =~ b.uuid
    end
  end

  describe "\"Use this location\" (no specific space)" do
    test "sends space_uuid: nil", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_location_only"]))
      |> render_click()

      assert has_element?(view, "#selected-place")
      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ "none"
    end
  end
end

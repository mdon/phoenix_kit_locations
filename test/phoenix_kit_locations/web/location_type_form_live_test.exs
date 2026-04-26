defmodule PhoenixKitLocations.Web.LocationTypeFormLiveTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations

  describe "new form" do
    test "renders the New Location Type heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/new")
      assert html =~ "New Location Type"
    end

    test "submitting the form creates a type and redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form", location_type: %{"name" => "Warehouse"})
        |> render_submit()

      assert to == "/en/admin/locations/types"
      assert Locations.get_location_type_by_name("Warehouse")
    end

    test "submit with blank name shows validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      rendered =
        view
        |> form("form", location_type: %{"name" => ""})
        |> render_submit()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
    end
  end

  describe "edit form" do
    test "renders existing type values", %{conn: conn} do
      type = fixture_location_type(%{name: "Original"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")

      assert html =~ "Edit Original"
    end

    test "updating name persists the change", %{conn: conn} do
      type = fixture_location_type(%{name: "Original"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form", location_type: %{"name" => "Renamed"})
        |> render_submit()

      assert to == "/en/admin/locations/types"
      assert %{name: "Renamed"} = Locations.get_location_type(type.uuid)
    end

    test "edit with nonexistent UUID redirects with flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        live(conn, "/en/admin/locations/types/#{Ecto.UUID.generate()}/edit")

      assert to == "/en/admin/locations/types"
      assert flash["error"] =~ "Location type not found"
    end
  end

  describe "inline validation errors" do
    test "validate with blank name shows error before save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      rendered =
        view
        |> form("form", location_type: %{"name" => ""})
        |> render_change()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
    end
  end

  describe "status select binding" do
    test "save with status=inactive persists", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      {:error, {:live_redirect, _}} =
        view
        |> form("form", location_type: %{"name" => "InactiveType", "status" => "inactive"})
        |> render_submit()

      assert %{status: "inactive"} = Locations.get_location_type_by_name("InactiveType")
    end
  end

  describe "phx-disable-with" do
    test "new-form submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/new")
      assert html =~ ~s(phx-disable-with="Creating...")
    end

    test "edit-form submit button has phx-disable-with", %{conn: conn} do
      type = fixture_location_type(%{name: "X"})
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")
      assert html =~ ~s(phx-disable-with="Saving...")
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}})

      assert is_binary(render(view))
    end
  end
end

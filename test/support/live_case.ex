defmodule PhoenixKitLocations.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitLocations.Web.LocationFormLiveTest do
        use PhoenixKitLocations.LiveCase

        test "renders", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/locations/new")
          assert html =~ "New Location"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitLocations.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitLocations.ActivityLogAssertions
      import PhoenixKitLocations.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc "Creates a LocationType fixture with a unique name."
  def fixture_location_type(attrs \\ %{}) do
    {:ok, type} =
      PhoenixKitLocations.Locations.create_location_type(
        Map.merge(%{name: "Type #{System.unique_integer([:positive])}"}, attrs)
      )

    type
  end

  @doc "Creates a Location fixture with a unique name."
  def fixture_location(attrs \\ %{}) do
    {:ok, location} =
      PhoenixKitLocations.Locations.create_location(
        Map.merge(%{name: "Location #{System.unique_integer([:positive])}"}, attrs)
      )

    location
  end
end

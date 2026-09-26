defmodule PhoenixKitLocations.SpacesTreeLockTest do
  @moduledoc """
  A re-parent holds its location's tree lock through the cycle check, so
  two in opposite directions at once cannot both pass and commit a loop.
  The sandbox runs every test on one connection and cannot race, so this
  holds the lock from a second, real connection and watches a re-parent
  wait. That pins "the lock is taken on a re-parent, a move to the top
  level included, and not on a rename"; the two-writer race itself was
  proved on a live node, not here.
  """
  use PhoenixKitLocations.DataCase, async: false

  alias PhoenixKitLocations.{Locations, Spaces}
  alias PhoenixKitLocations.Test.Repo

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp space!(location, name) do
    {:ok, space} =
      Spaces.create_space(%{"location_uuid" => location.uuid, "kind" => "room", "name" => name})

    space
  end

  test "a re-parent waits for the location's tree lock; a rename does not" do
    {:ok, location} = Locations.create_location(%{name: "Locked"})
    [a, b] = [space!(location, "A"), space!(location, "B")]
    key = "phoenix_kit_locations:spaces:#{location.uuid}"
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

    assert {:ok, a} = Spaces.update_space(a, %{"name" => "A2"})

    move = Task.async(fn -> Spaces.update_space(a, %{"parent_uuid" => b.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [key])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end

  # The child is created under its parent: a re-parent here would hold the
  # transaction-level lock for the rest of this sandboxed test.
  test "a move to the top level waits for the lock too" do
    {:ok, location} = Locations.create_location(%{name: "Locked up"})
    b = space!(location, "B")

    {:ok, a} =
      Spaces.create_space(%{
        "location_uuid" => location.uuid,
        "kind" => "room",
        "name" => "A",
        "parent_uuid" => b.uuid
      })

    key = "phoenix_kit_locations:spaces:#{location.uuid}"
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

    up = Task.async(fn -> Spaces.update_space(a, %{"parent_uuid" => ""}) end)
    assert Task.yield(up, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [key])
    assert {:ok, moved} = Task.await(up)
    assert moved.parent_uuid == nil
  end
end

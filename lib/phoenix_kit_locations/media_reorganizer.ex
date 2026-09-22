defmodule PhoenixKitLocations.MediaReorganizer do
  @moduledoc """
  Locations' media-reorganizer plan source: the `location-<uuid>` and
  `location-space-<uuid>` folders, planned by core's
  `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`, which applies the
  `Reorganizer.Source` contract.

  What is locations' own: every location and space row is live — only a
  deleted one leaves an orphan; each stores its folder pointer in
  `data["files_folder_uuid"]`, so moves back-fill it and a taken target is
  renamed `"name (N)"`; the parent and name hooks receive the record
  itself; a space's folder comes after its parent space's; and uploads for
  an unsaved record wait in `location-attachment-pending-*` folders.
  """

  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource
  alias PhoenixKitLocations.Schemas.{Location, Space}

  @pointer {:data, "files_folder_uuid"}

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` takes `:pending_days`."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: "locations",
      app: :phoenix_kit_locations,
      pending_prefix: "location-attachment-pending-",
      kinds: [
        %{kind: :location, schema: Location, prefix: "location-", pointer: @pointer},
        %{
          kind: :space,
          schema: Space,
          prefix: "location-space-",
          pointer: @pointer,
          fields: [:location_uuid, :parent_uuid, :kind],
          order: &parents_first/1
        }
      ]
    }
  end

  # A space right after the spaces above it, so a nested space's folder
  # moves after its parent's; otherwise in the order given.
  defp parents_first(spaces) do
    by_uuid = Map.new(spaces, &{&1.uuid, &1})

    {ordered, _seen} =
      Enum.reduce(spaces, {[], MapSet.new()}, fn space, acc -> emit(space, by_uuid, acc) end)

    Enum.reverse(ordered)
  end

  defp emit(space, by_uuid, {acc, seen}) do
    if MapSet.member?(seen, space.uuid) do
      {acc, seen}
    else
      seen = MapSet.put(seen, space.uuid)

      {acc, seen} =
        case space.parent_uuid && Map.get(by_uuid, space.parent_uuid) do
          nil -> {acc, seen}
          parent -> emit(parent, by_uuid, {acc, seen})
        end

      {[space | acc], seen}
    end
  end
end

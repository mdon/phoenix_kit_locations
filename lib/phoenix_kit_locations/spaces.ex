defmodule PhoenixKitLocations.Spaces do
  @moduledoc """
  Context for nested spaces under a Location — rooms, floors, zones,
  etc. forming a per-location tree.

  ## Same-Location parent invariant

  A space's `parent_uuid` (when set) must reference another space in
  the **same** Location. The DB doesn't enforce this directly — a
  composite FK on `(parent_uuid, location_uuid)` would, but it's
  heavier than the consumer surface justifies. We guard at the
  context boundary instead: `create_space/2` and `update_space/3`
  reject any cross-location parent with `{:error, :parent_in_other_location}`.

  ## Cycle prevention

  Direct self-loop is caught by the schema changeset. Indirect cycles
  (A → B → A) are blocked here in `validate_no_cycle/3` before any
  `parent_uuid` change is persisted. Walk-up depth-limited to 64 hops —
  generous for any realistic building hierarchy.

  ## Activity logging

  Mutating functions accept `opts \\ []` and forward `:actor_uuid`
  for the activity log. Same wrapper shape as `Locations` —
  guarded with `Code.ensure_loaded?(PhoenixKit.Activity)` and rescued
  so logging never crashes the mutation.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Schemas.Space

  @type opts :: keyword()
  @type uuid :: String.t()

  @max_cycle_walk 64

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Reads
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  All spaces for a Location, ordered by (parent_uuid, position).
  Returns a flat list; use `list_tree/1` for a nested shape.
  """
  @spec list_for_location(uuid) :: [Space.t()]
  def list_for_location(location_uuid) when is_binary(location_uuid) do
    from(s in Space,
      where: s.location_uuid == ^location_uuid,
      order_by: [asc_nulls_first: s.parent_uuid, asc: s.position, asc: s.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Nested tree of spaces for a Location. Each node carries a `:children`
  key as a list (empty for leaves). Root-level nodes have `parent_uuid == nil`.

  Single DB read — the tree is assembled in memory from the flat list.
  """
  @spec list_tree(uuid) :: [map()]
  def list_tree(location_uuid) when is_binary(location_uuid) do
    spaces = list_for_location(location_uuid)
    by_parent = Enum.group_by(spaces, & &1.parent_uuid)
    build_tree(by_parent, nil)
  end

  defp build_tree(by_parent, parent_uuid) do
    by_parent
    |> Map.get(parent_uuid, [])
    |> Enum.map(fn space ->
      Map.put(space, :children, build_tree(by_parent, space.uuid))
    end)
  end

  @doc "Fetches a space by UUID. Returns `nil` if not found."
  @spec get_space(uuid) :: Space.t() | nil
  def get_space(uuid), do: repo().get(Space, uuid)

  @doc "Builds an empty changeset (for `:new` forms)."
  @spec change_space(Space.t(), map()) :: Ecto.Changeset.t()
  def change_space(%Space{} = space, attrs \\ %{}),
    do: Space.changeset(space, attrs)

  @doc """
  Full breadcrumb path for a Space, root Location through the Space
  itself: `"Location / Floor / Zone / Shelf"`. `nil` when the space
  (or its Location) can't be found.

  `opts[:locale]` — when given, each segment's name resolves through
  `PhoenixKit.Utils.Multilang.get_language_data/2` for that language
  (falling back to the primary-language column when no translation
  override exists). Omitted (or `nil`) uses the primary-language
  column directly for every segment — no `data` JSONB read at all.
  """
  @spec full_path(uuid, opts) :: String.t() | nil
  def full_path(space_uuid, opts \\ []) when is_binary(space_uuid) do
    locale = Keyword.get(opts, :locale)

    with %Space{} = space <- get_space(space_uuid),
         %Location{} = location <- repo().get(Location, space.location_uuid) do
      ancestors = ancestors_in_order(space)

      Enum.map_join([location] ++ ancestors ++ [space], " / ", &translated_name(&1, locale))
    else
      nil -> nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Writes
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Creates a new space. Rejects parents that live in a different
  Location with `{:error, :parent_in_other_location}`.
  """
  @spec create_space(map(), opts) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :parent_in_other_location
             | :parent_not_found
             | :location_not_found}
  def create_space(attrs, opts \\ []) do
    with :ok <- validate_parent_location(attrs) do
      %Space{}
      |> Space.changeset(attrs)
      |> repo().insert()
      |> log_activity("space.created", "location_space", opts, &space_metadata/1)
    end
  end

  @doc """
  Updates an existing space. Re-parenting is allowed but rejected if
  the new parent lives in another Location, or if the change would
  create a cycle.
  """
  @spec update_space(Space.t(), map(), opts) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :parent_in_other_location
             | :parent_not_found
             | :location_not_found
             | :cycle}
  def update_space(%Space{} = space, attrs, opts \\ []) do
    attrs = Map.put_new(attrs, "location_uuid", space.location_uuid)

    with :ok <- validate_parent_location(attrs),
         :ok <-
           validate_no_cycle(space.uuid, fetch_attr(attrs, :parent_uuid), space.location_uuid) do
      space
      |> Space.changeset(attrs)
      |> repo().update()
      |> log_activity("space.updated", "location_space", opts, &space_metadata/1)
    end
  end

  @doc """
  Hard-deletes a space. Children CASCADE via the DB FK — the entire
  subtree is removed. The activity log records the delete of the
  named root; children deletes aren't individually logged (would be
  noisy on deep trees).
  """
  @spec delete_space(Space.t(), opts) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def delete_space(%Space{} = space, opts \\ []) do
    space
    |> repo().delete()
    |> log_activity("space.deleted", "location_space", opts, &space_metadata/1)
  end

  @doc """
  Reorders a sibling group under a single (location, parent) — accepts
  the full ordered list of sibling UUIDs and rewrites their `position`
  to match. Runs in a transaction; returns `{:ok, :reordered}` or
  `{:error, reason}`.
  """
  @spec reorder_siblings(uuid, uuid | nil, [uuid], opts) ::
          {:ok, :reordered} | {:error, term()}
  def reorder_siblings(location_uuid, parent_uuid, ordered_uuids, opts \\ [])
      when is_binary(location_uuid) and is_list(ordered_uuids) do
    repo().transaction(fn ->
      ordered_uuids
      |> Enum.with_index()
      |> Enum.each(fn {uuid, position} ->
        uuid
        |> sibling_position_query(location_uuid, parent_uuid)
        |> repo().update_all(set: [position: position])
      end)
    end)
    |> case do
      {:ok, _} ->
        maybe_log_activity(
          "space.reordered",
          "location_space",
          parent_uuid,
          opts,
          %{"location_uuid" => location_uuid, "count" => length(ordered_uuids)}
        )

        {:ok, :reordered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Scopes a single space to its (location, parent) sibling group. Root
  # siblings carry `parent_uuid == nil`, which must be matched with
  # `is_nil/1` — a pinned `== ^nil` compiles to SQL `= NULL` and never
  # matches, so floor reordering would silently update zero rows.
  defp sibling_position_query(uuid, location_uuid, nil) do
    from(s in Space,
      where: s.uuid == ^uuid and s.location_uuid == ^location_uuid and is_nil(s.parent_uuid)
    )
  end

  defp sibling_position_query(uuid, location_uuid, parent_uuid) do
    from(s in Space,
      where:
        s.uuid == ^uuid and s.location_uuid == ^location_uuid and
          s.parent_uuid == ^parent_uuid
    )
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — validations
  # ═══════════════════════════════════════════════════════════════════

  defp validate_parent_location(attrs) do
    check_parent_under_location(
      fetch_attr(attrs, :location_uuid),
      fetch_attr(attrs, :parent_uuid)
    )
  end

  # `attrs` may arrive string-keyed (form params) or atom-keyed (internal
  # callers); read either so parent/cycle checks never silently skip on a
  # key-shape mismatch.
  defp fetch_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)
  end

  defp check_parent_under_location(_location_uuid, nil), do: :ok
  defp check_parent_under_location(_location_uuid, ""), do: :ok
  defp check_parent_under_location(nil, _parent_uuid), do: {:error, :location_not_found}

  defp check_parent_under_location(location_uuid, parent_uuid) do
    case get_space(parent_uuid) do
      nil -> {:error, :parent_not_found}
      %Space{location_uuid: ^location_uuid} -> :ok
      %Space{} -> {:error, :parent_in_other_location}
    end
  end

  # Walk up the parent chain from `new_parent_uuid` — if we ever hit
  # `space_uuid`, the change would create a cycle. Bounded walk so a
  # corrupted chain can't spin forever.
  defp validate_no_cycle(_space_uuid, nil, _location_uuid), do: :ok
  defp validate_no_cycle(_space_uuid, "", _location_uuid), do: :ok

  defp validate_no_cycle(space_uuid, new_parent_uuid, _location_uuid)
       when space_uuid == new_parent_uuid,
       do: {:error, :cycle}

  defp validate_no_cycle(space_uuid, new_parent_uuid, location_uuid) do
    walk_ancestors(space_uuid, new_parent_uuid, location_uuid, @max_cycle_walk)
  end

  defp walk_ancestors(_target, _cursor, _location, 0), do: {:error, :cycle}

  defp walk_ancestors(target, cursor, location, hops_remaining) do
    case repo().one(
           from(s in Space,
             where: s.uuid == ^cursor and s.location_uuid == ^location,
             select: s.parent_uuid
           )
         ) do
      nil -> :ok
      ^target -> {:error, :cycle}
      next -> walk_ancestors(target, next, location, hops_remaining - 1)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — path resolution (full_path/2)
  # ═══════════════════════════════════════════════════════════════════

  # Ancestors of `space`, ordered root → direct parent. `[]` when
  # `space` is already a root (`parent_uuid == nil`) — skips the CTE
  # entirely in the common case. Mirrors
  # `PhoenixKitCatalogue.Catalogue.Tree.ancestor_uuids/1` +
  # `ancestors_in_order/1` + `walk_up/3`: one recursive CTE walking
  # `parent_uuid` up from `space`, `UNION` (not `UNION ALL`) so a
  # corrupted/cyclic chain can't spin forever — Postgres drops rows
  # already seen in the working table before the next iteration.
  defp ancestors_in_order(%Space{parent_uuid: nil}), do: []

  defp ancestors_in_order(%Space{} = space) do
    case ancestor_uuids(space.uuid) do
      [] ->
        []

      raw_uuids ->
        # The CTE's outer select in `ancestor_uuids/1` is schema-less
        # (`select: t.uuid` off a `with_cte` fragment) — Ecto has no
        # field type to `load/1` each row through, so it comes back as
        # the raw 16-byte binary Postgrex decoded off the wire, not
        # the textual form every loaded `%Space{}.uuid` carries.
        # Re-querying `Space` with these raw values directly in
        # `where: s.uuid in ^raw_uuids` would fail:
        # `Ecto.Type.dump(UUIDv7, <<16 raw bytes>>)` returns `:error`
        # (`UUIDv7.dump/1` delegates to `Ecto.UUID.dump/1`, which only
        # accepts the 36-char textual form). Normalise to text first —
        # same fix `PhoenixKitCatalogue.Catalogue` applies at every
        # other call site that reuses a Tree CTE's raw-uuid output
        # (its `load_uuid/1`).
        uuids = Enum.map(raw_uuids, &load_uuid/1)

        by_uuid =
          from(s in Space, where: s.uuid in ^uuids)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        walk_up(space.parent_uuid, by_uuid, [])
    end
  end

  # Recursive CTE returning every ancestor uuid of `uuid` (raw 16-byte
  # binaries — see `ancestors_in_order/1`), walking up the self-ref
  # `parent_uuid` chain. Excludes `uuid` itself.
  defp ancestor_uuids(uuid) do
    initial =
      from(s in Space,
        where: s.uuid == type(^uuid, UUIDv7),
        select: %{uuid: s.uuid, parent_uuid: s.parent_uuid}
      )

    recursion =
      from(s in Space,
        join: t in "space_ancestor_tree",
        on: s.uuid == t.parent_uuid,
        select: %{uuid: s.uuid, parent_uuid: s.parent_uuid}
      )

    cte = union(initial, ^recursion)

    from(t in "space_ancestor_tree",
      where: t.uuid != type(^uuid, UUIDv7),
      select: t.uuid
    )
    |> recursive_ctes(true)
    |> with_cte("space_ancestor_tree", as: ^cte)
    |> repo().all()
  end

  # Walks `by_uuid` from `uuid` up to the root, prepending each node as
  # it climbs — comes out root-first with no separate reverse (the
  # direct parent is added first so it ends up at the tail; the root
  # is added last so it ends up at the head).
  defp walk_up(uuid, by_uuid, acc) do
    case Map.get(by_uuid, uuid) do
      %Space{parent_uuid: nil} = s -> [s | acc]
      %Space{parent_uuid: parent_uuid} = s -> walk_up(parent_uuid, by_uuid, [s | acc])
      nil -> acc
    end
  end

  # Loads a raw 16-byte binary UUID (from the ancestor CTE) back into
  # the textual `xxxxxxxx-xxxx-...` form so it can be used in a normal
  # typed `Space` query. Falls back to the raw input on failure —
  # defensive only, `ancestor_uuids/1`'s output is always a valid
  # binary UUID in practice.
  defp load_uuid(raw) do
    case Ecto.UUID.load(raw) do
      {:ok, str} -> str
      :error -> raw
    end
  end

  # Resolves a translated `name` for a Location or Space (any map or
  # struct with a `:name` field and, for the locale-aware clause, a
  # `:data` field). `locale: nil` skips the JSONB read entirely and
  # returns the primary-language column as-is.
  #
  # Checks `data[locale]["_name"]` before `data[locale]["name"]`:
  # `PhoenixKitWeb.Components.MultilangForm.merge_translatable_params/4`
  # — the form write path used by both `LocationFormLive` and this
  # module's own `LocationStructureLive` detail panel — stores
  # translatable fields under an underscore-prefixed key (`"_name"`,
  # mirroring the `"_title"` example in `PhoenixKit.Utils.Multilang`'s
  # own moduledoc). A bare `Map.get(translation, "name")` would never
  # see those overrides and would always silently fall back to the
  # primary-language column regardless of `locale`. The unprefixed
  # `"name"` fallback covers data written through a different path
  # (e.g. bulk/AI translation) that stores field names as-is. Mirrors
  # `PhoenixKitCatalogue.Web.Components.ItemPicker.translated_name/2`
  # exactly.
  defp translated_name(%{name: name}, nil), do: name

  defp translated_name(%{data: data, name: name}, locale) do
    translation = Multilang.get_language_data(data, locale)
    Map.get(translation, "_name") || Map.get(translation, "name") || name
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — activity logging (mirrors Locations context)
  # ═══════════════════════════════════════════════════════════════════

  defp log_activity({:ok, %Space{} = record} = ok, action, resource_type, opts, metadata_fun)
       when is_function(metadata_fun, 1) do
    maybe_log_activity(action, resource_type, record.uuid, opts, metadata_fun.(record))
    ok
  end

  defp log_activity(
         {:error, %Ecto.Changeset{}} = err,
         _action,
         _resource_type,
         _opts,
         _metadata_fun
       ),
       do: err

  defp log_activity({:error, _} = err, _action, _resource_type, _opts, _metadata_fun), do: err

  defp maybe_log_activity(action, resource_type, resource_uuid, opts, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: "locations",
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        metadata: metadata
      })
    end

    :ok
  rescue
    e in Postgrex.Error ->
      if match?(%{postgres: %{code: :undefined_table}}, e) do
        :ok
      else
        Logger.warning("[Spaces] Activity log failed: #{Exception.message(e)}")
        :ok
      end

    e ->
      Logger.warning("[Spaces] Activity log error: #{Exception.message(e)}")
      :ok
  end

  defp space_metadata(%Space{} = s) do
    %{
      "name" => s.name,
      "kind" => s.kind,
      "status" => s.status,
      "location_uuid" => s.location_uuid,
      "parent_uuid" => s.parent_uuid
    }
  end
end

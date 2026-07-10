# Spec research: hierarchical locations rework (2026-07-10)

Companion to `DEVELOPMENT_PLAN.md`. Findings from code research; file:line refs verified on that date.

## 1. Spaces tree UI

- `Spaces` context is fully built: `list_tree/1` (spaces.ex:66-79, one flat query + in-memory nesting), `reorder_siblings/4` (spaces.ex:159-187), CRUD. **No dedicated Spaces LiveView exists.**
- `location_form_live.ex` embeds a two-level floor/room staged-draft UI (drafts in memory, persisted only on the Location's global Save, two-pass floors-then-rooms at :925-1161; kind guard `kind in ["floor","room"]` at :170). This model does NOT generalize to N-deep trees — **replace, not extend**: new dedicated tree UI with immediate-commit CRUD via `Spaces` context.
- **Reusable core component**: `PhoenixKitWeb.Components.FolderExplorer` (deps/phoenix_kit/.../folder_explorer.ex) — generic recursive tree: `folder_explorer/1` (:86-226) and recursive `folder_tree_node/1` (:268+) with MapSet-based expand state, configurable `on_navigate`/`on_toggle` events (:256-262), depth connector lines; MediaBrowser's move-destination picker reuses the same node component with `show_rename: false, enable_drag: false`. Model to adapt/fork for a `space_tree_node/1`.
- Catalogue `Tree` (phoenix_kit_catalogue/.../catalogue/tree.ex) is a recursive-CTE query module (ancestors/descendants), not UI; catalogue's category form uses a flat dash-indented `<select>` — weaker pattern, don't copy.

## 2. Kinds extension

- `Space.@kinds ~w(floor room)` at schemas/space.ex:44; validation `validate_inclusion` + `check_constraint` (message auto-derives from @kinds).
- Core migration V122 CHECK already allows `floor room hall suite section zone aisle shelf corner` (deps/phoenix_kit/.../v122.ex:56) → adding zone/section/aisle/shelf is **app-layer only, no migration**.
- Module has **no local gettext** — uses core backend `PhoenixKitWeb.Gettext` (en/et/ru + 5 more locales exist in core). No Floor/Room msgids exist yet. A `kind_label/1` helper with literal `gettext(...)` calls needs extract+merge in core; audit ALL locales incl. en after merge (fuzzy-match pollution precedent).

## 3. Place-picker component

- Precedent A (search half): `PhoenixKitCatalogue.Web.Components.ItemPicker` — self-contained search-combobox LiveComponent, parent notified via `send(self(), {:item_picker_select, id, item})`, multiple instances per page by `id`.
- Precedent B (tree half): FolderExplorer's `folder_tree_node/1` reconfigured as picker (see §1).
- No picker precedents in warehouse.
- Target: `PlacePicker` LiveComponent = Location combobox (filter by LocationType) + Space tree drill-down; message `{:place_picker_select, id, %{location_uuid:, space_uuid:}}`; N instances per page.

## 4. full_path API

- `paths.ex` is URL/route helpers only — full_path does NOT belong there; put it on `Spaces` (or a new module).
- Precedent: catalogue `Tree.ancestors_in_order/1` — recursive CTE (`UNION` not `UNION ALL`, cycle-safe) + ordered load. `Spaces.walk_ancestors/4` (spaces.ex:251-264, bounded 64 hops) is cycle-check-only (returns uuids) — don't reuse for path building; port the CTE pattern instead.
- Localization: Space.name primary language in column, secondary under `data[locale]["name"]` — same convention as Location; check `MultilangForm` for an existing translated-field read helper before writing one.

## 5. Attachments on Space

- **Already done, zero changes needed**: `Attachments.folder_name_for/1` has a `%Space{}` clause (attachments.ex:417-418), multi-resource scope-keyed design, exercised today by floor/room drafts in location_form_live.ex (mount at :92-93/431/452; save-time inject/rename at :1041-1152).
- New tree UI must re-wire the same mount/inject/`maybe_rename_pending_folder_for` sequence against its immediate-commit save path.

## Decisions locked (see DEVELOPMENT_PLAN.md)

- Location = top-level site typed by LocationType (Warehouse exists; add Workshop, Office as data).
- Inner structure = Spaces tree; kinds: floor, room, zone, section (участок), aisle, shelf. Soft nesting hints only, no hard rules.
- Machines are NOT spaces — manufacturing entity with location_uuid+space_uuid soft refs (manufacturing implementation is ON HOLD awaiting upstream module updates).
- Spaces editing moves to immediate-commit dedicated "Structure" tab; staged floor/room draft flow retires.
- Consumers (warehouse multi-warehouse) need: place-picker component + `full_path` + `list_locations(type: ...)` resolve API.

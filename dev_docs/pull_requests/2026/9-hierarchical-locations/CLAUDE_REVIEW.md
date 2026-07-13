# PR #9 Review — Hierarchical locations: space kinds, Structure tree UI, full_path, PlacePicker

**Reviewer:** Claude | **Date:** 2026-07-13 | **Verdict:** Approve **with one
required fix that we applied ourselves** — a `PlacePicker` selection-seed
regression introduced by the PR's own last commit. No open recommendations
remain.

## Scope of what we reviewed

PR #9 is large (5375 / −1745, 28 files, 30 commits, merge `0e9c5eb`): `kind`
extended from `floor/room` to `floor/room/zone/section/aisle/shelf`, a new
"Structure" tab (`LocationStructureLive`) replacing the old staged
floor/room-draft flow in `LocationFormLive` with an N-deep, immediate-commit
Space tree (`SpaceTree`, modeled on core's `FolderExplorer`), `Spaces.full_path/2`
(locale-aware breadcrumb via a cycle-safe recursive CTE), `Spaces.count_descendants/1`
(same CTE shape, reversed join direction, backing the delete-confirmation
modal), and a new `PlacePicker` LiveComponent (location search + Space-tree
drill-down) for future consumers (`phoenix_kit_manufacturing`).

We read every changed file with full surrounding context (not just hunks):
`spaces.ex`, `schemas/space.ex`, `location_structure_live.ex` (new, 758
lines), `place_picker.ex` (new), `space_tree.ex` (new), `files_card.ex`
(extracted from `location_form_live.ex`, verified byte-for-byte equivalent
to the pre-PR inline version including its `PhoenixKitWeb.Gettext` backend),
`location_tabs.ex` (new), and the full 1742-line deletion in
`location_form_live.ex` (confirmed clean — no dangling references to
`space_drafts`, `merge_running_changes`, `NavTabs`, or any other removed
symbol anywhere in `lib/` or `test/`).

Two things intentionally guided the read, per the PR's own domain:

- **Ecto CTE + schema-prefix gotcha.** `ancestor_uuids/1` and
  `descendant_uuids/1` build their recursive-CTE member queries with
  `from(s in Space, ...)` — since `Space` `use`s `PhoenixKit.SchemaPrefix`
  (added two commits before this PR), `@schema_prefix` is baked into the
  `from` AST at compile time for every query built off that schema,
  including CTE members. This is the *compile-time* `@schema_prefix`
  mechanism, not a *runtime* `prefix:` option — the CTE-doesn't-inherit-prefix
  gotcha specifically concerns the latter. The pattern also mirrors
  `PhoenixKitCatalogue.Catalogue.Tree.ancestor_uuids/1` (an existing,
  already-shipped sibling implementation) almost line for line. No issue.
- **Iron Law (no DB queries in `mount/3`).** `LocationStructureLive.mount/3`
  calls `Locations.get_location/1` and `Spaces.list_tree/1` directly, with
  no `handle_params/3`. This duplicates the query on the HTTP+WebSocket
  double-mount — but it's the *pre-existing* convention this repo's other
  two LiveViews (`LocationFormLive`, `LocationTypeFormLive`) already use, not
  something this PR introduces. Not flagged as a PR-specific finding.

---

## What we fixed ourselves

### `BUG - HIGH` — `PlacePicker`'s "seed-once" fix is defeated by `select_location`, breaking its own test *(fixed)*

The PR's last commit (`ba1f36c`) added seed-once semantics to `PlacePicker.update/2`
specifically so a consumer-supplied `selected_space_uuid` survives the
LiveComponent's own subsequent re-renders (documented at length in the
moduledoc, and covered by two new tests). But `handle_event("select_location", ...)`
— the handler that fires when the user picks a Location from the search
combobox — unconditionally resets `:selected_space_uuid` to `nil`:

```elixir
%Location{} = location ->
  {:noreply,
   socket
   |> assign(:selected_location, location)
   |> assign(:tree, Spaces.list_tree(location.uuid))
   |> assign(:expanded, MapSet.new())
   |> assign(:selected_space_uuid, nil)   # <- clobbers the seed
   |> assign(:open, false)
   |> assign(:query, "")
   |> assign(:matches, [])}
```

Trace through `place_picker_test.exs:246` ("seed selected_space_uuid is
honoured on initial mount"): the harness mounts with `selected_space_uuid:
floor.uuid`; `update/2`'s seed-once guard correctly assigns it into
`socket.assigns.selected_space_uuid`. But the test then drives
`select_location_option(view, location)` — the *only* way to populate
`selected_location`/`tree` so the tree (and therefore the highlight) renders
at all — which immediately resets `selected_space_uuid` to `nil` regardless
of the seed. `space_tree_node/1`'s `is_selected` becomes `nil == <uuid>` (`false`)
for every node, so the `"bg-primary/10"` highlight class never renders and
the test's own assertion (`assert rendered =~ "bg-primary/10"`) fails. The
seed feature the commit set out to build is unreachable in the one case that
matters — selecting the Location the seeded Space actually belongs to —
because the two code paths (`update/2`'s seed-once guard and
`select_location`'s hardcoded reset) were never reconciled.

This matches the PR description's own caveat almost exactly: "Integration
tests are written but were NOT executed in the development environment (no
scratch database available)." We hit the same limitation in this sandbox
(no `psql` binary, no way to install one without root) and could not run
`mix test` to confirm mechanically — this finding is from tracing the event
flow by hand, not a test run. `mix format`, `mix compile --warnings-as-errors`,
`mix credo --strict`, and `mix dialyzer` all pass clean both before and after
the fix (see Gate below); none of them would have caught this, since it's a
runtime state-flow bug, not a type or static-analysis violation.

**Fix applied** (`lib/phoenix_kit_locations/web/components/place_picker.ex`,
`select_location` handler): instead of unconditionally clearing
`selected_space_uuid`, keep it only when it's actually present in the
newly-loaded tree (reusing the existing `space_in_tree?/2` ownership check
that the same commit added for `select_space`):

```elixir
tree = Spaces.list_tree(location.uuid)

selected_space_uuid =
  if space_in_tree?(tree, socket.assigns.selected_space_uuid),
    do: socket.assigns.selected_space_uuid,
    else: nil
```

This preserves the highlight when the picked Location is the seeded Space's
own Location (the seed's entire purpose) while still correctly clearing it
when the user browses to any *other* Location (the seeded uuid can't be in
that Location's tree, so `space_in_tree?/2` naturally returns `false`).

We could not re-run the two `describe "update/2 seed-once behavior"` tests
against a real Postgres in this sandbox — **please run `mix test` from a
real scratch DB before merging**, per the PR's own request, with particular
attention to `place_picker_test.exs`.

---

## Things we verified but did NOT change

- **`files_card.ex`'s `use Gettext, backend: PhoenixKitWeb.Gettext`** — looks
  inconsistent with the rest of the PR's new files (which all use the
  module's own `PhoenixKitLocations.Gettext`), but `git show fd43603:...
  location_form_live.ex` confirms this component (and its exact gettext
  strings) already existed inline in `location_form_live.ex` *before* this
  PR, using that same host backend. This is a faithful extraction, not a
  new inconsistency — correct as-is.
- **`mix.exs`'s `package.files`** gained `priv` (`~w(lib priv .formatter.exs
  ...)`) — necessary and correctly added, since this PR is the first to ship
  a `priv/gettext` directory; without it the published Hex package would
  silently drop all translations.
- **Gettext catalogs** — 42 msgids in each of `en`/`et`/`ru`, all fully
  translated (no blank `msgstr` besides the standard empty PO header entry).
- **`Spaces.reorder_siblings/4`'s root-parent `is_nil/1` handling**, the
  same-Location parent invariant, and the depth-bounded (64-hop) indirect
  cycle walk are all correctly guarded and match their moduledoc claims.

## Gate

```
mix format --check-formatted   # clean
mix compile --warnings-as-errors --force   # clean, 0 warnings
mix credo --strict              # 482 mods/funs, no issues
mix dialyzer                    # 0 errors
mix test                        # could not run — no `psql` in this sandbox,
                                 # no root to install it (same gap the PR
                                 # itself flags). Please run against a real
                                 # Postgres before merging.
```

All four static gates pass clean on the tree with our one fix applied.

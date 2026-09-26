# PR #18 Review — Files and uploads on core's toolkits, spaces tree lock, actor and activity through core

- **PR:** [#18](https://github.com/BeamLabEU/phoenix_kit_locations/pull/18)
- **Author:** mdon
- **State:** MERGED (`d8eaab5`)
- **Reviewer:** Claude (Opus 5.5)
- **Date:** 2026-09-26
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

15 commits, 39 files (+1,251 / −2,534). The module's own copies of shared code
are replaced with core 2.38's toolkits:

- `PhoenixKitWeb.Actor.opts/1` replaces four copies of `actor_opts/1`;
  `PhoenixKit.Activity.log/3` replaces the guarded, rescued `Activity.log/1` wrappers.
- `Utils.TreeQuery` replaces the space ancestor and descendant CTEs. The old
  64-hop cycle walk (which called any deeper chain a cycle) is now one
  recursive query.
- `Storage.ResourceFolders` / `PhoenixKitWeb.Attachments` replace folder
  lookup, the claim check, the name fallback, store, detach and the type
  classifier. `MediaReorganizer` shrinks to a `ResourceSource` declaration.
- The dropzone hook moves from a colocated hook, which never reached a host
  that did not import `phoenix-colocated/phoenix_kit_locations`, to a prebuilt
  `priv/static` bundle declared by `js_sources/0`.

Behaviour fixes:

- A re-parent takes a per-location advisory lock (`pg_advisory_xact_lock`)
  before its cycle check, so two opposite re-parents cannot both commit.
- `update_space/3` pins `location_uuid` to the space's own.
- The location and space saves keep a stored `files_folder_uuid`, read under
  `FOR UPDATE` (`keep_folder_pointer/2`).
- An upload that cannot be filed is cancelled instead of sitting at 100%.
- A byte-identical re-upload is flashed.
- The admin header uses the per-page title/crumb shapes.
- Edit forms open on the viewing language.
- The core floor goes to `>= 2.38.0 and < 3.0.0`.

## Verified

- **Tree lock.** Only re-parents take it, a move to the top level included
  (`reparenting?/2` normalises `""`/`nil`). Lock order is always advisory → row,
  and no other writer takes the advisory lock, so there is no lock-order
  inversion with `reorder_siblings/4` or renames. Under READ COMMITTED the
  second re-parent's `TreeQuery.ancestor_uuids/2` statement sees the first
  one's committed parent, so the opposite-direction race is closed.
  `spaces_tree_lock_test.exs` pins the lock with a real second connection.
- **Cycle check vs uuid case.** `TreeQuery` casts (lower-cases) the parent,
  and the schema's `validate_no_self_parent/1` compares cast values, so an
  upper-cased self uuid is still caught.
- **`own_location/2`** writes `location_uuid` in the key shape the attrs
  already use, so `cast/3` never sees mixed keys.
- **`keep_folder_pointer/2`** only overrides when a pointer is stored, and
  the stored pointer comes from the locked row, so a claim made
  (`ResourceFolders.write_pointer/4`) while the form was open survives the save.
- **`handle_progress/3`** cancels the entry on both unfiled branches, so a
  leftover entry no longer counts against `max_entries`.
- **`update_space/3` error clauses.** `{:ok, _}` and changeset errors are
  logged; the context atoms pass through. `save_space` and `submit_rename` both
  flash `Errors.message/1` for an atom.
- **Gate.** `mix test` ran against Postgres: 527 tests, 0 failures before the
  fixes below.

## Findings

### BUG - MEDIUM — Saving a space deleted since it was loaded crashed the Structure LiveView — FIXED

`locked_update/2` reads the row `FOR UPDATE` but used the result only for the
folder pointer. When the space was gone (deleted in another tab, or removed by
its parent's cascade), `repo().update()` raised `Ecto.StaleEntryError`, and the
Structure page crashed and remounted. `selected_space` sits in socket assigns
for as long as the panel is open, so the stale struct is realistic.

**Fix:** `locked_update/2` returns `{:error, :space_not_found}` when the locked
read comes back `nil` (the atom is already in `Errors`). Both LiveView callers
already flash `{:error, atom}`. The `@spec` and doc now list it.
Test: `spaces_test.exs` "updating a space deleted since it was loaded returns
:space_not_found". It failed with `StaleEntryError` before the fix.

### BUG - MEDIUM — Same stale-struct raise in `update_location/3` — FIXED

`update_location/3` had the same issue: its transaction locked the row and then
updated regardless. `LocationFormLive` re-reads the location just before it
saves, which leaves only a small window, but host code calling the public
context with a held struct got a raise.

**Fix:** it now rolls back to `{:error, :location_not_found}` (spec and doc
updated). `LocationFormLive.update_location/2` matches
`{:error, %Ecto.Changeset{}}` explicitly and flashes and navigates to the list
for an atom, the same way as its existing `nil` branch. Test:
`locations_test.exs` "update_location/3 on a location deleted since it was
loaded returns :location_not_found".

### NITPICK — Forged `set_active_upload_scope` scope (not fixed; pre-existing)

`set_active_upload_scope/2` accepts any string. An unknown scope reads as
`empty_scope_state/0` (`resource: nil`), so the upload lands in a fresh
`location-attachment-pending-…` folder that nothing points at. This needs
`manage_all`, since uploads are only allowed there, and it touches no other
account's data. It is left as is: rejecting unknown scopes would need
the scope list threaded through both LiveViews for no security gain.

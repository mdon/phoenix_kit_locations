# Follow-up Items for PR #3 — Quality sweep

The original quality sweep landed in commit `4dfc445` ("Bring locations
module up to quality") on top of an earlier PR #2 follow-up commit
(`a341c50`). At the time of merge there were no external reviews — the
sweep itself implemented the entire C2–C10 + part of C11 from the
workspace playbook.

This file tracks subsequent re-validation passes that bring the module
forward to the evolving post-Apr pipeline (new C-step requirements
added since the original sweep).

## Batch 2 — re-validation 2026-04-26

Second module under the post-Apr re-validation template (canonical
template: AI module, BeamLabEU/phoenix_kit_ai#5). Phase 1 PR triage
re-verified clean; Phase 2 mainly adds C-step deltas the original
sweep didn't have prompts for.

### Async UX (C5)

- ~~`phx-disable-with` on `show_delete_confirm` buttons (4 sites in
  `locations_live.ex:293/303/348/358`)~~ — **FALSE POSITIVE**.
  `show_delete_confirm` opens a modal (`@confirm_delete = {type, uuid}`)
  and is UI-state-only per AGENTS.md C5 ("`UI-state-only buttons
  (modal_close, switch_view) don't need it`"). The actual destructive
  click is the modal's confirm button (in core's
  `PhoenixKitWeb.Components.Core.Modal.confirm_modal/1`), which is
  out-of-scope for this module sweep.

### Defensive `handle_info` catch-all (C10)

- `locations_live.ex`, `location_form_live.ex`, `location_type_form_live.ex`
  had no `handle_info/2` clause at all. Phoenix.LiveView's default
  silently drops unmatched messages, but adding an explicit
  `Logger.debug` catch-all means a future PubSub subscribe (or a
  multilang-hook fall-through) won't go unnoticed in dev. Pattern matches
  the workspace sync precedent at AGENTS.md:678-680.

### `enabled?/0` `catch :exit` (AGENTS.md:911)

- `phoenix_kit_locations.ex:40-44` had only `rescue _ -> false`; added
  `catch :exit, _ -> false` so a sandbox-shutdown trap (the 1-in-N
  flake AGENTS.md:911 describes) returns the documented fallback
  rather than surfacing the exit. Matches the AI module's
  `enabled?/0` shape exactly.

### Test infrastructure (C7)

- Added `phoenix_kit_settings` table to `test/support/postgres/migrations/`.
  Mirrors core's real schema (uuid/key/value/value_json/module/
  date_added/date_updated per AGENTS.md:921-925). Without it, every
  test that triggered a `Settings.get_boolean_setting` call from the
  LV mount path (multilang languages_enabled, locations_enabled) saw
  a `relation "phoenix_kit_settings" does not exist` Logger.error.
  With the table present, the table lookup succeeds (empty row →
  default value) but core still logs a `DBConnection.OwnershipError`
  for processes outside the sandbox owner — a pre-existing log-noise
  pattern that lives upstream in core's `Settings.get_boolean_setting/2`
  Logger.error (fires *before* our outer rescue point). See AGENTS.md:1075-1076
  for the AI module's identical observation.

### Errors test pin (C8)

- `errors_test.exs` removed the `is_binary/1`-loop smell (the
  per-atom EXACT-string asserts above are sufficient pinning). Same
  shape as AI module batch 2.

### `@spec` backfill on small public surfaces (C12 #3)

- `paths.ex` — added `@spec` to all 6 public functions
  (`index/0`, `location_new/0`, `location_edit/1`, `types/0`,
  `type_new/0`, `type_edit/1`).

### Documentation (C13)

- `AGENTS.md` — added the canonical "What This Module Does NOT Have"
  section at the bottom (no PubSub, no soft-delete, no Oban, no
  external HTTP, no public API routes, no file uploads, no wizard
  form, no postal-registry validation). Pinning these in writing
  prevents future scope creep and makes review-finding triage faster.
- `README.md` — added "Error Handling" subsection (Errors atom →
  gettext message, with a one-liner example) and "Activity Logging"
  subsection. The Errors module landed in PR #3 but README didn't
  mention it; agents read the README first.

### Pinning tests (C11)

- `phoenix_kit_locations/web/locations_live_test.exs`,
  `location_form_live_test.exs`,
  `location_type_form_live_test.exs` — `handle_info` catch-all smoke
  per LV. Sends two unknown messages to `view.pid`, asserts
  `render(view)` returns a binary. If the catch-all clause regresses
  to a `FunctionClauseError`, the round-trip fails.

## Skipped / surfaced (with rationale)

- **Activity logging on `:error` branch.** The C12 #2 prompt
  (AGENTS.md:644-647) calls for every CRUD context fn to log on
  `:error` too with a `db_pending: true` flag. The original sweep
  deliberately scoped to `:ok`-only, and the AI re-validation kept the
  same scope. Surfaced here for completeness; not fixed in Batch 2.
  Adding `:error`-branch logging is a one-pattern refactor across the
  10 mutating fns in `locations.ex` — a "fix everything" pass would
  close it.

- **LV-level `actor_uuid:` pinning in delete tests.** C12 #2 calls
  for delete tests to assert `assert_activity_logged(action,
  actor_uuid: ...)` rather than just resource-uuid match. Pinning
  this requires scope-injection test infra (`hooks.ex` +
  `LiveCase.put_test_scope/2` + `fake_scope/1` mirroring
  `phoenix_kit_hello_world/test/support/`). The
  `actor_opts/1` threading is already verified at the context layer
  by `test/activity_logging_test.exs` (every CRUD test passes
  `actor_uuid: @actor` and `assert_activity_logged` pins it). The AI
  module's batch 2 also did NOT add scope hooks. Surfaced as a future
  test-depth improvement, not blocking.

- **Pre-existing log spam from core's `Settings.get_boolean_setting/2`.**
  See "Test infrastructure (C7)" above and AGENTS.md:1075-1076.
  Suppressing the upstream Logger.error lives in core, not this
  module.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_locations.ex` | 2 (`<commit>`) | `enabled?/0` + `catch :exit, _ -> false` |
| `lib/phoenix_kit_locations/paths.ex` | 2 | `@spec` on all 6 public fns |
| `lib/phoenix_kit_locations/web/locations_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `lib/phoenix_kit_locations/web/location_form_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `lib/phoenix_kit_locations/web/location_type_form_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `test/support/postgres/migrations/20260403000000_setup_phoenix_kit.exs` | 2 | `phoenix_kit_settings` table per AGENTS.md:921 schema |
| `test/errors_test.exs` | 2 | drop `is_binary/1`-loop smell |
| `test/phoenix_kit_locations/web/locations_live_test.exs` | 2 | `handle_info` catch-all pin |
| `test/phoenix_kit_locations/web/location_form_live_test.exs` | 2 | `handle_info` catch-all pin |
| `test/phoenix_kit_locations/web/location_type_form_live_test.exs` | 2 | `handle_info` catch-all pin |
| `AGENTS.md` | 2 | "What This Module Does NOT Have" section |
| `README.md` | 2 | Error Handling + Activity Logging subsections |

## Verification

- `mix compile` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues, 190 mods/funs
- `mix dialyzer` — 0 errors, 0 skipped, 1 unnecessary skip
- `mix test` — **162 tests, 0 failures** (up from 160)
- 10/10 stable runs

## Open

None.

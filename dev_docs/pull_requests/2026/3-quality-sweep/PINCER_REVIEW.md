# PR #3 Review — Quality sweep + re-validation

**Reviewer:** Pincer 🦀 | **Date:** 2026-04-29 | **Verdict:** Approve (already merged) — three should-fix items for a follow-up PR

## Summary

Large, well-organized sweep: 73 → 188 tests, 96.89% line coverage, real test
infrastructure (`Test.Endpoint` + `LiveCase` + scope-injection hooks),
centralized error mapping, activity logging across all mutations, and an
honest `FOLLOW_UP.md` documenting residual coverage gaps. Most of it lands cleanly.

The remaining concerns cluster into three buckets:

1. **Phoenix lifecycle** — DB queries in `mount/3` of two LiveViews (Iron Law
   violation; called twice per page load).
2. **Error surface** — the `Errors` fallback can leak `inspect/1` output to
   end users.
3. **Coverage shape** — one of the new tests deliberately drops production
   tables to exercise an unreachable rescue branch. That's coverage of
   defensive code that the author himself flags as dead in `FOLLOW_UP.md`.

The author's own `FOLLOW_UP.md` already documents most residual coverage
misses; this review adds the items it does **not** flag.

---

## Should-fix (post-merge)

### 1. DB queries in `mount/3` of form LiveViews

**`lib/phoenix_kit_locations/web/location_form_live.ex:41-69`**

`mount/3` calls (via `load_location/2` and the assign block):

- `Locations.get_location/1` (line 77, edit only)
- `Locations.linked_type_uuids/1` via `safe_linked_type_uuids/1` (line 87, edit only)
- `Locations.list_location_types/1` via `safe_list_location_types/0` (line 95, **always**)

**`lib/phoenix_kit_locations/web/location_type_form_live.ex:22-45`**

`mount/3` calls `Locations.get_location_type/1` (line 53, edit only).

Phoenix LiveView's `mount/3` is invoked **twice** — once during the dead HTTP
render, once during the WebSocket connect — so every query above runs twice
per page load. The standard fix is to move data loading to `handle_params/3`
(URL-driven) or guard with `connected?(socket)` if the dead render really
needs the data.

`LocationsLive.mount/3` (`web/locations_live.ex:24-32`) gets this right —
empty assigns in mount, `load_data/2` in `handle_params/3`. Apply the same
pattern to the form LVs.

Note: the post-PR-#2 credo refactor (`c1b6381`, `7f57325`) reorganised
`LocationFormLive.mount/3` to satisfy cyclomatic complexity but did not
move queries out — this isn't a regression introduced by PR #3, but the
"quality sweep" framing implies it would have been the place to fix it.

### 2. `Errors.message/1` fallback leaks `inspect/1`

**`lib/phoenix_kit_locations/errors.ex:44-46`**

```elixir
def message(reason) do
  gettext("Unexpected error: %{reason}", reason: inspect(reason))
end
```

The moduledoc claims "nothing silently surfaces a raw struct" (line 17), but
this is exactly what does happen — any unmapped reason is `inspect/1`'d into
the user-visible flash. If a `Postgrex.Error`, an `Ecto.Changeset`, or a
multi-tuple ever reaches this clause, the user sees internal structure
(table names, constraints, query fragments).

**Fix:** log internally, return a generic translated string:

```elixir
def message(reason) do
  Logger.warning("[Errors] unmapped reason: #{inspect(reason)}")
  gettext("An unexpected error occurred.")
end
```

### 3. `LocationsLive do_delete_item` outer rescue + its DROP-TABLE test

**`lib/phoenix_kit_locations/web/locations_live.ex` (rescue clause in `do_delete_item/3`)**
**`test/destructive_rescue_test.exs:47-74`**

The test in `destructive_rescue_test.exs` mounts a LiveView, then runs
`DROP TABLE phoenix_kit_locations CASCADE` mid-handler so the rescue clause
in `do_delete_item/3` triggers. The PR's own `FOLLOW_UP.md:270-275`
acknowledges:

> the `{:error, reason}` arm of `do_delete_item` is dead because
> `Locations.delete_*` either succeeds or raises

The rescue catches a class of failures that cannot occur via the public API
in production. The right move is to **delete the rescue and the test
together** — production `repo.delete/1` either returns `{:ok, _}` or raises a
specific error that LiveView's standard supervision will handle correctly.

Keeping the other two `destructive_rescue_test` tests (`find_similar_addresses`
returns `[]` on missing table; `create_location` succeeds without
`phoenix_kit_activities`) is defensible — those pin the documented graceful-
degradation contract. The `do_delete_item` one does not.

The 96.52% → 96.89% coverage bump from `80b4b3f` is anti-value: it
incentivises future contributors to add tests *for* defensive code rather
than removing the code.

---

## Nice-to-have

### `Code.ensure_loaded?(PhoenixKit.Activity)` on every log

**`lib/phoenix_kit_locations/locations.ex:536`**

`PhoenixKit.Activity` is a hard dep declared in `mix.exs`; the module is
always loaded. The `Code.ensure_loaded?/1` guard hits the `:code_server` on
every mutation. Either drop it or replace with `function_exported?/3` cached
in a module attribute. Negligible perf cost; the smell is "defensive code
pretending a hard dep is soft."

### Generic catch-all rescue in `maybe_log_activity`

**`lib/phoenix_kit_locations/locations.ex:559-561`**

The `Postgrex.Error :undefined_table` rescue is reasonable for the
"host hasn't migrated" case. The trailing generic `e -> Logger.warning(...)`
swallows everything else — DB timeouts, connection errors, `ArgumentError`
from bad metadata. Narrow to `[Postgrex.Error, DBConnection.ConnectionError]`
or remove and let the rescue stay scoped.

### `safe_linked_type_uuids/1` and `safe_list_location_types/0` rescues

**`lib/phoenix_kit_locations/web/location_form_live.ex:86-100`**

These wrap `Locations.*` calls in `rescue error -> []`. The Locations
functions either succeed or raise on missing tables; the rescue exists
*only* to satisfy the artificial DROP-TABLE test scenarios in
`destructive_rescue_test.exs:76-95`. Either remove (let it crash; the LV
supervisor will recover with a flash via the LiveView error template) or
narrow to `Postgrex.Error`.

### `actor_opts/1` is duplicated across all three LVs

`web/locations_live.ex` (~L179), `web/location_form_live.ex` (~L513),
`web/location_type_form_live.ex` (~L131-136). Identical 6-line helper.
Extract to a shared module — e.g. `PhoenixKitLocations.Web.ScopeHelper`.

### `insert_type_assignment!/3` naming

**`lib/phoenix_kit_locations/locations.ex` (insertion path)**

The new `LocationTypeAssignment.changeset/2` correctly converts FK
violations from raises to `{:error, changeset}`. The wrapper still ends in
`!`, which by Elixir convention means "raises on error." It now propagates
via `repo().rollback/1` from inside a transaction — defensible, but the
name is misleading. Rename to `insert_type_assignment_or_rollback/3` or
drop the `!`.

### `handle_info` catch-all rationale

**`web/locations_live.ex:111-115`**, **`web/location_form_live.ex:210-214`**,
**`web/location_type_form_live.ex:99-103`**

Defensible as a future-proofing measure. The comments cite "MultilangForm
hook fall-throughs" — verify that hook actually sends unhandled messages.
If yes, name them. If no, the catch-all is solving a hypothetical problem.

---

## Nits

- **`get_location_by/2` doc** (`locations.ex` near L187): the doc says
  unknown fields raise `ArgumentError`; in fact they raise
  `FunctionClauseError`. Update the doc.
- **`sync_location_types/3` `@spec`**: claims `{:error, :type_assignment_failed}`,
  but the function returns whatever `repo.transaction/1` produces. Tighten
  the spec or widen to `{:error, term()}`.
- **`README.md:79`** example: `{:error, _changeset} -> Errors.message(:location_delete_failed)`
  is misleading — `delete_location/2` returns `{:ok, _}` or raises in the
  current implementation. Use `:location_not_found` (the actual error path
  callers see) as the example.
- **`mix.exs:58`** `lazy_html >= 0.1.0` — unusually loose constraint. Pin to
  `~> 0.1`.
- **`do_delete_item/3` factoring** (`locations_live.ex:121-154`): six
  per-kind dispatch helpers (`fetch_for_delete/2`, `delete_for_kind/2`,
  `deleted_message/1`, `not_found_atom/1`, `delete_failed_atom/1`,
  `reload_action/1`) for two kinds. A simple `case kind do` would be ~10
  lines shorter and just as readable.

---

## What's good (worth highlighting)

1. **`changeset_error_metadata/1`** (`locations.ex:574`) — PII-safe by
   construction: emits field names + `db_pending: true`, never values.
   Genuinely useful audit-trail pattern.
2. **`PhoenixKitLocations.Errors`** — central, gettext-backed, atom contract
   is testable. Right abstraction at the right boundary.
3. **`LocationTypeAssignment.changeset/2` with `assoc_constraint/2`** —
   correctly converts FK violations from raises to changesets. Right fix
   at the right layer; a real behaviour improvement, not a coverage hack.
4. **`sync_location_types/3` no-op short-circuit** — `MapSet.equal?` plus
   "only log when the set actually changed" keeps activity logs clean and
   skips a transaction.
5. **Test infrastructure** (`LiveCase`, `Hooks`, `Test.Endpoint`,
   `Test.Router`) — `:assign_scope` mirrors production scope-injection;
   `fake_scope/1` returns a real `%Scope{}` struct rather than a bag of
   fields.

---

## Suggested follow-up scope

A single "PR #4 — locations LV lifecycle hygiene" branch covering:

1. Move queries from `LocationFormLive.mount/3` and
   `LocationTypeFormLive.mount/3` into `handle_params/3`.
2. Tighten `Errors.message/1` fallback (log internally, return generic
   translated string).
3. Delete `do_delete_item` outer rescue + the matching DROP-TABLE test.
4. Extract `actor_opts/1` to `PhoenixKitLocations.Web.ScopeHelper`.

Items 1 and 3 are behaviour changes worth their own commits with explicit
"why" notes in the body. Items 2 and 4 are mechanical.

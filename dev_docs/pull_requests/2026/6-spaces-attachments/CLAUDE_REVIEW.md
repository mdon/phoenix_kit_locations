# PR #6 Review — Spaces (floors/rooms) + scope-aware Attachments + Phase 2 cleanup

**Reviewer:** Claude | **Date:** 2026-05-29 | **Verdict:** Approve **with one
required fix that we applied ourselves** (post-merge) — a save-path crash for
the common "location with no spaces" case. Three cleanups also applied (two
`textarea` attr warnings + the latent `reorder_siblings` root-parent no-op);
two minor items left as recommendations.

## Scope of what we reviewed

PR #6 is large (3697 / −80, 17 files, 24 commits): the V122 **Spaces** feature
(staged floor/room drafts that commit on Location save), a scope-aware
**Attachments** rework, the Locations/Types subtab cleanup, a full-width style
sweep, PR #4 / #5 follow-ups, and a credo + dialyzer pass. We read the new
context (`spaces.ex`), schema (`schemas/space.ex`), error mapping
(`errors.ex`), the 820-line `attachments.ex`, and the 2341-line
`location_form_live.ex` draft-persistence pipeline + validation gate in full.
The PR was already merged to `main` (commit `c88ca87`) by the time of review;
the fixes below are committed against the merged tree.

The architecture is sound: drafts as the single source of truth, a two-pass
floor-then-room persist with an `id_map` to translate `new-…` draft ids to real
UUIDs, context-boundary parent/cycle invariants instead of a heavier composite
FK, and a `Code.ensure_loaded?/1`-guarded + rescued activity logger so logging
never takes down a mutation. The error-atom → gettext indirection in
`errors.ex` is clean. None of that needed changing.

---

## What we fixed ourselves

### `BUG - CRITICAL` — saving a location with no staged spaces crashed the form *(fixed)*

`persist_space_drafts/3` had two clauses with the **identical** head
`persist_space_drafts([], _location_uuid, _socket)`:

```elixir
defp persist_space_drafts([], _location_uuid, _socket), do: nil               # ← shadowing
defp persist_space_drafts([], _location_uuid, _socket), do: {nil, MapSet.new()}
```

The first always matches, so the empty-drafts case returned `nil`. But every
caller destructures the result as a tuple:

```elixir
{flash, failed_ids} = persist_space_drafts(socket.assigns.space_drafts, location.uuid, socket)
```

`{flash, failed_ids} = nil` raises `MatchError`, crashing the LiveView on save.
And `space_drafts` starts as `[]` for every `:new` location
(`assign_spaces_state(socket, :new, …)`, line 109–111) — so this fires on the
**overwhelmingly common path**: creating or updating any location that has no
floors/rooms. The leftover `do: nil` clause is a relic from when the function
returned just a flash; the return contract changed to `{flash, failed_ids}` but
the empty clause wasn't updated.

The compiler flags it outright:

```
warning: this clause cannot match because a previous clause at line 932
         matches the same pattern as this clause
934 │   defp persist_space_drafts([], _location_uuid, _socket), do: {nil, MapSet.new()}
```

**Fix:** deleted the dead `do: nil` clause so the empty case returns the
correct `{nil, MapSet.new()}`.

**Why it slipped through:** the unit suite (89 tests) the PR ran does not
exercise this — the DB-backed test that *does* save a spaceless location
(`location_form_live_test.exs:15`, "submitting the form creates a location,
redirects…") lives in the integration suite, which was "excluded under no-DB."
The crash only manifests when a real save reaches `persist_space_drafts/3`,
which needs a Repo.

### `NITPICK` — `<.textarea label={nil}>` × 2 emitted a component attr warning *(fixed)*

The floor and room "Internal notes" editors passed `label={nil}` to the core
`<.textarea>` (declared `attr :label, :string, default: nil`). Phoenix's
attribute validation warns on an explicit `nil` against a `:string` attr:

```
warning: attribute "label" in component …Textarea.textarea/1 must be a :string, got: nil
```

The textareas sit inside a `<details>` with their own `<summary>` label, so they
genuinely want no label. **Fix:** dropped the `label={nil}` attribute entirely —
the `default: nil` already produces the label-less render, behavior-identical and
warning-free.

Net diff: **4 deletions, 1 file** (`location_form_live.ex`).

---

## Verification we ran (and what we couldn't)

- `mix compile` — confirmed the `cannot match` and `textarea`/`label` warnings
  are **gone** after the fix; no new warnings introduced.
- `mix format --check-formatted` — clean on the edited file.
- `mix test` — **could not run in this environment**: `test/test_helper.exs`
  shells out to `System.cmd("psql", …)` to provision the test DB, and `psql`
  isn't installed here (`:enoent`). This is the same DB gap that hid the bug —
  the save path is DB-backed. The fix is a behavior-preserving removal of a
  dead clause + two no-op attrs, so the existing 89 unit tests are unaffected,
  and the integration save test should now pass instead of crashing once run
  against a DB.

---

### `BUG - LOW` (latent, currently unused) — `Spaces.reorder_siblings/4` no-oped for root-level floors *(fixed)*

The original query scoped the sibling group with a pinned `== ^parent_uuid`:

```elixir
from(s in Space,
  where: s.uuid == ^uuid and s.location_uuid == ^location_uuid and
           s.parent_uuid == ^parent_uuid)
```

When `parent_uuid` is `nil` (every floor — floors are always root), a pinned
`== ^nil` compiles to SQL `parent_uuid = NULL`, which is never true, so
`update_all` matched **zero rows** and the reorder silently did nothing.
Rooms (non-nil parent) reordered fine. The function has **no callers yet**
(reordering isn't wired into the staged-draft UI), so this was latent — but it
would bite whoever wires up floor drag-reordering.

**Fix:** extracted a `sibling_position_query/3` helper with a `nil`-parent
clause that uses `is_nil(s.parent_uuid)` and a non-nil clause that keeps the
pinned equality — clause-per-case, matching the module's existing
`check_parent_under_location/2` / `classify_for_floor_delete/3` style.

## Recommendations we did *not* apply (flagged for follow-up)

### `NITPICK` — inconsistent key access in `update_space/3`'s cycle check

`validate_parent_location/1` reads `parent_uuid` under **both** string and atom
keys, but the sibling `validate_no_cycle` call passes `attrs["parent_uuid"]`
(string only). An atom-keyed `attrs` would silently skip the cycle guard. Every
current caller (the form pipeline) uses string keys, so it's correct in
practice — but the two checks should agree on key handling.

### `NITPICK` — `:parent_in_other_location` returned for a non-existent parent

`check_parent_under_location/2` maps a `get_space(parent_uuid) == nil` (parent
UUID doesn't exist at all) to `:parent_in_other_location`. Slightly misleading;
a separate `:parent_not_found` atom would read truer. Cosmetic — the form never
lets a user pick a non-existent parent.

### Process note — add `mix compile --warnings-as-errors` to the quality gate

The PR's gate ran credo / dialyzer / format / test but **not**
`--warnings-as-errors`. The critical bug was a plain compiler warning
("this clause cannot match"); warnings-as-errors in `test.setup`/CI would have
blocked the merge. Worth adding given how much of this module's correctness
rides on clause ordering and pattern coverage. (Note: the file also carries
several pre-existing "clauses should be grouped together" warnings — those are
an *intentional* "handler next to its private helpers" layout used throughout
this LiveView, e.g. `toggle_type` at line 313 predating this PR; warnings-as-
errors would need those grouped or that specific warning allowed.)

---

## What's good (worth highlighting)

1. **Drafts as single source of truth.** New (`persisted?: false`) and existing
   (`persisted?: true` / `deleted: true`) spaces share one list and one commit
   path. Partial-save failures keep the failed drafts on the page
   (`finish_save/5`) instead of dropping the user's typing.
2. **Two-pass persist with `id_map`.** Floors first, then rooms with their
   `new-…` parent ids resolved to freshly-created UUIDs — and rooms whose parent
   floor failed validation get a purpose-built `:parent_floor_unsaved` error
   rather than a misleading FK `:parent_in_other_location`.
3. **Invariants at the right layer.** Same-location parent and indirect-cycle
   (depth-bounded walk-up, 64 hops) live in the context, not smeared across the
   schema or the LV; the schema only owns the direct self-loop guard. Matches
   the module's documented "no composite FK" trade-off.
4. **Attachments rework is scope-keyed cleanly** — every Files card routes by a
   `scope` (`location` / draft id) so multiple dropzones coexist, and the
   activity logger / Files calls are rescued so a missing V122 migration leaves
   the card empty instead of crashing the form.
5. **The new pure-helper tests are real** — `space_test.exs`,
   `attachments_test.exs`, and the `errors_test.exs` extension cover the
   app-layer kind whitelist, length caps, self-parent guard, file-size/icon
   formatting, and the new error atoms without tautology.

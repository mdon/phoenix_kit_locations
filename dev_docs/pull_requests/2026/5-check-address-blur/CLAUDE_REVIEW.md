# PR #5 Review — Fix `check_address` blur crash that wiped every typed field

**Reviewer:** Claude | **Date:** 2026-05-25 | **Verdict:** Approve (already merged) — no required fixes, two optional follow-ups

## Summary

A one-line pattern-match bug was taking down the LiveView on every
address-field blur. `phx-blur="check_address"` (on Address Line 1 /
City / Postal Code) sends only event metadata —
`%{"key" => nil, "value" => "<blurred input's value>"}` — never the
form's serialized params. Only `phx-change` / `phx-submit` produce the
`%{"location" => params}` shape. The handler matched on
`%{"location" => params}`, so every real blur raised
`FunctionClauseError`, crashed the LV process, triggered a browser
reconnect, and remounted the form blank. From the user's chair: type a
field, click into the next one, watch everything you typed disappear.

The fix drops the form-shaped match and reads the address straight off
the changeset, which `phx-change="validate"` keeps current on every
keystroke (no `phx-debounce` on the core `<.input>`). Net +13 / −4 in
the handler, plus a real overhaul of the test that was supposed to
catch this.

The diagnosis is correct, the fix is idiomatic, and — notably — the
tests now exercise the actual browser event path instead of a
hand-crafted payload that happened to match the broken signature.

---

## Verified correct

The fix leans on two preconditions; both hold.

### 1. `:changeset` is always assigned before any blur

`mount/3` calls `assign_form(changeset)`
(`lib/phoenix_kit_locations/web/location_form_live.ex:66`, `:110-112`),
which assigns both `:form` and `:changeset`. So a blur on an untouched
field — focus in, focus out, no keystroke — can't crash on a missing
assign. The `:edit` test confirms this: it blurs without seeding the
changeset first and still passes, because `Ecto.Changeset.get_field/2`
falls back to the loaded record's data.

### 2. The changeset is fresh by the time blur fires

`phx-change="validate"` (`:262`) → `handle_event("validate", …)`
(`:119-134`) re-derives and re-assigns the changeset every keystroke,
and there's no `phx-debounce` on the inputs. LiveView delivers channel
events in order, so the final keystroke's `change` is processed before
the `blur` — the blurred field's latest value is already in the
changeset when `check_address` reads it.

Nice side effect: `validate` resets `:address_warning` to `nil` each
keystroke and blur recomputes it, giving consistent "warn on blur,
clear as you type" UX for free.

---

## Tests: the real win

The four pre-existing `check_address` tests used
`render_hook(view, "check_address", %{"location" => …})` — a payload
shaped to match the **broken** handler. They were green while the
feature was broken: a textbook example of a test asserting the bug.

This PR switches them to seed the changeset via `render_change` and
then drive blur with `render_blur` on the actual
`input[name="location[address_line_1]"]` element — the same event
shape a browser emits — and adds a regression test that reproduces the
reported scenario end to end: type a name + address, blur the address
field, then assert `Process.alive?(view.pid)` and that every typed
value survives the re-render.

That `Process.alive?` assertion is the right guard: under the old
handler the blur would crash the LV (and `render_blur` would raise
before the assert even ran), so the regression can't silently come
back.

---

## Findings

No `BUG` findings — the PR removes one. The items below are
improvements, neither blocking nor introduced by this PR.

### `IMPROVEMENT - MEDIUM` — redundant per-blur queries

The handler now ignores its params (`_params`) and reads all three
address fields from the changeset, so blurring **any** of the three
bound fields runs the same full `find_similar_addresses/4` lookup.
Tabbing through Address Line 1 → City → Postal Code fires three
near-identical DB queries. Harmless and invisible to users. If anyone's
already in that template, a single `phx-blur` (e.g. only on
`postal_code`) would do the same job — but it's not worth a dedicated
change.

### `IMPROVEMENT - HIGH` — DB query in `mount/3` (pre-existing, separate ticket)

`mount/3` calls `load_location/2`, which queries the DB for `:edit`
(`:41-68`). `mount/3` runs twice (HTTP render + WebSocket connect), so
that's the classic "no queries in mount" anti-pattern — the load
belongs in `handle_params/3`. Unrelated to this blur fix and on a
different code path; flagged here only so it's tracked. Own ticket, own
test surface.

---

## What's good (worth highlighting)

1. **Root-cause writeup is honest and precise.** The PR body names the
   exact payload shape `phx-blur` sends, cites the working precedent in
   core (`referrals/web/settings.html.heex` pairing `phx-blur` with
   `phx-value-*`), and explains *why the old tests passed anyway*.
   That last part is the tell of a real diagnosis rather than a
   guess-and-check fix.
2. **Reads from the changeset, not a reconstructed payload.** The
   alternative — adding `phx-value-*` attributes to feed the handler —
   would have worked but coupled the binding to the handler's argument
   shape. Reading the changeset that `validate` already maintains is
   the lower-coupling choice.
3. **Tests now simulate the browser, not the bug.** Swapping
   `render_hook` for `render_change` + `render_blur` on the real
   element is the difference between "tests the handler I wrote" and
   "tests what the user actually does."
4. **Quality gates clean** per the PR body: `mix format`, compile
   `--warnings-as-errors`, `credo --strict`, `dialyzer`,
   `deps.unlock --check-unused` all pass; 40 unit tests green
   (the `check_address` tests are `:integration` / DB-backed and were
   excluded locally — expected to pass with a DB).

---

## Suggested follow-up scope

Neither item is required to merge (already merged) or to ship. If a
hygiene pass gets queued:

1. **Optional:** collapse the three `phx-blur="check_address"` bindings
   to one. Marginal; skip unless touching that template anyway.
2. **Worth its own ticket:** move the `:edit` load out of `mount/3`
   into `handle_params/3` so it doesn't run twice. Real anti-pattern,
   but pre-existing and out of scope for a blur fix.

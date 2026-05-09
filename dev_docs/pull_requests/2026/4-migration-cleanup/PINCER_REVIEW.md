# PR #4 Review — Migration cleanup: drop hand-rolled test DDL, swap to `ensure_current/2`

**Reviewer:** Pincer 🦀 | **Date:** 2026-05-05 | **Verdict:** Approve (already merged) — two should-fix items, a few nice-to-haves

## Summary

Net −130 lines and a real architectural win: deletes the 143-line
`test/support/postgres/migrations/20260403000000_setup_phoenix_kit.exs`
that hand-rolled a copy of core's V40 / V03 / V90 DDL, and replaces it
with a single `PhoenixKit.Migration.ensure_current/2` call in
`test/test_helper.exs`. Schema drift between test and prod is now
impossible by construction — the test schema is built by the same
versioned migrations that ship to host apps.

The one fixture-drift the cleanup surfaces (V90 ships
`phoenix_kit_notifications` with an FK to `phoenix_kit_activities`, so
plain `DROP TABLE phoenix_kit_activities` no longer succeeds) is
addressed correctly by switching to `DROP TABLE … CASCADE` in
`destructive_rescue_test.exs`. That's a *good* outcome — the test now
exercises the rescue against the real production constraint graph
instead of a stripped-down test fixture.

The remaining concerns are documentation and version-pinning hygiene,
not behaviour. Two are should-fix; the rest are polish.

---

## Should-fix

### 1. Dangling reference to `dev_docs/migration_cleanup.md`

**`test/test_helper.exs:65`**

```elixir
# … See `dev_docs/migration_cleanup.md` for the full story.
PhoenixKit.Migration.ensure_current(PhoenixKitLocations.Test.Repo, log: false)
```

The file does not exist anywhere in the repo:

```bash
$ ls dev_docs/migration_cleanup.md
ls: cannot access 'dev_docs/migration_cleanup.md': No such file or directory
```

Either land the doc (the AGENTS.md update covers a chunk of what would
go in it; promote those paragraphs into a standalone doc), or drop the
"See …" sentence. Comment-pointing at a file that isn't there is a
strictly worse state than no pointer at all — the next contributor
spends time looking for a doc that never landed.

### 2. PR description / version-floor mismatch with `mix.exs`

The PR body says:

> `ensure_current/2` (core 1.7.105+ / phoenix_kit#515)…
> **Should be merged after BeamLabEU/phoenix_kit#515** — CI will be red until core 1.7.105 publishes.

But `mix.exs` still pins `{:phoenix_kit, "~> 1.7"}` (`mix.exs:52`) and
the lockfile is at `1.7.95`. There's no version floor enforcing the
"1.7.105+" requirement, so a clean checkout could resolve to an older
core that doesn't expose `ensure_current/2`, and `mix test` would
crash at boot with `UndefinedFunctionError` rather than a readable
"please bump phoenix_kit" hint.

(Local inspection: `deps/phoenix_kit @ 1.7.95` *does* already export
`ensure_current/2` — so either the PR description's "1.7.105" floor is
stale, or the function was backported. Worth confirming and pinning
the actual minimum.)

**Fix:** bump the constraint to `{:phoenix_kit, "~> 1.7.95"}` (or
whichever version is the true floor) so resolution fails fast on a
host that's too old.

---

## Nice-to-have

### `ensure_current/2` accumulates rows in `schema_migrations`

This is a property of the helper itself, not this PR — but worth
flagging here because it's the pattern this repo just adopted. Per
core's docstring (`deps/phoenix_kit/lib/phoenix_kit/migration.ex:212`):

> The `schema_migrations` table accumulates one row per call —
> cosmetic noise acceptable for the test-DB use case.

The test DB is dropped/recreated via `mix test.reset`, so this only
matters between resets — but if a contributor runs `mix test` on a
loop (e.g. via a watcher) they'll see `schema_migrations` grow without
bound. Worth a one-line comment in `test_helper.exs` calling out that
`mix test.reset` clears it, so the first contributor to notice the
growing table doesn't go hunting for a leak.

### `test.setup` no longer mentions migrations

**`mix.exs:40-42`**

```elixir
"test.setup": [
  "ecto.create --quiet -r PhoenixKitLocations.Test.Repo"
]
```

`test.setup` used to chain `ecto.create` + `ecto.migrate`. Now it's
only `ecto.create` and the migration step happens implicitly inside
`test_helper.exs` on every `mix test` run. That's correct given
`ensure_current/2`'s "re-runnable on every boot" semantics, but a
contributor reading `mix.exs` in isolation will wonder where the
schema comes from. A two-line `# Schema is applied by …` comment
above the alias would close that loop.

### `destructive_rescue_test.exs` now also drops `phoenix_kit_location_type_assignments`

**`test/destructive_rescue_test.exs:30, 67-68, 78, 88`**

The PR body documents the activities-FK fix but doesn't mention that
several tests in this file also pre-emptively drop
`phoenix_kit_location_type_assignments CASCADE` before dropping the
parent table. That's also correct — V90 added the assignments table
with FKs back to `phoenix_kit_locations` and `phoenix_kit_location_types`
— but it's a second instance of the same "fixture-drift after switching
to real V90" pattern that deserves a callout in the PR body so future
diff-readers see the full story.

### Verification claim cites a path-dep override that isn't in the repo

The PR body says:

> Local test suite via `phoenix_kit_parent` path-dep override resolving
> to local core 1.7.104+:

There's no `phoenix_kit_parent` reference in `mix.exs` and no
`/workspace/phoenix_kit_parent` directory. That's expected for a
publish-ready PR (you don't ship a path override), but the verification
note reads like contributors can reproduce the run as-is. A one-line
"requires local checkout of phoenix_kit at sibling path with `mix.exs`
override applied" would save the next reviewer a confused 15 minutes.

---

## Nits

- **`test_helper.exs:54-66`** comment block: 12 lines explaining why
  `ensure_current/2` exists. Most of that rationale belongs in core's
  docstring (and is already there at
  `deps/phoenix_kit/lib/phoenix_kit/migration.ex:191-220`). Trim to
  ~3 lines: "uses core's `ensure_current/2` so the test schema tracks
  whatever V-migrations core ships; replaces the deleted hand-rolled
  shim. See `PhoenixKit.Migration` for re-runnable semantics."
- **`test/destructive_rescue_test.exs:30, 67`** double-blank lines
  between consecutive `TestRepo.query!(...)` calls look incidental,
  not deliberate. Worth a `mix format` pass — though that's a credo /
  formatter concern, not a review one.
- **AGENTS.md L194-216** still describes "test setup" prose; the
  cleanup is a chance to also drop the now-stale "Create the DB once"
  pgcrypto / `uuid-ossp` callout if any of it predates the
  `ensure_current/2` switch.

---

## What's good (worth highlighting)

1. **Net −130 lines.** Real deletion, not relocation. The
   hand-rolled test migration was a maintenance trap — every time core
   shipped a new V-migration, this repo would silently diverge. Gone
   now, by construction.
2. **`DROP TABLE … CASCADE` is the right fix.** The cleaner instinct
   would be "let's not test the rescue at all" — but the rescue
   contract (graceful degradation when host hasn't migrated) is
   real, and exercising it against production's actual FK graph
   (with `phoenix_kit_notifications` + assignments cascading off)
   is *more* faithful than the previous fixture run.
3. **`mix test.setup` is now a one-liner.** `ecto.create` and
   nothing else. The migration step is implicit in
   `test_helper.exs` — single source of truth for "what schema does
   the test suite need?"
4. **AGENTS.md documentation update is honest.** Both the
   "Database & Migrations" and "Testing" sections were updated in
   the same diff so the docs don't lie about how the test DB is
   built. A common failure mode in cleanup PRs is leaving the docs
   referencing the old shape; this one doesn't.
5. **Idempotent-by-construction.** `ensure_current/2`'s
   wall-clock-version trick (core's `Migration` module L208-216)
   means CI re-runs and local watch loops both work without manual
   `mix ecto.migrate` between them. The cost — accumulating rows
   in `schema_migrations` — is documented in core and irrelevant
   for test DBs.

---

## Suggested follow-up scope

Two-commit hygiene PR — maybe bundled with the PR #3 follow-ups
already queued:

1. Either land `dev_docs/migration_cleanup.md` (move the relevant
   AGENTS.md paragraphs there) or drop the "See …" comment in
   `test_helper.exs:65`.
2. Bump `{:phoenix_kit, "~> 1.7"}` → `{:phoenix_kit, "~> 1.7.95"}`
   in `mix.exs:52` (or the actual minimum that exposes
   `ensure_current/2`) so resolution fails fast on too-old hosts.

Both are mechanical. Item 1 is the one to prioritize — a comment
pointing at a missing file is the kind of silent lie that erodes
trust in the rest of the comments.

# CLAUDE_REVIEW — PR #7: Add env-gated path override for phoenix_kit deps

**PR:** https://github.com/BeamLabEU/phoenix_kit_locations/pull/7
**Commit:** `b8e81f6`
**Scope:** `mix.exs`, `AGENTS.md` (+34 / -1)

## Summary

Wraps `phoenix_kit` (and future sibling `phoenix_kit_*` deps) in a `pk_dep/3`
helper: when `<APP>_PATH` is set the dep resolves to a local `path:` +
`override: true` checkout; otherwise the published Hex pin is used unchanged.
Clean design — unset env genuinely leaves `mix hex.publish` and CI resolving
exactly as before. One real edge case was found and fixed.

## Findings

### BUG — MEDIUM: empty `<APP>_PATH` produced a broken `path: ""` dep

`System.get_env/1` returns `""` (not `nil`) for an exported-but-empty
variable. The common inline-unset idiom `PHOENIX_KIT_PATH= mix test` fell into
the `path ->` clause and produced `{:phoenix_kit, [path: "", override: true]}`.
Mix expands `path: ""` to the project's **own** directory, so phoenix_kit
resolved to a broken local checkout instead of the Hex pin — silently breaking
the AGENTS.md promise *"Unset = the published pin."*

**Fix:** read with a `""` default and `String.trim/1`, treat blank as unset
(also guards against a stray-whitespace path).

### IMPROVEMENT — LOW: redundant `nil` clause split (folded into the fix)

`{app, requirement, []}` is valid Mix dep syntax, so the two no-path clauses
are cosmetic. Kept the 2-tuple output for cleanliness but they now branch on
`""` rather than `nil`.

### NITPICK: version requirement unchecked in path mode

In path mode the `~> 1.7.125` requirement is dropped (correct — Mix rejects a
version req on a `path:` dep), so there's no guard that the local checkout
satisfies the floor. Acceptable for local dev; flagged only for awareness.

## Resolution

Applied to `mix.exs`:

```elixir
defp pk_dep(app, requirement, opts \\ []) do
  env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

  case System.get_env(env_var, "") |> String.trim() do
    "" when opts == [] -> {app, requirement}
    "" -> {app, requirement, opts}
    path -> {app, [path: path, override: true] ++ opts}
  end
end
```

Comment updated to "Unset or blank => the published pin."

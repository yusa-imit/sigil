# Plan 005 — Phase 2E: JSON Pointer, Merge Patch, Patch, JSONPath

## Goal

Make `sigil.path` real: JSON Pointer (RFC 6901), JSON Merge Patch (RFC 7386), JSON Patch
(RFC 6902) and a JSONPath subset (RFC 9535: name, index, wildcard, slice, descendant, filter),
all over `core.Value`, with no recursion and no allocation after setup. Afterwards zoltraak
can replace its `storage/jsonpath.zig` with `sigil.path` for `JSON.GET`, the Phase 2 consumer
proof of concept in `ROADMAP.md`. Ships as v0.4.0.

## Why now

Plan 004 closed 11/11 and v0.3.0 is tagged (first release). `sigil.json` reads and writes
`Value` trees, so the path layer has its input. ROADMAP Phase 2 names `JSON.GET` on
`sigil.path.jsonpath` as sigil's first consumer proof of concept. CI is green and no `bug` or
`directive` issue is open. 2D (direct-to-struct streaming) is a DOM bypass with no consumer
asking for it yet, so it waits.

## Scope

- [x] **ADR 0004 — path contract (design only, `architect`; return the file text, keep the
      scope tight).** Pins: (a) where results live: a `Value` is a borrowed view into a
      `ValueTree`, so Pointer `resolve` returns `?*const Value`, and mutating ops (Patch,
      Merge Patch) take the tree; (b) JSONPath result type: a caller-supplied bounded node
      list, `error.OutOfSpace` past it, plus `matches_max`; (c) mutation atomicity for Patch:
      validate all ops first, or apply to a copy; pick one and say what a failed op leaves
      behind; (d) one error vocabulary for the module, `TooDeep`/`OutOfMemory` shared with
      `core.Error`; (e) JSONPath conformance: which RFC 9535 features are in (functions
      `length`, `count`, `match`, `search`, `value`?) and what is rejected with a typed error;
      (f) path parse diagnostics reuse `core.Diagnostics` (byte column in the query string).
      Amends PRD 4.4. Verification: `docs/adr/0004-path-contract.md` exists.
- [x] **`path/pointer.zig`.** `parse` into a fixed segment list (`~0`/`~1` escapes, array
      index grammar with no leading zeros, `-` end marker), `resolve`, `format`. Tests: every
      RFC 6901 section 5 example; invalid escape, leading-zero index, index one past the
      end; model test against a naive splitter over 1,000 seeds.
- [x] **`path/merge.zig`.** `apply(tree, patch)` per RFC 7386 (`null` deletes, objects
      merge, anything else replaces) with an explicit bounded stack. Tests: the RFC appendix
      A table verbatim, depth `nesting_max` and one past (`TooDeep`), `check_invariants` of
      the result tree after every mutation.
- [x] **`path/patch.zig`.** `apply(tree, ops, diag)` (the target is `tree.root`) for `add`, `remove`, `replace`, `move`,
      `copy`, `test` over Pointer, with the atomicity ADR 0004 chose. Tests: RFC 6902
      appendix A (A.1-A.16) including the failing cases A.12-A.16; `move` into its own child
      is rejected; a failing allocator and a failing op leave the target as documented.
- [x] **`path/jsonpath.zig` — parse.** Query string into a bounded selector program
      (child name and index, wildcard, slice with negative steps, descendant segment);
      `segments_max` and `selectors_max` limits, typed `QueryTooLong`/`InvalidSyntax` errors
      with a column. Tests: valid and invalid grammar tables from RFC 9535 section 2, every
      error variant provoked, boundary at each `_max`.
- [x] **`path/jsonpath.zig` — evaluate.** `select(query, root, out)` with an explicit work
      stack (descendant traversal has no recursion), document order preserved, `out` bounded.
      Tests: RFC 9535 section 1.5 bookstore examples, empty result vs `OutOfSpace`,
      `nesting_max`-deep document, wildcard on empty array and object.
- [ ] **JSONPath filters.** `?` expressions: comparison (`==`, `!=`, `<`, `<=`, `>`, `>=`),
      `&&`, `||`, `!`, existence test, and the function set ADR 0004 admits; expression
      depth bounded by `filter_depth_max`. Tests: the RFC 9535 filter examples; comparison
      of int, uint and float follows `core.number` exactness (no silent int to float).
- [ ] **Conformance corpus.** Vendor the JSONPath compliance test suite (its license is
      checked and committed beside it, as JSONTestSuite was) and run it from `zig build
      test` with the pass, fail and pinned-unsupported counts asserted, never "no crash".
      Verification: suite counts printed by the test and recorded in the CHANGELOG.
- [ ] **Benchmarks.** `zig build bench` adds Pointer resolve, JSONPath `$..*` and a filter
      query over the plan 004 document; MB/s and ns per match recorded in
      `docs/plans/000-inherited.md`. Measure only; tuning is its own plan.
- [ ] **Release v0.4.0.** Tick 2E in `000-inherited.md`, CHANGELOG `[0.4.0]`, `build.zig.zon`
      and `sigil.version` 0.3.0 -> 0.4.0 in one PR, then tag and `gh release create`.
      Verification: `gh release view v0.4.0` succeeds.

## Out of scope

- 2D direct-to-struct streaming, TOML/YAML/MessagePack/CBOR/Proto/CSV, `config`.
- Replacing zoltraak's `jsonpath.zig`: that is a consumer plan in zoltraak (`/integrate`),
  opened after v0.4.0; a `migration` issue is filed then.
- JSON Schema and full RFC 9535 normalized-path output.

## Risks

- RFC 9535 is large; the function extensions and I-Regexp (`match`, `search`) may not fit a
  no-allocation matcher. ADR 0004 may defer them; the corpus pins them as unsupported.
- Patch atomicity: copy-on-apply costs memory, validate-first duplicates logic. The ADR picks
  one before code starts.
- A `Value` holds borrowed slices; `move`/`copy` must duplicate into the tree, not alias.
- The compliance suite is third-party data: license and size must be checked on vendoring
  (`git ls-files` count, `.gitignore` `test_*` pitfall from plan 004).

## Done when

- `zig build test`, `zig fmt --check` and CI are green; tidy reports 0 findings.
- Every RFC example for 6901, 7386, 6902 and the cited RFC 9535 sections passes.
- `gh release view v0.4.0 -R yusa-imit/sigil` succeeds; the plan 005 milestone issue is
  closed with all items ticked.

## Version impact

MINOR: v0.4.0. Additive (`sigil.path` becomes real, replacing its stub `Error` set).
No consumer pins sigil yet, so no `migration` issue is due at release time.

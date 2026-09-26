# Plan 002 — Phase 1A: core Value/ValueTree/Diagnostics

## Goal

Land the one real data structure every format module builds on: a `Value` union, an
arena-owned `ValueTree` that frees it as a unit, and a `Diagnostics{line, col, message}` type
every parser fills on failure. This is the first non-stub code in sigil — everything in
`docs/PRD.md` §4 sits on top of it.

## Why now

Plan 001 (Zig 0.16 + Tiger Style baseline) closed 11/11 with zero functional code; `core/` is
Phase 1A in both `docs/PRD.md` §4.1 and `docs/plans/000-inherited.md`, and every later item
(number handling, unicode, reflection, JSON) is blocked on `Value` existing. Landing it now
means the `tidy` assertion-baseline check (added in plan 001 item 9, currently 0/0 because no
real functions exist) finally has something to measure.

## Scope

- [ ] **`core/value.zig` — the `Value` union.** `null | bool | int: i64 | uint: u64 |
      float: f64 | string: []const u8 | bytes: []const u8 | timestamp: Timestamp | array:
      []Value | map: Map` per PRD §4.1. `Map` preserves insertion order (TOML/YAML round-trip
      requirement, `REALM.md`). No allocation in this file — `Value` itself is a plain union;
      `ValueTree` below owns memory. Tests: construction of every variant, `std.meta` exhaustive
      switch coverage, `Map` insertion-order preserved through get/put/iterate.
- [ ] **`core/tree.zig` — `ValueTree`.** `ValueTree{arena: std.heap.ArenaAllocator, root:
      Value}`, `init`/`deinit` (single `arena.deinit()` frees the whole tree), a `dupe`-style
      builder API for tests to construct trees without hand-rolling arena calls. Doc-comment the
      ownership contract at every function returning a `Value` or slice tied to the tree's
      lifetime (`REALM.md`'s DOM-ownership rule). Tests: arena release leaves no leaks under
      `std.testing.allocator` wrapping the arena's backing allocator; a tree built then `deinit`d
      is safe to drop (no double-free, no use-after-free caught by a `GeneralPurposeAllocator`
      safety build).
- [ ] **`core/diagnostics.zig` — `Diagnostics`.** `{line: u32, col: u32, message: []const u8,
      snippet: ?[]const u8}`, a `limits: struct { message_len_max: u32, snippet_len_max: u32 }`
      to bound the two slices (Tiger Style §1.7 "a limit on everything"), and a formatter
      (`format(self, w: *std.Io.Writer) !void`) that renders `line:col: message`. Tests: a
      message/snippet longer than the limit is truncated with an explicit marker, never silently
      dropped or overflowed; formatter output for a representative diagnostic.
- [ ] **`core/number.zig` — i64/u64/f64 boundary handling (Phase 1B, folded in).** Exact-integer
      preservation rules from `REALM.md` ("no silent int -> float coercion"): a `Number`
      wrapper or free functions deciding int-vs-uint-vs-float representation from source text
      shape (a `TOML`/`JSON` lexer's job upstream; this module only holds the decision logic and
      overflow errors). Tests: `i64::MAX`/`MIN`, `u64::MAX`, `-0` distinct from `0`, an
      integer literal one past `i64::MAX` returns a typed overflow error rather than silently
      becoming a float.
- [ ] **Wire into `root.zig` and `tidy`.** Replace `core.zig`'s stub body with re-exports of
      `core/{value,tree,diagnostics,number}.zig`; confirm the existing `wire_usize` and
      assertion-baseline `tidy` checks now scan real code (both were 0/0 findings against stub
      files; this item is done when the assertion-baseline count is nonzero and still green).

## Out of scope

- `core/unicode.zig` (Phase 1C) and `reflect/` (Phase 1D) — next plan, once `Value` is stable.
- Any format module (`json`, `toml`, ...) — Phase 2+, blocked on this plan.
- Benchmarks — `Value`/`ValueTree` are not yet exercised by anything hot enough to benchmark.

## Risks

- **`Map` insertion-order choice locks a representation other formats depend on.** Getting it
  wrong (e.g. plain `std.StringHashMap`, which does not preserve order) breaks the TOML/YAML
  round-trip guarantee before those modules even start. Mitigation: `architect` review of the
  `Map` shape before implementation; a round-trip-shaped test (put A, B, C; iterate; expect
  A, B, C) as the very first test written.
- **Arena-per-tree ownership is a one-way door once format modules build on it.** Mitigation:
  the DOM-ownership doc-comment rule from `REALM.md` is enforced at every function from this
  plan onward, not retrofitted later.
- **First real assertion-density code**: plan 001's baseline check has never measured actual
  logic. Mitigation: `zig-developer` targets 2+ assertions/function from the first line, not as
  a follow-up pass.

## Done when

- `zig build test` green with `core/value.zig`, `core/tree.zig`, `core/diagnostics.zig`,
  `core/number.zig` implemented (no `Error.NotImplemented` left in any of the four).
- `zig build tidy`'s assertion-baseline check reports a nonzero, green function count for
  `src/core/**`.
- A round-trip-shaped test proves `Map` preserves insertion order across put/iterate.
- `docs/plans/000-inherited.md` items 1A and 1B ticked.

## Version impact

MINOR (0.2.0 → 0.3.0) — first real public API surface (`sigil.core.Value` and friends) is
additive, no prior consumer to break. No tag this milestone either: `reflect` and every format
module still return `error.NotImplemented`, so the library remains unfetchable in practice;
tagging waits until at least one format module (JSON, Phase 2) is usable end to end.

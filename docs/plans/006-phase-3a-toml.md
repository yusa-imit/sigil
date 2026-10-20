# Plan 006 — Phase 3A: TOML 1.0 (lexer, parser, writer, toml-test)

## Goal

Make `sigil.toml` real: a TOML v1.0.0 lexer, parser and order-preserving writer over
`core.Value`, `toml.parse(T)` through `reflect`, the toml-test corpus run from `zig build test`
with counts asserted, and the parse -> stringify -> parse round-trip as a seeded property. No
recursion, no allocation after setup, every error at a line:col. Afterwards zr can replace its
~5.1k-line `parseToml` (ROADMAP Phase 3 structural debt, PRD 3C). Ships as v0.5.0.

## Why now

Plan 005 closed 10/10 (milestone #55) and v0.4.0 is tagged. CI is green; no `bug`, `directive`
or `migration` issue is open in sigil. ROADMAP Phase 3 names zr -> sigil (TOML/YAML) and the
`parseToml` function as debt; zr's REALM.md puts its TOML parser at 8.3k lines. TOML comes
before YAML (3B) because its grammar is closed and toml-test gives an exact oracle. 2D has no
consumer asking for it; 2F stays out except the TOML fuzz in item 10 (PRD §6: parsers fuzz).

## Scope

- [x] **ADR 0005 — TOML contract (design only, `architect`; return the file text).** Pins:
      (a) the four datetime kinds vs `core.Timestamp` (`seconds`, `nanoseconds`,
      `offset_minutes: ?i16`), which cannot tell a local date or local time from a local
      datetime, so round-trip fails without a change: a kind tag or another shape, and the
      leap-second and sub-nanosecond policy; (b) build strategy: `Map` capacity is fixed at
      `init` but TOML extends tables out of order, so a counting pass, or a scratch build then
      an exact arena copy; (c) the redefinition rules as one state per table (implicit,
      `[header]`, dotted, inline-frozen, array-of-tables) and their typed errors; (d) integers
      are i64 (spec), hex/octal/binary past i64 are `IntegerAboveMax`, writer refuses `uint`
      above i64 and `null`/`bytes` as `Unrepresentable`, as `json.writer` does; (e) limits:
      depth 128 (`core.value.nesting_max`) over arrays, inline tables and key segments, input
      `maxInt(u32)`; (f) public surface mirroring `json.zig` (`parse_value`, `parse`,
      `write_value`, `stringify`, options); (g) where the toml-test runner lives, so no
      `toml/` library file imports `json/` (test-only precedent: `path/conformance_test.zig`).
      Amends PRD §4.3 TOML row. Verification: `docs/adr/0005-toml-contract.md` exists.
- [x] **`core/timestamp.zig`.** The `Timestamp` change of ADR 0005 (a) plus RFC 3339 / TOML
      datetime parse and format (civil date <-> days, offsets, fraction digits). Shared in
      `core` because CBOR tag 0 needs the same text form and siblings may not share code.
      Tests: 0001-01-01 and 9999-12-31, Feb 29 in 2000 vs 1900, `2023-02-29` rejected,
      offsets +-23:59, 9 fraction digits; model test against a naive day counter, 1,000 seeds.
      `reflect` and `json.writer` keep compiling and passing (`zig build test`).
- [x] **`toml/lexer.zig` — structure and strings.** Pull lexer over one complete slice
      (ADR 0003 §1 shape): bare and quoted keys, `.`, `=`, `[`, `[[`, `,`, `{`, comments,
      newlines (LF, CRLF); basic, literal, multi-line strings with `\uXXXX`, `\UXXXXXXXX`,
      line-ending backslash; control characters rejected. Tests: every string example of the
      TOML 1.0.0 spec, each error variant provoked with its line:col, surrogate escape refused.
- [x] **`toml/lexer.zig` — scalars.** Integers (sign, `_` only between digits, `0x`/`0o`/`0b`,
      no leading zero) via `core.number` after stripping `_` into a bounded buffer; floats
      (exponent, `inf`, `nan`, signs); booleans; the four datetimes via `core/timestamp.zig`.
      Tests: spec integer/float/datetime tables, i64 min/max and one past (typed error, never
      float), `1__0`, `_1`, `01`, `0x_1` rejected.
- [ ] **`toml/parser.zig` — keys and tables.** Dotted keys, `[table]`, `[[array.of.tables]]`
      with the ADR 0005 (c) state machine; insertion order kept. Tests: every spec table and
      array-of-tables example; each redefinition error (table twice, dotted key into a
      `[header]` table, `[[a]]` after `a = []`, key reopening an inline table) with line:col;
      a header 128 segments deep passes, 129 is `TooDeep`; `check_invariants` on every map.
- [ ] **`toml/parser.zig` — arrays and inline tables.** Values on an explicit bounded stack
      (no recursion): mixed-type arrays (TOML 1.0), multi-line arrays with comments and a
      trailing comma, single-line inline tables frozen after close. Tests: spec examples,
      nesting at 128 and 129, `{ a = 1, }` and a newline inside `{}` rejected.
- [ ] **`toml.zig` facade and reflect.** The ADR 0005 (f) surface replaces the stub
      `Error = error{NotImplemented}` (ADR 0001: no tagged `NotImplemented`); `toml.parse(T)`
      runs `reflect.parse` over the tree, result slices doc-commented as tree-owned. Tests: a
      zr-shaped config struct (tables, arrays of tables, optionals, `core.Timestamp`), unknown
      field and type mismatch report the TOML line:col.
- [ ] **toml-test corpus.** Vendor the pinned toml-test release's TOML 1.0.0 valid and invalid
      cases with its license (MIT expected; check) and a `SOURCE` file, as `tests/jsonpath/`
      was. Run them from `zig build test`, valid compared against the tagged-JSON expectation
      (decoded per ADR 0005 (g)); assert the pass, reject and pinned-unsupported counts, never
      "no crash". Why careful: third-party bulk data; check size, and that `git ls-files`
      counts every file (the `.gitignore` `test_*` rule hid JSONTestSuite in plan 004).
      Verification: counts printed by the test and recorded in the CHANGELOG.
- [ ] **`toml/writer.zig`.** Order-preserving writer: scalars, `[table]` and `[[array]]`
      headers, inline form for maps inside arrays, keys quoted only when not bare, float always
      with `.`/exponent or `inf`/`nan`, timestamps per kind; `toml.stringify(T)`. Tests: every
      `Unrepresentable` case of ADR 0005 (d), a written spec example re-parses `eql`, root that
      is not a map refused.
- [ ] **Round-trip property and seeded mutation.** A seeded generator of TOML-representable
      `Value` trees (depth and width bounded): write -> parse -> `eql` over 1,000 seeds, and
      parse -> write -> parse over every valid corpus file (REALM rule). Seeded byte mutation
      of corpus files plus a `std.testing.fuzz` entry: each input gives a tree that passes
      `check_invariants` or a typed error with a position, never a panic. Verification:
      `zig build test`; seed count asserted.
- [ ] **Benchmarks.** `zig build bench` adds TOML parse over a seeded ~100 KB document (PRD §5
      target < 1 ms), `toml.parse(T)` and the writer; MB/s, ms and arena bytes per input byte
      recorded in `docs/plans/000-inherited.md`. Measure only; tuning is its own plan.
- [ ] **Release v0.5.0.** Tick 3A in `000-inherited.md`, CHANGELOG `[0.5.0]`, `build.zig.zon`
      and `sigil.version` 0.4.0 -> 0.5.0 in one PR, then tag and `gh release create`.
      Verification: `gh release view v0.5.0` succeeds.

## Out of scope

- YAML (3B), the zr migration (3C: a consumer plan in zr via `/integrate` after v0.5.0, with a
  `migration` issue filed then), 2D streaming-to-struct, JSON fuzz (rest of 2F).
- TOML 1.1 drafts (optional seconds, newlines in inline tables) and comment preservation (PRD:
  none in v1). A pull-event API for TOML: the lexer is public, an event parser is not.

## Risks

- `core.Timestamp` is public since v0.3.0; changing it touches `reflect` and `json.writer`.
  No sibling `build.zig.zon` pins sigil (checked 2026-10-19), so the cost is now, not later.
- Redefinition rules are the bulk of toml-test invalid cases; if the ADR state machine is
  wrong, items 5-6 grow. The corpus item pins any gap as unsupported with a reason, not skip.
- The fixed-capacity `Map` may force a second pass over the input; ADR 0005 (b) decides and
  the benchmark shows the price.
- toml-test expectations are JSON; decoding them must not make `toml/` import `json/`.

## Done when

- `zig build test`, `zig fmt --check src build.zig` and CI are green; tidy reports 0 findings.
- toml-test 1.0.0 counts are asserted in the test and printed in the CHANGELOG; round-trip
  property passes over 1,000 seeds and every valid corpus file.
- `gh release view v0.5.0 -R yusa-imit/sigil` succeeds; the plan 006 milestone issue is closed
  with all 12 items ticked.

## Version impact

MINOR: v0.5.0. `sigil.toml` becomes real (replacing its stub `Error` set). The `Timestamp`
change breaks shape, which VERSIONING.md allows in a foundation MINOR during `0.x`; CHANGELOG
"Changed" entry. No consumer pins sigil, so no `migration` issue is due at release time.

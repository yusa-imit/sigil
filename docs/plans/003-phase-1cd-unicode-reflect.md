# Plan 003 — Phase 1C/1D: unicode utilities and comptime reflection

## Goal

Finish Phase 1: land `core/unicode.zig` (the UTF-8 and escape primitives every text format
shares) and `reflect/{options,parse,stringify}.zig`, the comptime `T <-> Value` mapping of
`docs/PRD.md` §4.2. Afterwards a caller can turn a `Value` into a typed struct and back; turning
bytes into a `Value` stays Phase 2's job.

## Why now

Plan 002 (issue #20) closed 5/5: `Value`, `Map`, `ValueTree`, `Diagnostics` and `number` are
merged, which is the "once Value is stable" gate plan 002 set for this work. CI is green on
main and no `bug` or `directive` issue is open, so nothing outranks features. 1C goes first:
the JSON, TOML and YAML scanners all need one validator and one `\u` decoder, and `stringify`
needs the validator to refuse non-UTF-8 text. 1D is half of sigil's reason to exist (every
consumer in `REALM.md` loads configs into structs), and Phase 2D reuses its options table.

## Scope

- [ ] **`core/unicode.zig` — UTF-8 validation.** `find_invalid(bytes) ?Invalid` returns the
      byte offset and reason (overlong, surrogate, above U+10FFFF, truncated, stray
      continuation) so a parser can fill `Diagnostics.col`; the offset is `u32`, so a longer
      input is `error.InputTooLarge` (it is data, not a contract). Tests: every boundary of
      Unicode Table 3-7, plus a `std.testing.fuzz` differential test against
      `std.unicode.utf8ValidateSlice` whose seed corpus runs in `zig build test`.
- [ ] **`core/unicode.zig` — escape primitives.** Format-agnostic parts only: `encode` a
      codepoint into `*[4]u8`, `parse_hex4` plus surrogate-pair combining for `\uXXXX\uXXXX`
      (a lone surrogate is a typed error, never a silent U+FFFD), and `write_escaped(w:
      *std.Io.Writer, text, policy)`. Why no escape tables: JSON, TOML and YAML escape
      differently, so each format keeps its own table. Tests: surrogate edges (D7FF, D800,
      DBFF+DC00, DFFF, E000), `encode` then validate for all 0x110000 codepoints (bounded
      loop), writer output per policy.
- [ ] **ADR 0002 — reflect contract (design only, `architect`).** Pins the one-way doors
      before code: (a) hooks take `*ValueTree`, not a bare allocator, so hook results share the
      tree lifetime; `sigilStringify` returns a `Value` instead of writing bytes, since reflect
      never sees a writer; (b) `Value` has no source positions, so reflect errors put the key
      path (`tls.cert`) in the message and a documented "path only" `line`/`col` that the
      format layer upgrades in Phase 2; (c) int into float only when exact, float into int
      never, narrowing is `IntegerOutOfRange`; (d) tagged-union and `?T` null shape. PRD §4.2
      is amended in the same PR. Verification: `docs/adr/0002-reflect-contract.md` exists.
- [ ] **`reflect/options.zig`.** Reads `T.sigil_options` at comptime (`rename`, `rename_all`,
      `deny_unknown_fields`) into a comptime field table (Zig name, wire name, default). An
      unknown option key, a `rename` of a missing field, or two fields on one wire name is a
      `@compileError`, never a runtime surprise. Tests: resolved tables for sample structs;
      compile-error cases live in `tests/compile_errors/` and run as `zig build test` steps
      that invoke the compiler and expect the message.
- [ ] **`reflect/parse.zig` — scalars.** `parse(comptime T, tree: *ValueTree, value: Value,
      diag: *Diagnostics) Error!T` for `bool`, sized ints, floats, `[]const u8` (borrowed from
      the tree, not copied; lifetime doc-commented), enums from strings, `?T`. Typed errors
      (`TypeMismatch`, `IntegerOutOfRange`, `InexactNumber`, `UnknownEnumValue`) each fill
      `diag`. Tests: every int width at min, max and one past each, from `.int` and `.uint`;
      `2^53 + 1` into `f64` rejected; `3.0` into `u8` rejected.
- [ ] **`reflect/parse.zig` — structs and sequences.** Structs through the options table
      (defaults honored, `MissingField`, `UnknownField` under `deny_unknown_fields`), `[N]T`
      (`LengthMismatch`), `[]T` allocated once from the tree arena at exact `array.len`.
      Recursion carries a depth argument capped at `core.value.nesting_max` (`TooDeep`),
      because a type like `struct { children: []Node }` otherwise recurses on input data.
      Tests: PRD §4.2 `Config` on a hand-built `Value`; nested key path in the message; depth
      128 accepted, 129 `TooDeep`; no leaks under `std.testing.allocator`.
- [ ] **`reflect/parse.zig` — unions, string maps, hook.** Tagged unions per ADR 0002; an
      unmanaged, order-preserving string array hash map sized once to `map.count` (PRD names
      `std.StringHashMap`, which stores its allocator and loses order, breaking round-trip; the
      ADR records the swap); `sigilParse` dispatched when `T` declares it. Tests: each union
      variant, unknown tag, hook wins over the default mapping.
- [ ] **`reflect/stringify.zig`.** `stringify(comptime T, tree: *ValueTree, value: T)
      Error!Value`, the mirror of parse for every type above, honoring options and
      `sigilStringify`. `[]const u8` becomes `.string` only if valid UTF-8, else `InvalidUtf8`
      (never a silent `.bytes`); unsigned values above `maxInt(i64)` become `.uint`, all others
      `.int`, matching `number.parse_integer` so round-trips stay `eql`. Tests: per type,
      expected `Value` compared with `core.value.eql`.
- [ ] **Round-trip property test.** Seeded model-based test (`std.Random.DefaultPrng`, seed
      printed on failure): random instances of a fixed matrix covering every supported kind,
      nested 3 deep; `stringify`, `parse`, compare with the original, `stringify` again and
      compare the two `Value`s with `eql`. PRD §8 requires the type matrix; `REALM.md` makes
      round-trip a property. Verification: 1,000 seeds pass in `zig build test`.
- [ ] **Wire and close.** `reflect.zig` re-exports `options`/`parse`/`stringify`, `core.zig`
      re-exports `unicode`; both drop `error.NotImplemented`. Tick 1A-1D in
      `docs/plans/000-inherited.md` (1A/1B are still unticked, missed at plan 002's close).
      Verification: tidy's assertion baseline counts the new public functions, still green.

## Out of scope

- `sigil.parse(T, bytes)`/`json.parse(T, ...)`: needs a format; Phase 2 wraps `reflect.parse`.
- `reflect/schema.zig` (Phase 5B) and per-format escape tables (Phase 2-3).
- Benchmarks: PRD §5's reflect target (> 300 MB/s) is JSON into structs, measured in 2D.
- `tools/tidy.zig` self-exemption (1860 lines): a tooling theme, not this one. Not a
  showstopper, since every check still enforces on `src/`, and cycles 15-18 showed it does not
  fit one cycle. It gets its own plan or a full `/stabilize sigil` cycle.

## Risks

- **Hook signatures and "path only" diagnostics bind every format module.** Mitigation: ADR
  0002 is item 3 and lands before any reflect code; PRD §4.2 changes with it, not after.
- **Reflection recurses at runtime on recursive types.** Mitigation: an explicit depth bound
  at `nesting_max`, a documented Tiger Style trade-off with the precedent of PR #19.
- **Comptime cost (PRD §9).** The round-trip matrix instantiates every kind, so it doubles as
  the canary; a large jump in CI `zig build test` time means splitting instantiations.
- **`Map.get` is O(n)**, so struct parse is O(keys x fields). Fine for configs; revisit only
  if the 2D benchmarks say so.
- **0.16 std names** (hash maps, `std.Random`, fuzz API) may differ from older docs. Each item
  checks them against the 0.16.0 toolchain, not memory.

## Done when

- `zig build test` and `zig build tidy` green on main, CI 8/8.
- `grep -rn NotImplemented src/core.zig src/core src/reflect.zig src/reflect` prints nothing.
- `docs/adr/0002-reflect-contract.md` exists and `docs/PRD.md` §4.2 matches it.
- `grep -c '^- \[x\] 1[A-D]' docs/plans/000-inherited.md` prints `4`.
- The plan 003 milestone issue is closed with 10/10 ticked.

## Version impact

MINOR in semver terms (additive `sigil.core.unicode` and `sigil.reflect`, no consumer to break),
folded into the unreleased 0.3.0 that plan 002 started: `CHANGELOG.md` `[Unreleased]` grows,
no `build.zig.zon` bump, no tag. Decided on its own terms, not copied: `REALM.md`'s quirk
("no tag until Phase 1 lands") would allow a tag after this plan, but nothing yet turns bytes
into a `Value`, so no consumer can load a file; ROADMAP Phase 2 names core + reflect + JSON
as sigil's first deliverable; and 2D will likely reshape the reflect entry points. A tag now
would open `migration` issues for an API nobody can call. Tag with JSON 2A-2C.

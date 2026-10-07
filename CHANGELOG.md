# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions per
`citadel/protocol/VERSIONING.md` (MINOR may break during `0.x`).

## [Unreleased]

Plans 002 and 003 (Phase 1A-1D: `core/` and `reflect/`) are implemented; the first tag lands
with plan 004 (JSON).

### Added

- `docs/adr/0003-json-contract.md`: the JSON scanner, position, error, DOM-sizing, strictness
  and writer contract (plan 004 item 1); amends ADR 0001's json signatures and PRD §4.2/§4.3/§5.
- `core/value.zig`: the `Value` union, `Timestamp`, an insertion-ordered `Map` over a
  caller-supplied entry buffer (`put` returns `DuplicateKey`/`OutOfSpace`), and a structural
  `eql` with an explicit bounded stack (`nesting_max` = 128). Re-exported from `sigil.core`.
- `core/tree.zig`: `ValueTree`, the arena that owns a document's strings, bytes, arrays and
  map buffers, with `dupe_string`/`dupe_bytes`/`dupe_array`/`new_map`/`dupe_key` builders.
- `core/diagnostics.zig`: `Diagnostics{line, col, message, snippet}`, the position-carrying
  parse failure report every format module fills. `DiagnosticsType(comptime limits: Limits)`
  sizes fixed inline buffers at comptime (no allocation); input over a limit is truncated to
  exactly that limit with a `truncation_marker` appended, never silently dropped.
- `core/number.zig`: decimal literal text -> `Value` (`.int`/`.uint`/`.float`), exact, no
  silent int -> float coercion. `is_decimal_literal`/`classify` gate the grammar;
  `parse_integer` prefers `.int`, widens to `.uint` only past `maxInt(i64)`, and returns a
  typed `IntegerAboveMax`/`IntegerBelowMin` error only past `maxInt(u64)`/`minInt(i64)`;
  `parse_float` returns `FloatOutOfRange` on a finite literal that rounds to infinity, never a
  silent `inf`. Re-exported from `sigil.core`.
- `core/unicode.zig`: strict UTF-8 validation (`find_invalid`) per Unicode Table 3-7, reporting
  the byte offset and reason (`overlong`, `surrogate`, `above_max`, `truncated`,
  `stray_continuation`) of the first bad sequence; input over `maxInt(u32)` bytes is
  `InputTooLarge`. Re-exported from `sigil.core`.
- `core/unicode_escape.zig`: the format-agnostic escape primitives. `encode` (codepoint ->
  UTF-8, surrogates and > U+10FFFF are `InvalidCodepoint`), `parse_hex4` (`\uXXXX` digits),
  `decode_utf16` (surrogate-pair combining; a lone surrogate is `LoneSurrogate`, never U+FFFD),
  and `write_escaped` (`"`, `\\`, control escapes, and `\uXXXX` under the `ascii_only` policy;
  invalid UTF-8 is refused before anything is written). Re-exported from `sigil.core`.
- `reflect/options.zig`: `resolve(T)` turns a type's `pub const sigil_options` (`rename`,
  `rename_all`, `deny_unknown_fields`) into a comptime table of Zig name, wire name and default
  presence; `find_wire` looks a wire name up. Every misuse is a `@compileError`, checked by
  17 fixtures under `tests/compile_errors/`. Exposed as `sigil.reflect.options`.
- `reflect/context.zig` and `reflect/parse.zig`: `sigil.reflect.parse.parse(T, tree, value, diag)`
  for scalars (`bool`, sized ints, `f32`/`f64`, `[]const u8`, exhaustive enums, `?T`,
  `Timestamp`, `Value`), the `ParseError` set, the key `Path` and `Context` (`fail`,
  `parse_child`), and `core.diagnostics.position_none` for path-only messages.
- `reflect/parse.zig`: plain structs (through the options table: defaults, `MissingField`,
  `UnknownField` under `deny_unknown_fields`), `[N]T` (`LengthMismatch`) and `[]T`/`[]const T`
  (one arena allocation of exactly `array.len`). Entering a 129th nested container is
  `TooDeep`. Packed structs, tuples, `comptime` fields and sentinel slices or arrays are
  `@compileError`s.
- `reflect/parse.zig`: externally tagged unions (a void variant is its tag string, any other
  variant a one-entry map; `UnknownEnumValue` for an unknown tag), `std.array_hash_map.String(V)`
  maps (order-preserving, one arena reservation of `map.count`, borrowed keys), and the
  `sigilParse`/`sigilStringify` hook pair (same `Context`, so path and depth continue). An
  unpaired or mistyped hook and an untagged union are `@compileError`s.
- `reflect/stringify.zig`: `sigil.reflect.stringify.stringify(T, tree, value, diag)`, the mirror
  of `parse` for every supported type, options table and hook included. Signed integers are
  `.int`, unsigned ones `.int` up to `maxInt(i64)` and `.uint` above; a `[]const u8` or map key
  that is not UTF-8 is `InvalidUtf8`, never `.bytes`. Strings, arrays, maps and `Value` fields
  are copied into the tree. `Context.stringify_child` and `Context.fail_stringify` serve
  `sigilStringify` hooks; the 129th nested container is `TooDeep`.
- `reflect/roundtrip_test.zig`: a seeded property test (1,000 seeds) over a matrix of every
  supported kind nested several containers deep: `stringify` -> `parse` must equal the
  original and a second `stringify` must be `eql` to the first. A failure logs its seed.
- `core.Error`: the union `number.Error || unicode.Error || EscapeError || {TooDeep,
  OutOfMemory}`, replacing the `NotImplemented` placeholder; a comptime test pins its members.

### Fixed

- `bench/main.zig`: ported to Zig 0.16 (`process.Init`, `Io.Clock.awake`, `std.mem.find`); the
  harness is now compiled by `zig build test`, so it can no longer rot unnoticed.
- `tools/tidy.zig`: moved `tidy_baseline.txt` from the repo root to `tools/` — the root was
  outside `citadel/protocol/DOCS.md`'s allowed file list. `--baseline`'s default now points at
  `./tools/tidy_baseline.txt`; no behavior change for `zig build tidy`.
- `tools/tidy.zig`: the directory walk (`walkDir15`/`descendDir15`, `walkDir16`/`descendDir16`)
  was unbounded mutual recursion — a pathologically deep or symlink-cyclic tree would recurse
  without limit. Threaded a `depth: usize` through all four functions; past `dir_depth_max` (64)
  they now return `error.NestingTooDeep` instead of descending further (operating error, not
  caller error, so a typed return, not an assert). `std.Io.Dir.walkSelectively` (std's own
  explicit stack) was tried in place of hand-rolled recursion for the 16-path but crashed on
  Linux CI with a "file descriptor used after closed" panic inside std's own walker — reverted
  to bounded recursion; see `STATE.md` for the follow-up note.

## [0.2.0] — 2026-09-12

Plan 001: Zig 0.16.0 migration and Tiger Style baseline. No tag or GitHub release — the
library is still all stub modules (`REALM.md`'s release quirk: `zig fetch` today would hand a
consumer an empty package), so this bump is manifest- and changelog-only.

### Added

- `zig build tidy`: a machine-enforced Tiger Style lint step (line length, function length with
  a shrinking baseline ratchet, `catch unreachable` proof-comment requirement, banned 0.15 APIs,
  missing `//!` headers, `usize` in wire-format structs) — hard-gates `zig build test`.
- The kingdom's `io: Io` convention, settled here first as the spike other realms copy:
  `comptime T` in the receiver slot, `io` immediately after; `config.load`, `json.parseFile`/
  `stringifyFile` given their final signatures (`docs/adr/0001-io-convention.md`).
- An assertion baseline on `main.zig` and `root.zig`, plus a `tidy` check enforcing the
  two-assertions-per-function average kingdom-wide as real modules land.

### Changed

- Migrated to Zig 0.16.0 end to end: `main(init: std.process.Init)`, `std.Io.File` stdout,
  `minimum_zig_version = "0.16.0"`, CI resolves the toolchain from the manifest.
- CI restored the native macOS test job (cross-compile alone no longer stood in for it).

### Fixed

- Repo hygiene left over from the kingdom restructure (stale `docs/milestones.md` references,
  CI `paths-ignore`).
- README reconciled with reality: module table marked `Planned` throughout, Zig badge to
  `0.16.x`, no `zig fetch` pointed at a tag that was never cut.
- A `catch unreachable` in `tools/tidy.zig` missing its own `// proof:` comment.

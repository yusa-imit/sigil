# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions per
`citadel/protocol/VERSIONING.md` (MINOR may break during `0.x`).

## [Unreleased]

### Added

- `sigil.core.timestamp` (plan 006 item 2): proleptic Gregorian civil date <-> days and RFC 3339
  / TOML datetime `parse` and `format` for all four kinds, shared with future CBOR tag 0.
- `sigil.toml.lexer` (plan 006 item 3): a pull lexer for TOML structure, comments, keys and the
  four string forms (`Lexer.next` with `Mode` `.key`/`.value`, `decode_string`).
- `sigil.toml.scalar` (plan 006 item 4): `parse` classifies a lexer scalar run into a `Value`
  (booleans, `i64` integers incl. `0x`/`0o`/`0b`, floats, `inf`/`nan`, the four datetimes); the
  lexer now returns `date time` with one space as a single run.

### Changed

- `core.Timestamp` gains a required `kind` field (`instant`, `local_datetime`, `local_date`,
  `local_time`) and `check_invariants` (ADR 0005 section 2). Breaking for code that builds a
  `Timestamp` literal; allowed in a foundation MINOR during 0.x.

## [0.4.0] - 2026-10-19

Plan 005 (Phase 2E): `sigil.path` is real. JSON Pointer, Merge Patch, Patch and a JSONPath
subset (everything but `match`/`search`) over `Value`, with no recursion and no allocation after
setup.

### Added

- ADR 0004, the path contract (plan 005 item 1): borrowed read results, path-copy atomic Patch
  and Merge Patch, bounded JSONPath `compile`/`select`, one error vocabulary; amends PRD §4.4.
- `sigil.path.pointer` (plan 005 item 2): RFC 6901 `parse` into a caller-supplied segment
  buffer (`segments_max` 128, byte-column diagnostics), allocation-free `resolve` returning a
  borrowed `?*const Value`, `format`, `index_of`, `segment_eql`.
- `sigil.path.merge` (plan 005 item 3): RFC 7386 `apply(tree, patch)` by path copying and one
  `tree.root` swap, explicit bounded stack, `TooDeep` at `nesting_max`; the patch is deep-copied
  into the tree (internal `path/clone.zig`), so nothing aliases it. Appendix A passes verbatim.
- `sigil.path.patch` (plan 005 item 4): RFC 6902 `apply(tree, ops, diag)` for `add`, `remove`,
  `replace`, `move`, `copy`, `test`; each op rebuilds the spine, `tree.root` is assigned once
  after the last op, so any failure leaves the tree untouched; `PatchError` as in ADR 0004
  (`op <index>: <reason>` diagnostics). `copy`/`move` deep-copy their source, so a tree never
  holds a subtree twice. Appendix A (successes and failures) and a seeded model pass.
- `sigil.path.jsonpath` (plan 005 item 5): `compile(*Program, query, diag)` parses the RFC 9535
  grammar without filters into a fixed-size `Program` (names, indices, `*`, slices, `..`,
  selector lists); limits `segments_max` 32, `selectors_max` 64, `query_len_max` 1024; typed
  `QueryError` with byte-column diagnostics. Filters follow in item 7.
- `sigil.path.jsonpath.select` (plan 005 item 6): `select(program, root, out)` evaluates a
  `Program` with an explicit `nesting_max` frame stack (no recursion, no allocation), in document
  order with duplicates kept; results are pointers into the document, `OutOfSpace` one past
  `out.len`, `TooDeep` for a container nested past `nesting_max`. RFC 9535 section 1.5, 2.3 and
  2.5.2 examples and a seeded model against a level-by-level reference pass.
- JSONPath filters (plan 005 item 7): `?expr` with `== != < <= > >=`, `&&`, `||`, `!`,
  parentheses, existence tests of `@`/`$` queries, literals and `length`, `count`, `value`;
  numbers compare by exact value across `int`/`uint`/`float`, NaN never matches. New
  `QueryError` variants `FilterTooDeep`, `FilterTooLong`, `UnsupportedFunction` (`match`,
  `search`) and `UnknownFunction`; limits `filter_depth_max` 8, `filters_max` 32, `exprs_max`
  128, `queries_max` 32; embedded queries share one pool of `segments_max` segments and
  `selectors_max` selectors. `Selector` gains a `filter` variant (exhaustive switches over it
  need an arm). Container equality ignores map key order and compares numbers by value. RFC
  9535 section 2.3.5.3 examples pass verbatim.
- JSONPath conformance (plan 005 item 8): `path/conformance_test.zig` runs the vendored
  jsonpath-standard compliance suite (`tests/jsonpath/cts.json`, commit 20ebdcc, BSD-2 license
  and notice beside it). Counts, asserted: 715 tests (249 invalid, 466 valid), 659 pass, 56
  pinned unsupported (`match`/`search`, 24 + 32 tagged), 0 divergent.
- Path benchmarks (plan 005 item 9): `zig build bench` adds `path.pointer.resolve`,
  `path.jsonpath $..*` and `path.jsonpath filter` over the seeded ~1 MiB document, printing ns per
  match beside MB/s; numbers recorded in `docs/plans/000-inherited.md` (measured, not tuned).

### Removed

- `sigil.path.Error` (`error{NotImplemented}`), the stub set: each path file declares its own.

## [0.3.0] - 2026-10-14

Plan 004 (Phase 2A-2C, JSON) and the first tag. Plans 002 and 003 (Phase 1A-1D: `core/` and
`reflect/`) are included. A `zig fetch` now gives a consumer `Value`, reflection, and a working
JSON reader and writer; every other format module is still an empty stub.

### Removed

- `sigil.config.load`, `Watcher` and their option and error types: ADR 0001 forbids
  `error.NotImplemented` in a tagged API. Their final signatures stay in
  `docs/adr/0001-io-convention.md`; Phase 5 restores them with an implementation.

### Added

- JSON benchmarks (plan 004 item 10): `zig build bench` generates one seeded ~1 MiB document and
  prints MB/s for `json.dom.parse`, `json.write.minified` and `json.parse(T)` plus arena bytes
  per input byte; CI now runs the step. Numbers are recorded in `docs/plans/000-inherited.md`.
- `json.parseFile` and `json.stringifyFile` (plan 004 item 9, ADR 0003 section 9) in
  `json/file.zig`: both take `arena` and a final `diag`; `bytes_max` gives `InputTooLarge`
  (inclusive boundary); std's file errors are collapsed by hand into `FileNotFound`,
  `AccessDenied`, `ReadFailed`, `NoSpaceLeft`, `WriteFailed` plus passed-through `Canceled` and
  `OutOfMemory`. `stringifyFile` converts before it touches the file, then writes one trailing
  newline. The `root.zig` parity test now pins 7 parameters. `json.Error` lost `NotImplemented`
  and `scratch_bytes_min` is gone.
- `json.parse(T)`, `json.stringify`, `json.parse_value` and `json.write_value` (plan 004 item 8):
  the in-memory path is the DOM then `reflect.parse`, and `reflect.stringify` then the writer.
  A `reflect` failure is upgraded from a path to the source line:col by `scanner.locate`, which
  re-scans the input along the `reflect.Path` within `depth_max`. `raw_eql`, `parse_traced`
  and `Context.trace` carry the path; `json.StringifyOptions` is now the writer's.
- `json/scanner.zig`: the pull tokenizer over one complete slice (plan 004 item 2) with
  object/array structure, literals, RFC 8259 numbers, `depth_max` nesting and line:col
  diagnostics.
- `json/scanner.zig` strings (plan 004 item 3): `.key`/`.string` tokens are validated whole
  (strict UTF-8, no raw byte below 0x20, escape syntax, surrogate pairing) with the new
  `InvalidEscape`, `LoneSurrogate`, `ControlCharacter` and `InvalidUtf8` errors, plus
  `decode_string(raw, out)`, which cannot fail on a validated token. A seed-corpus differential
  fuzz against `std.json.validate` runs in `zig build test`.
- `json/dom.zig` (plan 004 item 4): `parse(tree, input, options, diag)` builds a `Value` in a
  `ValueTree` in two scans with no recursion, copying every string, keeping `i64`/`u64`/`f64`
  distinct through `core.number`, and applying the `reject`/`last` duplicate-key policy.
  `Map.index_of` is the new core primitive behind it.
- `json/suite_test.zig` and `tests/json/` (plan 004 item 7): the MIT-licensed JSONTestSuite
  corpus (318 files) vendored with its license. Every `y_` parses, every `n_` fails with a
  nonzero line:col, and the 35 `i_` outcomes are pinned.
- `json/roundtrip_test.zig` (plan 004 item 6): 1,000 seeded canonical `Value`s and the number
  edges survive write, `dom.parse` and `core.eql` in minified, pretty and `sort_keys` output.
- `json/writer.zig` (plan 004 item 5): `write(w, value, options, diag)` emits minified or pretty
  JSON with no recursion and no allocation, orders keys by byte with `sort_keys`, writes floats
  that always re-parse as floats, and refuses `.bytes`, `.timestamp`, NaN and infinity with an
  `Unrepresentable` key-path diagnostic. `reflect.context.write_diagnostic` is the public form of
  the path message `Context.fail` already rendered.
- `core.diagnostics.Position`, `position_of` and `snippet_of`: line:col in bytes and the
  failing line, computed from an offset only on failure.
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

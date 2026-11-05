# Plan 008 — Phase 4CD: CSV and Protobuf wire format

## Goal

Make `sigil.csv` and `sigil.proto` real. CSV (RFC 4180) reads into `core.Value` as an array of
records keyed by header and writes back, with header-to-struct mapping through `reflect`.
Protobuf gets a schema-less wire reader and writer plus a comptime struct mapping from a
`sigil_proto` field-number table. No recursion, no allocation after setup, no declared length
trusted, every error at a byte offset. Ships as v0.7.0.

## Why now

Plan 007 closed 11/11 (milestone #84) and v0.6.0 is tagged (2026-11-05). CI is green; no
`bug`, `directive` or `migration` issue and no PR is open in sigil. 4C and 4D are the two
closed grammars left in Phase 4 and finish it; YAML (3B) is the largest open grammar and
nobody is blocked on it, so it waits for its own plan. PRD 6D names `sigil.proto` or msgpack for
synod's message encoding: proto is the second candidate and a consumer plan needs both real.

## Scope

- [ ] **ADR 0007: CSV and proto contract (design only, `architect`; return the file text).**
      CSV: (a) RFC 4180 plus options without defaults (`delimiter`, `quote`, `header`
      present/absent, `line_ending` on write); (b) records to `array` of `object` keyed by
      header, every cell a `string` (no type guessing; reflect parses cells into field types);
      (c) ragged row, duplicate header, bare quote inside an unquoted field, EOF in a quoted
      field: typed errors at line:col; CRLF and LF accepted, lone CR refused; (d) limits:
      `fields_max`, `record_len_max`, `records_max`, input `maxInt(u32)`; (e) writer quotes on
      delimiter, quote, CR, LF, leading or trailing space; (f) non-`string` leaf values are
      `Unrepresentable` unless reflect formats them. Proto: (g) `Value` mapping of wire types
      (varint to `int`/`uint`, zigzag only for fields annotated `sint`, 64/32-bit to
      fixed-width or float per annotation, len to `string`/`bytes`/nested message); (h)
      `sigil_proto` table syntax, field numbers 1..2^29-1 (19000-19999 refused), repeated and
      packed fields, unknown fields skipped within limits and optionally kept; (i) groups
      (wire types 3/4) and varints over 10 bytes refused; last-wins for scalar repeats;
      (j) limits: depth 128, length checked against bytes left before allocating; (k) surface
      mirroring `msgpack.zig` (`parse_value`, `parse`, `write_value`, `stringify`); (l) runner
      layout for vectors. Amends PRD section 4.3 rows. Verification:
      `docs/adr/0007-csv-proto-contract.md` exists.
- [ ] **`csv/reader.zig`: scanner.** Pull scanner over one complete slice yielding fields and
      record ends; quoted cells with embedded delimiters, quotes (`""`) and newlines; u32
      offsets. Tests: empty input, one empty field, `a,,b`, trailing newline or none, CRLF,
      quoted newline, every ADR (c) error at its line:col, truncation at every byte of a sample.
- [ ] **`csv/reader.zig`: tree.** Count pass, then one exact-size arena build of records;
      header row optional per ADR; `check_invariants` on every result. Tests: ragged row,
      duplicate header, `records_max` and `fields_max` boundaries (n, n+1), 1 MiB cell,
      arena bytes linear in input bytes.
- [ ] **`csv/writer.zig`, `csv.zig` facade and header-to-struct reflect.** Writer per ADR (e),
      `parse(T)` mapping header names to fields of `[]T`, `stringify([]T)`; replaces the stub
      `Error = error{NotImplemented}` (ADR 0001). Tests: each quoting trigger, a struct with
      int, bool, optional and enum fields round-tripping, a missing and an extra column, a
      cell that fails to parse reported at its line:col, result slices doc-commented tree-owned.
- [ ] **CSV vectors, round-trip, mutation and fuzz.** Vendor a csv-spectrum subset (MIT) with
      `SOURCE` and license under `tests/csv/`; check `git ls-files` counts every file
      (`.gitignore` `test_*` hid a corpus in plan 004); assert pass, reject and pinned counts.
      Seeded generator of record trees (1,000 seeds): write -> parse -> `eql`, second write
      byte-identical; seeded byte mutation and a `std.testing.fuzz` entry. Reuse the plan 007
      harness shape in `core/binary_property.zig` only if it fits without a format import.
- [ ] **`proto/wire.zig`: reader.** Pull reader over one slice: tag decode, field number and
      wire type split, varint (10-byte cap, canonical and non-canonical accepted), 64/32-bit,
      length-delimited checked against the remainder, groups refused. Tests: the encoding
      guide examples (`08 96 01` is field 1 = 150), field number 0 and 2^29, reserved range,
      11-byte varint, truncation at every byte, `0a ffffffff0f` with 3 bytes left allocates 0.
- [ ] **`proto/wire.zig`: writer.** Tag, varint, zigzag, fixed widths and length prefix into a
      caller buffer, `OutOfSpace` on overflow, plus a size pass so `stringify` allocates once.
      Tests: every varint width boundary (2^7, 2^14, ... 2^63, 2^64-1), zigzag of
      `minInt`/`maxInt` for i32 and i64, writer bytes equal the reader's expectation.
- [ ] **`proto/reflect.zig`: struct mapping.** Comptime table from `sigil_proto`; scalars,
      strings, bytes, nested messages on an explicit `[nesting_max]Frame` stack, repeated
      fields (packed and unpacked read), unknown-field policy per ADR (h), missing fields take
      their struct default or `error.MissingField` at the message offset. Tests: a synod-shaped
      message (term, index, entries, payload bytes) round trip; a `@compileError` probe is
      documented, not run; duplicate field number rejected at comptime; depth 128 and 129.
- [ ] **Proto vectors, round-trip, mutation and fuzz.** Pin the official encoding-guide
      examples and a hand-built set from the wire spec in `tests/proto/` with `SOURCE`;
      seeded message generator (1,000 seeds) encode -> decode -> equal, second encode
      byte-identical; seeded byte mutation and a fuzz entry: a typed error with an offset or
      a valid message, never a panic, allocation linear in input bytes.
- [ ] **Benchmarks.** `zig build bench` adds CSV parse (1 MB, 8 columns), CSV write, proto
      decode and encode over one seeded message set; MB/s and arena bytes per input byte in
      `docs/plans/000-inherited.md`. Measure only; tuning is its own plan.
- [ ] **Release v0.7.0.** Tick 4C and 4D in `000-inherited.md`, CHANGELOG `[0.7.0]`,
      `build.zig.zon` and `sigil.version` 0.6.0 -> 0.7.0 in one PR, then tag and
      `gh release create`. Verification: `gh release view v0.7.0 -R yusa-imit/sigil` succeeds.

## Out of scope

- YAML (3B), config (Phase 5), 2D streaming-to-struct, JSON fuzz (rest of 2F), msgpack
  encode tuning, and the consumer migrations (6D is a synod plan via `/integrate`).
- `.proto` file parsing or code generation, proto3 JSON mapping, `Any`/`oneof` helpers,
  service definitions, groups, extensions, CSV dialect sniffing, encodings other than UTF-8,
  streaming from `std.Io.Reader`, and CSV formula-injection escaping (a consumer concern).

## Risks

- CSV cells are strings only; typed access lives in reflect. If cell parsing needs a reflect
  change shared with `json` and `toml`, ADR 0007 decides and the item tests every format.
- Proto without a schema file means field numbers live in Zig source; a wrong table is silent
  data loss. The comptime duplicate and range checks, and the unknown-field policy, carry that.
- csv-spectrum licensing and size must be checked before vendoring; fall back to a hand-built
  set recorded in `SOURCE` if it does not fit.
- Wire bytes become a stability surface at v0.7.0 (VERSIONING); record them in
  `memory/architecture.md` Formats.

## Done when

- `zig build test`, `zig fmt --check src build.zig` and CI are green; tidy reports 0 findings.
- Vector counts for both formats are asserted in tests and printed in the CHANGELOG; the
  round-trip property passes over 1,000 seeds per format.
- `gh release view v0.7.0 -R yusa-imit/sigil` succeeds; the plan 008 milestone issue is
  closed with all 11 items ticked.

## Version impact

MINOR: v0.7.0. `sigil.csv` and `sigil.proto` become real, replacing their stub `Error` sets.
A `core` or `reflect` change from ADR 0007 breaks shape, which VERSIONING.md allows in a
foundation MINOR during `0.x`; CHANGELOG "Changed" entry. No sibling `build.zig.zon` pins
sigil (checked at v0.6.0), so no `migration` issue is due at release.

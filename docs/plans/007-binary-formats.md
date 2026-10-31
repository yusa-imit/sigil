# Plan 007 — Phase 4AB: MessagePack and CBOR over core.Value

## Goal

Make `sigil.msgpack` and `sigil.cbor` real: a decoder and an encoder per format over
`core.Value`, `parse(T)`/`stringify(T)` through `reflect`, the official test vectors run from
`zig build test` with counts asserted, and encode -> decode as a seeded property. No recursion,
no allocation after setup, no declared length trusted, every error at a byte offset. CBOR gets
the RFC 8949 deterministic encoding as an option. Ships as v0.6.0.

## Why now

Plan 006 closed 12/12 (milestone #67) and v0.5.0 is tagged (2026-10-28). CI is green; no `bug`,
`directive` or `migration` issue and no PR is open in sigil. YAML (3B) is the largest and least
closed grammar left and nobody is blocked on it, so it waits; 3C is a zr consumer plan. PRD 6D
names msgpack (or proto) for synod's message encoding: that is the consumer. Both formats are
closed grammars with official vectors and raise the same questions (non-string map keys, int
width, tags/ext), so one ADR and one plan cover them.

## Scope

- [ ] **ADR 0006: binary-format contract (design only, `architect`; return the file text).**
      Pins for both formats: (a) `Value` mapping: non-negative ints to `int` up to
      `maxInt(i64)`, `uint` above; CBOR negatives past i64 are `IntegerBelowMin`; f16/f32 widen
      exactly; str/text valid UTF-8 (`core.unicode`); bin/bytes to `bytes`; (b) map keys are
      strings in `Value`, so other keys are a typed error, duplicates `reject`/`last` without
      `msgpack/` importing `json/`; (c) msgpack ext -1 to `instant` (null offset), other ext
      refused; CBOR tag 0 via `core/timestamp.zig`, tag 1 int/float (rounding stated), 2/3 to
      `uint`/`int` when they fit; other tags and simple values; (d) encoder: shortest int head,
      float width policy, NaN form, which `Timestamp` kinds are `Unrepresentable`; (e) limits:
      depth 128 (`core.value.nesting_max`, a tag is a level), input `maxInt(u32)`, and the bomb
      rule: a declared count or length is checked against the bytes left (1 per element, 2 per
      map entry) before allocating; (f) CBOR indefinite lengths: a counting first pass (ADR
      0003 section 4) or a typed refusal; (g) deterministic mode (RFC 8949 section 4.2.1):
      preferred serialization, definite lengths, keys by encoded bytes, no allocation;
      (h) positions: line 1, col = byte offset + 1 of the item's initial byte, no `Diagnostics`
      shape change; (i) surface mirroring `json.zig`/`toml.zig` (`parse_value`, `parse`,
      `write_value`, `stringify`, options without defaults), copy vs borrow of str/bin (PRD
      zero-copy), how a `[]const u8` field meets `.bytes` in `reflect`; (j) where the vector
      runners live (test-only, as `toml/conformance_test.zig`). Amends PRD section 4.3 rows.
      Verification: `docs/adr/0006-binary-contract.md` exists.
- [x] **`msgpack/decoder.zig`: reader.** Pull reader over one complete slice (ADR 0003
      section 1 shape): every format family, u32 offsets (tidy bans `usize` in `msgpack/`),
      declared lengths checked against the remainder. Tests: one case per first byte
      0x00-0xff incl. reserved 0xc1 (typed error at its offset), truncation at every byte of a
      sample, `0xdd ffffffff` with 5 bytes left refused with 0 bytes allocated.
- [x] **`msgpack/decoder.zig`: tree.** Containers on an explicit `[nesting_max]Frame` stack,
      each map sized from its header in one arena allocation; the ADR key, duplicate, ext and
      timestamp rules. Tests: depth 128 passes, 129 is `TooDeep`; `maxInt(i64)` and +1;
      timestamp 32/64/96 forms; non-string key at its offset; `check_invariants` on every map.
- [ ] **`msgpack/encoder.zig` and `msgpack.zig` facade.** Shortest-head writer per ADR (d) and
      the ADR (i) surface, replacing the stub `Error = error{NotImplemented}` (ADR 0001);
      result slices doc-commented as tree-owned. Tests: every `Unrepresentable` case, each width
      boundary (127/128, 255/256, 2^16, 2^32), a synod-shaped message struct through
      `stringify` -> `parse`, a type mismatch reported at its offset.
- [ ] **`cbor/decoder.zig`: reader.** Heads of major types 0-7, additional info 0-27,
      reserved 28-30 refused, indefinite lengths and `break` per ADR (f), f16, text checked as
      UTF-8. Tests: the RFC 8949 Appendix A items and each Appendix F not-well-formed class,
      every error at its offset.
- [ ] **`cbor/decoder.zig`: tree and tags.** The item 3 frame-stack build for CBOR plus tags
      0-3 and simple values per ADR (c). Tests: tag 0 at offsets +-23:59, tag 1 int and float,
      bignum 2^64-1 accepted and 2^64 refused, `-2^64` refused, 129 nested tags `TooDeep`.
- [ ] **`cbor/encoder.zig` and `cbor.zig` facade.** Preferred serialization, the ADR (g)
      deterministic option, the item 4 surface. Tests: Appendix A encodings byte-equal; two
      insertion orders of one map give identical deterministic bytes; shortest floats keep the
      value (f16 `1.5`, f32 `100000.0`, f64 `1.1`); one NaN encoding.
- [ ] **Official test vectors.** Vendor small subsets of msgpack-test-suite and the RFC 8949
      Appendix A vectors, each with its license and a `SOURCE` file, as `tests/toml-test/`
      was; run them from `zig build test` through the ADR (j) runners; assert pass, reject and
      pinned-unsupported counts, never "no crash". Why careful: third-party data; check
      licenses, size, and that `git ls-files` counts every file (`.gitignore` `test_*` hid
      JSONTestSuite in plan 004). Verification: counts printed by the test, in the CHANGELOG.
- [ ] **Round-trip property, mutation and fuzz.** Seeded generators of representable `Value`
      trees per format (depth and width bounded): encode -> decode -> `eql` over 1,000 seeds
      after the ADR (a) normalization, second encode byte-identical. Seeded byte mutation of the
      vectors plus a `std.testing.fuzz` entry per format (0.16 `Smith` API): a tree that passes
      `check_invariants` or a typed error with an offset, never a panic, arena bytes linear in
      input bytes. Verification: `zig build test`; seed counts asserted.
- [ ] **Benchmarks.** `zig build bench` adds msgpack and CBOR decode and encode over one seeded
      ~1 MB record tree (PRD section 5: msgpack encode > 1 GB/s); MB/s and arena bytes per input
      byte recorded in `docs/plans/000-inherited.md`. Measure only; tuning is its own plan.
- [ ] **Release v0.6.0.** Tick 4A and 4B in `000-inherited.md`, CHANGELOG `[0.6.0]`,
      `build.zig.zon` and `sigil.version` 0.5.0 -> 0.6.0 in one PR, then tag and
      `gh release create`. Verification: `gh release view v0.6.0` succeeds.

## Out of scope

- YAML (3B), proto (4C), CSV (4D), 2D streaming-to-struct, JSON fuzz (rest of 2F), and the
  synod migration (6D: a consumer plan in synod via `/integrate` after v0.6.0).
- Decoding from `std.Io.Reader`, file helpers, a `Value` ext variant, CBOR tags past 3,
  bignums past 64 bits, RFC 8746 typed arrays, RFC 8943 date tags.
- The open reflect note (a null optional is `Unrepresentable` in `toml.stringify`; omitting
  it would be a reflect option). msgpack and CBOR carry null natively, so it does not block
  this plan; it is asked as a question on the plan PR, not built here.

## Risks

- Reading a small `uint` back as `int` makes the round-trip hold modulo one normalization;
  ADR (a) must state it exactly, or the REALM numeric-exactness rule weakens unseen.
- CBOR indefinite lengths carry no count; a first pass doubles decode work (the benchmark
  shows it), a refusal pins Appendix A cases as unsupported.
- msgpack-test-suite is JSON-shaped; its runner stays test-only or `msgpack/` imports `json/`.
- If `reflect` must accept `.bytes` for `[]const u8`, `json` and `toml` change too; ADR (i)
  decides and item 4 tests every format. Deterministic CBOR bytes become a wire surface at
  v0.6.0 (VERSIONING); record them in `memory/architecture.md` Formats.

## Done when

- `zig build test`, `zig fmt --check src build.zig` and CI are green; tidy reports 0 findings.
- Vector counts for both formats are asserted in tests and printed in the CHANGELOG; the
  round-trip property passes over 1,000 seeds per format.
- `gh release view v0.6.0 -R yusa-imit/sigil` succeeds; the plan 007 milestone issue is closed
  with all 11 items ticked.

## Version impact

MINOR: v0.6.0. `sigil.msgpack` and `sigil.cbor` become real (replacing their stub `Error`
sets). A `core` or `reflect` change from ADR 0006 (b, i) breaks shape, which VERSIONING.md
allows in a foundation MINOR during `0.x`; CHANGELOG "Changed" entry. No sibling
`build.zig.zon` pins sigil (checked 2026-10-28), so no `migration` issue is due at release.

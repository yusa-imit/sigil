# Plan 004 — Phase 2A-2C: JSON scanner, DOM, writer, and the first tag

## Goal

Make sigil load and write real files: `json/scanner.zig` (pull tokenizer), `json/dom.zig`
(bytes into a `ValueTree`), `json/writer.zig` (minify/pretty), then `json.parse(T)`/`stringify`
over `reflect` and the ADR 0001 `parseFile`/`stringifyFile`. Afterwards a consumer can read a
JSON file into a typed struct with line:col diagnostics, and sigil ships its first tag, v0.3.0.

## Why now

Plan 003 (issue #27) closed 10/10: `core` and `reflect` are done, so Phase 1 has landed. CI is
green, no `bug` or `directive` issue is open. Nothing turns bytes into a `Value` yet, so no
consumer can use sigil; ROADMAP Phase 2 names core + reflect + JSON as sigil's first deliverable,
and JSON is the format every planned consumer (zoltraak, silica, zr) touches. 2D (direct-to-struct
streaming) and 2E (path) build on this scanner and DOM, so they wait.

## Scope

- [x] **ADR 0003 — JSON contract (design only, `architect`).** Pins what 2D-2F and every later
      text format copy: (a) scanner API over a complete slice, zero allocation, raw string slices
      plus a `has_escapes` flag, depth in a fixed bit stack with `depth_max <= nesting_max`
      asserted; (b) `u32` offsets, line:col computed from the offset only on failure, and the
      `col` unit (bytes or codepoints); (c) one error vocabulary (`TooDeep`, not the stub's
      `DepthExceeded`) and how `reflect.ParseError` folds in; (d) DOM sizing under PRD §5's
      "2x input" memory target, since `Map` needs its capacity up front (two-pass child counts
      vs a scratch stack); (e) strictness: BOM, top-level scalars, no extensions, integers
      past `u64` are errors, never floats; (f) `last` duplicate key on a fixed `Map`, sort_keys
      without allocation; (g) writer refuses `.bytes`, `.timestamp`, NaN/inf; floats always
      re-parse as `.float`; (h) `diag` joins `parseFile`, amending ADR 0001.
      Verification: `docs/adr/0003-json-contract.md` exists; PRD §4.3 JSON row matches it.
- [x] **`json/scanner.zig` — structure, literals, numbers.** `next()` yields object/array
      begin/end, `true`/`false`/`null`, and raw number text checked against RFC 8259 §6 (no
      leading zero, no `+`, no `.5`, no `1.`). Tests: each token kind; each number edge; depth
      128 accepted, 129 `TooDeep`; empty input, trailing data and truncation each fill `diag`
      with the right line:col on multi-line input.
- [ ] **`json/scanner.zig` — strings.** UTF-8 via `core.unicode.find_invalid`, raw controls
      below 0x20 rejected, escapes via `parse_hex4`/`decode_utf16` (a lone surrogate is a typed
      error), and `decode_string(raw, out)` into a caller buffer (`out.len >= raw.len` is
      enough, asserted). Tests: every escape, surrogate edges, bad UTF-8 at a known col, and a
      `std.testing.fuzz` differential against `std.json` accept/reject whose seed corpus runs
      in `zig build test`. Why: one oracle catches what hand-written cases miss.
- [ ] **`json/dom.zig`.** Bytes into a `ValueTree` per ADR 0003: no recursion (explicit stack
      bounded by `depth_max`), numbers through `core.number`, so i64/u64/f64 stay distinct, and
      the duplicate-key policy. Tests: `18446744073709551615` is `.uint`,
      `-9223372036854775808` is `.int`, `1e400` is `FloatOutOfRange`, each duplicate policy,
      no leak, and an OOM sweep with `std.testing.checkAllAllocationFailures`.
- [ ] **`json/writer.zig`.** `write(w: *std.Io.Writer, value, options, diag)`: minify, pretty
      with `indent_spaces`, `sort_keys`; escapes via `core.unicode_escape.write_escaped`;
      explicit stack bounded by `depth_max`; allocates nothing (ADR 0001). Tests: golden output
      per mode; floats `0.1`, `1.0`, `-0.0`, `5e-324`, `1e300`; each refused kind with its key
      path; `WriteFailed` from a full fixed writer.
- [ ] **Round-trip property test.** Seeded generator of canonical JSON-representable `Value`s
      (astral strings, number edges, nesting to 8); write minified and pretty, parse, compare
      with `eql`; seed logged via `std.log.err` on failure. Why: `REALM.md` makes round-trip a
      property, not a unit test. Verification: 1,000 seeds pass in `zig build test`.
- [ ] **JSONTestSuite.** Vendor the MIT-licensed `test_parsing/` cases under `tests/json/`
      with the license; every `y_` parses, every `n_` fails with a nonzero line:col, `i_`
      results are pinned so a change is visible. Why before a tag: the suite is the cheap,
      known catalog of the bugs a hand-written parser has. Verification: `zig build test`.
- [ ] **`json.parse(T)` and `json.stringify`.** In memory: DOM, then `reflect.parse`; and
      `reflect.stringify`, then the writer. Reflect's path-only diagnostic is upgraded to
      line:col by re-scanning the input along `reflect.Path` (bounded by `depth_max`), as
      ADR 0002 promised. Tests: PRD §4.2 `Config` from JSON text; a `TypeMismatch` at
      `servers[2].host` and an `UnknownField` each report the source line:col.
- [ ] **`parseFile`/`stringifyFile`.** Implement the ADR 0001 shapes over the item above with
      the hand-written I/O error mapping; `bytes_max` gives `InputTooLarge`; `json.zig` loses
      `|| Error`. Tests on `std.testing.tmpDir` with `std.testing.io`: file round trip,
      missing file, oversize file, malformed file with line:col; the `root.zig` parity test
      still passes.
- [ ] **Benchmarks.** Port `bench/main.zig` to 0.16 first: it still calls
      `GeneralPurposeAllocator`, `argsAlloc`, `std.fs` and `std.time.Timer`, and nothing builds
      it, so CI never noticed. Add a CI step that builds `bench`. Benchmarks: DOM parse, writer,
      `parse(T)` on a seeded 1 MiB document (no vendored twitter.json), plus arena bytes per
      input byte. Record MB/s in `docs/plans/000-inherited.md`. Verification: `zig build bench
      -Doptimize=ReleaseFast` prints all three.
- [ ] **Release v0.3.0.** ADR 0001 forbids `NotImplemented` in a tagged API, so drop the
      `config.load`/`Watcher` stubs (their signatures stay in ADR 0001; Phase 5 restores them).
      Tick 2A-2C in `000-inherited.md` and plan 003 item 4 (done in PR #31, box missed).
      `CHANGELOG.md` `[0.3.0]`, `build.zig.zon` 0.2.0 -> 0.3.0 in the same PR; after merge,
      `git tag -a v0.3.0` and `gh release create`. Verification: `gh release view v0.3.0`.

## Out of scope

- 2D direct-to-struct streaming (DOM bypass), 2E `path/*`, 2F long-running fuzz campaign.
- Incremental input (chunked feed); the scanner takes a complete slice per ADR 0003.
- Hitting PRD §5 throughput: this plan measures; tuning (SIMD, etc.) is its own plan.
- `tools/tidy.zig` self-exemption: still a tooling theme, carried as before.

## Risks

- **The scanner contract binds TOML/YAML and 2D.** Mitigation: ADR 0003 is item 1, before code.
- **Canonical numbers.** `.uint(5)` re-parses as `.int(5)` and `1.0` written as `1` comes back
  as `.int`. Mitigation: the writer forces `.0`/exponent on floats and the round-trip generator
  emits `.uint` only past `maxInt(i64)`, both stated in ADR 0003.
- **`Map.get` is O(n)**, so duplicate detection is O(n^2) per object. Tolerable for configs;
  the bench records it, and a hash index is a later plan if numbers say so.
- **`reflect.Path` may unwind before the format layer reads it.** Item 8 then adds a frozen
  copy at the first failure, an additive change to `Context`.
- **Oracle disagreement.** `std.json` may differ from RFC 8259 on edge cases; triage against
  the RFC and JSONTestSuite, not by assuming std is right.

## Done when

- `zig build test` and `zig build tidy` green on main, CI 8/8 (plus the new bench build step).
- `grep -rn 'return error.NotImplemented' src` prints nothing.
- `docs/adr/0003-json-contract.md` exists and `docs/PRD.md` §4.3 matches it.
- `grep -c '^- \[x\] 2[A-C]' docs/plans/000-inherited.md` prints `3`.
- `gh release view v0.3.0 -R yusa-imit/sigil` succeeds; the plan 004 milestone issue is
  closed with 11/11 ticked.

## Version impact

MINOR: v0.3.0, sigil's first tag. Additive (`sigil.json`), plus removals of stub-only API
(`json` stub errors, `config` stubs) that nothing calls, allowed for an untagged `0.x`
foundation. The `REALM.md` quirk ("no tag until Phase 1 lands") is now satisfied, and plan 003
deferred the tag to "JSON 2A-2C": after this plan a `zig fetch` gives a consumer a working JSON
reader and writer, which is the point of a tag. No `migration` issues: no consumer pins sigil
yet. Not later: 2D-2F are additive and ship as 0.4.0+; waiting on them buys nothing.

# sigil

> Marks that carry meaning — serialization and configuration formats for Zig

sigil은 하나의 `Value` 중간 표현과 comptime 리플렉션(struct ↔ Value) 위에 JSON(+JSONPath/Pointer/
Patch), TOML 1.0, MessagePack, CBOR을 제공한다. 모든 파서는 line:col 진단을 내고 시드 기반
속성 테스트와 공식 테스트 스위트로 검증된다. YAML 1.2 코어 서브셋, Protobuf 와이어 포맷, CSV,
파일+환경변수+CLI 인자를 병합하는 계층형 설정 로더는 아직 구현되지 않았다. zr의 TOML/YAML,
zoltraak의 JSON/JSONPath, silica의 JSON 타입, synod의 메시지 인코딩이 이 위로 이식될 계획이다.

[![CI](https://github.com/yusa-imit/sigil/workflows/CI/badge.svg)](https://github.com/yusa-imit/sigil/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status: `core`, `reflect`, `json`, `path`, `toml`, `msgpack` and `cbor` are implemented

`sigil.core`, `sigil.reflect`, `sigil.json`, `sigil.path`, `sigil.toml`, `sigil.msgpack` and
`sigil.cbor` are implemented and tested: parse and stringify between Zig types and `Value`, read
and write JSON, TOML 1.0, MessagePack and CBOR with line:col diagnostics (JSONTestSuite, toml-test,
RFC 8949 and msgpack-test-suite vectors, seeded round-trip and mutation properties), and query or
patch a `Value` with JSON Pointer, Merge Patch, Patch and JSONPath (the RFC 9535 compliance suite;
`match`/`search` are unsupported). Benchmarks are in `docs/plans/000-inherited.md`. Every other
module in the table below is an empty stub that declares only its error set; no YAML, Protobuf or
CSV can be read or written yet. `docs/PRD.md` has the full design. The API is unstable and may
change between 0.x minors.

## Modules

| Module | Status | Purpose |
|---|---|---|
| `sigil.core` | Implemented | Value union, arena-owned ValueTree, decimal Number parsing, Timestamp, Diagnostics (line:col), strict UTF-8 validation and escape primitives. |
| `sigil.reflect` | Implemented (`Schema(T)` planned) | comptime struct ↔ Value mapping: parse(T), stringify(T), field options (rename, defaults, deny_unknown), custom hooks. Schema(T) validation is not built yet. |
| `sigil.json` | Implemented | RFC 8259 strict pull scanner, DOM builder, minified/pretty writer, `parse(T)`/`stringify`, `parseFile`/`stringifyFile` with line:col diagnostics. Direct-to-struct streaming parse is not built yet. |
| `sigil.path` | Implemented | JSON Pointer (RFC 6901), JSONPath (RFC 9535 without `match`/`search`), JSON Patch (RFC 6902), Merge Patch (RFC 7386) — all over Value, no recursion, no allocation after setup. |
| `sigil.toml` | Implemented | TOML v1.0.0 lexer, parser, order-preserving writer; `parse`/`parse_value`, `stringify`/`write_value`; passes toml-test. |
| `sigil.yaml` | Planned | YAML 1.2 core-schema subset: block/flow collections, scalars, anchors/aliases (bounded), multi-doc. |
| `sigil.msgpack` | Implemented | MessagePack decoder and encoder: `parse`/`parse_value`, `stringify`/`write_value`, timestamp extension, shortest-form heads. |
| `sigil.cbor` | Implemented | CBOR (RFC 8949) decoder and encoder: `parse`/`parse_value`, `stringify`/`write_value`, tags, indefinite items, deterministic encoding option. |
| `sigil.proto` | Planned | Protobuf wire format (varint/64/len/32) with comptime field-number mapping — no schema compiler. |
| `sigil.csv` | Planned | RFC 4180 reader/writer, configurable delimiter/quote, header → struct mapping. |
| `sigil.config` | Planned | Layered config: defaults < files < env < args; schema validation; poll-based `Watcher`. The final `io: Io` signatures are in `docs/adr/0001-io-convention.md`; no code ships until Phase 5. |

## Install

The latest tag is v0.6.0. Fetch it with `zig fetch --save <release tarball URL>` from the
[releases page](https://github.com/yusa-imit/sigil/releases), then:

```zig
// build.zig
const sigil = b.dependency("sigil", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sigil", sigil.module("sigil"));
```

## Build

```bash
zig build            # library + CLI
zig build test       # unit tests
zig build bench      # benchmarks
zig build docs       # API docs → zig-out/docs
```

## Part of the Zig Kingdom

sigil is a planned foundation component of: zr, zoltraak, silica, synod. No consumer has
migrated yet — see [citadel](https://github.com/yusa-imit/citadel)'s `docs/KINGDOM.md` for the
full dependency map.

## License

MIT — see [LICENSE](LICENSE). Vendored test data under `tests/` keeps its own license
(`tests/json/LICENSE` MIT, `tests/jsonpath/LICENSE` BSD-2).

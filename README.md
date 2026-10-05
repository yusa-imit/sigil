# sigil

> Marks that carry meaning — serialization and configuration formats for Zig

sigil은 하나의 `Value` 중간 표현과 comptime 리플렉션(struct ↔ Value) 위에 JSON(+JSONPath/Pointer/Patch), TOML 1.0, YAML 1.2 코어 서브셋, MessagePack, CBOR, Protobuf 와이어 포맷, CSV를 제공하고, 파일+환경변수+CLI 인자를 병합하는 계층형 설정 로더를 포함할 예정이다. 모든 파서는 line:col 진단을 내고 fuzz로 검증될 예정이다. zr의 TOML/YAML, zoltraak의 JSON/JSONPath, silica의 JSON 타입, synod의 메시지 인코딩이 이 위로 이식될 계획이다.

[![CI](https://github.com/yusa-imit/sigil/workflows/CI/badge.svg)](https://github.com/yusa-imit/sigil/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status: Phase 1 done (`core`, `reflect`); every format module is still a stub

`sigil.core` and `sigil.reflect` are implemented and tested (parse and stringify between Zig
types and `Value`, with a seeded round-trip property test). Every other module in the table
below is a **signature stub**: it declares its planned public shape and error set, but its
entry points return `error.NotImplemented`. No format (JSON, TOML, ...) can be read or written
yet; JSON is next (`docs/plans/`). `docs/PRD.md` has the full design. The API is unstable and
may change before the first tag.

## Modules

| Module | Status | Purpose |
|---|---|---|
| `sigil.core` | Implemented | Value union, arena-owned ValueTree, decimal Number parsing, Timestamp, Diagnostics (line:col), strict UTF-8 validation and escape primitives. |
| `sigil.reflect` | Implemented (`Schema(T)` planned) | comptime struct ↔ Value mapping: parse(T), stringify(T), field options (rename, defaults, deny_unknown), custom hooks. Schema(T) validation is not built yet. |
| `sigil.json` | Planned (signature stub) | RFC 8259 pull scanner, DOM builder, pretty/minify writer, direct-to-struct streaming parse. `parseFile`/`stringifyFile` carry their final `io: Io` shape already — see `docs/adr/0001-io-convention.md`. |
| `sigil.path` | Planned | JSON Pointer (RFC 6901), JSONPath (RFC 9535 subset), JSON Patch (RFC 6902), Merge Patch (RFC 7386) — all over Value. |
| `sigil.toml` | Planned | TOML v1.0.0 lexer, parser, writer (order-preserving). toml-test suite. |
| `sigil.yaml` | Planned | YAML 1.2 core-schema subset: block/flow collections, scalars, anchors/aliases (bounded), multi-doc. |
| `sigil.msgpack` | Planned | MessagePack encoder/decoder, all types + ext, zero-copy bin/str. |
| `sigil.cbor` | Planned | CBOR (RFC 8949) core + tags 0–3, deterministic encoding option. |
| `sigil.proto` | Planned | Protobuf wire format (varint/64/len/32) with comptime field-number mapping — no schema compiler. |
| `sigil.csv` | Planned | RFC 4180 reader/writer, configurable delimiter/quote, header → struct mapping. |
| `sigil.config` | Planned (signature stub) | Layered config: defaults < files < env < args; schema validation; poll-based `Watcher`. `load`/`Watcher` carry their final `io: Io` shape already — see `docs/adr/0001-io-convention.md`. |

## Install

No tag has been cut yet — no format module exists, so a `zig fetch` today would hand you
`Value` and reflection with nothing to read or write. The first tag lands once `json` is real;
the snippet below is the shape consumers will use once a release exists:

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

MIT — see [LICENSE](LICENSE).

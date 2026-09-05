# sigil

> Marks that carry meaning — serialization and configuration formats for Zig

sigil은 하나의 `Value` 중간 표현과 comptime 리플렉션(struct ↔ Value) 위에 JSON(+JSONPath/Pointer/Patch), TOML 1.0, YAML 1.2 코어 서브셋, MessagePack, CBOR, Protobuf 와이어 포맷, CSV를 제공하고, 파일+환경변수+CLI 인자를 병합하는 계층형 설정 로더를 포함한다. 모든 파서는 line:col 진단을 내고 fuzz로 검증된다. zr의 TOML/YAML, zoltraak의 JSON/JSONPath, silica의 JSON 타입, sailor의 state_persist, synod의 메시지 인코딩이 이 위로 이식된다.

[![CI](https://github.com/yusa-imit/sigil/workflows/CI/badge.svg)](https://github.com/yusa-imit/sigil/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.x-orange.svg)](https://ziglang.org)

---

## Status

**Bootstrap** — API 설계 및 Phase 1 구현 중. 안정 릴리즈 전까지 API는 변경될 수 있다.

## Modules

| Module | Purpose |
|---|---|
| `sigil.core` | Value union, arena-owned ValueTree, Number parsing/formatting, Timestamp, Diagnostics (line:col), UTF-8/escape utils. |
| `sigil.reflect` | comptime struct ↔ Value mapping: parse(T), stringify(T), field options (rename, defaults, deny_unknown), custom hooks, Schema(T) validation. |
| `sigil.json` | RFC 8259 pull scanner, DOM builder, pretty/minify writer, direct-to-struct streaming parse. |
| `sigil.path` | JSON Pointer (RFC 6901), JSONPath (RFC 9535 subset), JSON Patch (RFC 6902), Merge Patch (RFC 7386) — all over Value. |
| `sigil.toml` | TOML v1.0.0 lexer, parser, writer (order-preserving). toml-test suite. |
| `sigil.yaml` | YAML 1.2 core-schema subset: block/flow collections, scalars, anchors/aliases (bounded), multi-doc. |
| `sigil.msgpack` | MessagePack encoder/decoder, all types + ext, zero-copy bin/str. |
| `sigil.cbor` | CBOR (RFC 8949) core + tags 0–3, deterministic encoding option. |
| `sigil.proto` | Protobuf wire format (varint/64/len/32) with comptime field-number mapping — no schema compiler. |
| `sigil.csv` | RFC 4180 reader/writer, configurable delimiter/quote, header → struct mapping. |
| `sigil.config` | Layered config: defaults < files < env < args; schema validation; change watch hook. |

## Install

```bash
zig fetch --save https://github.com/yusa-imit/sigil/archive/refs/tags/v0.1.0.tar.gz
```

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

sigil is a foundation component consumed by: zr, zoltraak, silica, sailor, synod.
See [citadel](https://github.com/yusa-imit/citadel) for the full map.

## License

MIT — see [LICENSE](LICENSE).

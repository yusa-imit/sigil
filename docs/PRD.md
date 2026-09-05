# sigil — Product Requirements Document

> **sigil**: 의미를 새긴 기호. Zig 왕국의 직렬화 & 설정 포맷 라이브러리.
> Layer: **Foundation** · Consumers: zr (TOML/YAML/JSON), zoltraak (JSON/JSONPath), silica (JSON 타입, 설정), synod (메시지 인코딩), sailor (state_persist)

---

## 1. 배경과 문제

zr은 TOML과 YAML 파서를 직접 갖고 있고 `std.json`을 15개 파일에서 쓴다. zoltraak는 `storage/{json_value,jsonpath}.zig`로 JSON 트리와 JSONPath를 구현했다. silica는 SQL JSON/JSONB 타입을 위해 또 다른 JSON 표현을 가진다. sailor는 `state_persist.zig`에서 자체 직렬화를 한다.

같은 "값 트리 ↔ 바이트" 문제를 네 번 풀고 있다. 포맷은 달라도 **중간 표현(Value)과 comptime 리플렉션(struct ↔ Value)** 은 하나면 된다.

## 2. 목표 (Goals)

1. **하나의 `Value` 중간 표현**: null/bool/int/float/string/bytes/array/map + 타임스탬프. 모든 포맷이 이 위에서 동작
2. **comptime 리플렉션**: `sigil.parse(T, bytes)`, `sigil.stringify(value)` — 구조체 필드 이름/타입/기본값/옵셔널을 컴파일 타임에 매핑. 커스텀 `sigilParse`/`sigilStringify` 훅
3. **포맷**: JSON(+JSONPath, JSON Patch, JSON Schema 서브셋), TOML 1.0, YAML 1.2 코어 서브셋, MessagePack, CBOR, Protobuf 와이어 포맷, CSV
4. **스트리밍**: 대용량을 위한 pull 파서(토큰 이벤트) — DOM 없이 처리 가능
5. **설정 계층화**: 파일(TOML/YAML/JSON) + 환경변수 + CLI 인자 → 하나의 타입된 Config. 핫 리로드 훅
6. **제로 의존성**, allocator-first, 파서는 fuzz 필수

## 3. 비목표 (Non-Goals)

- XML — 필요 시 v2
- 스키마 코드 생성기(protoc 플러그인) — 별도 도구
- ORM/DB 매핑 — silica 몫

## 4. 아키텍처

```
┌────────────────────────────────────────────────────────┐
│ config: Layered(file+env+args) · Watch · Validate      │
├────────────────────────────────────────────────────────┤
│ formats: json · toml · yaml · msgpack · cbor · proto · │
│          csv                                            │
│   each: Parser(pull) · Dom(→Value) · Writer(pretty/min) │
├────────────────────────────────────────────────────────┤
│ path: JsonPath · JsonPointer · JsonPatch · MergePatch   │
├────────────────────────────────────────────────────────┤
│ reflect: parse(T) · stringify(T) · FieldOptions ·       │
│          Schema(T) (validation)                         │
├────────────────────────────────────────────────────────┤
│ core: Value · ValueTree(arena) · Number · Timestamp ·   │
│       Diagnostics(line:col) · Escape/Unicode utils      │
└────────────────────────────────────────────────────────┘
```

### 4.1 `core.Value`

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,          // TOML/CBOR 무부호 보존
    float: f64,
    string: []const u8,
    bytes: []const u8,  // msgpack/cbor/proto 바이너리
    timestamp: Timestamp,  // TOML datetime, CBOR tag 0/1
    array: []Value,
    map: Map,           // 삽입 순서 보존 (TOML/YAML 라운드트립)
};
pub const ValueTree = struct { arena: ArenaAllocator, root: Value };  // 한 번에 해제
pub const Diagnostics = struct { line: u32, col: u32, message: []const u8, snippet: ?[]const u8 };
```

### 4.2 `reflect`

```zig
const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    tags: []const []const u8 = &.{},
    tls: ?struct { cert: []const u8, key: []const u8 } = null,

    pub const sigil_options = .{
        .rename = .{ .name = "server_name" },
        .rename_all = .snake_case,
        .deny_unknown_fields = true,
    };
};
var tree = try sigil.toml.parse(Config, allocator, src, &diag);   // ValueTree 소유
const cfg: Config = tree.value;
const out = try sigil.json.stringify(allocator, cfg, .{ .pretty = true });
```

- 지원: 정수/부동/bool/[]const u8/옵셔널/배열/슬라이스/구조체/enum(문자열)/tagged union/`std.StringHashMap`
- 기본값: 구조체 기본값 존중, 누락 필드는 `error.MissingField` + Diagnostics
- 커스텀: `pub fn sigilParse(allocator, Value, *Diagnostics) !T`, `pub fn sigilStringify(self, *Writer) !void`

### 4.3 포맷별 요구

| 포맷 | 파서 | 라이터 | 특이사항 |
|---|---|---|---|
| JSON | RFC 8259, pull + DOM | pretty/minify, 키 정렬 옵션 | 큰 정수 손실 없음(i64/u64/float 구분), 깊이 제한, 중복 키 정책 |
| TOML | v1.0.0 전체 | 주석 보존 없음(v1), 테이블 순서 보존 | 날짜/시간 4종, 인라인 테이블, 배열 테이블. toml-test 스위트 통과 |
| YAML | 1.2 코어 스키마 서브셋: 블록/플로우 매핑·시퀀스, 스칼라, 앵커/별칭, 멀티라인 | 블록 스타일 | 태그(!!) 미지원, 문서 스트림(`---`) 지원. 빌리언 러프 방어(별칭 확장 제한) |
| MessagePack | 전 타입, ext | | 스트리밍, 제로카피 bin/str |
| CBOR | RFC 8949 코어, 태그 0/1/2/3 | 결정론적 인코딩 옵션 | |
| Protobuf | 와이어 포맷(varint/64/len/32), 필드번호 comptime 매핑 | | 스키마 없이 comptime 구조체 어노테이션으로 인코딩. `sigil_proto = .{ .name = 1, .port = 2 }` |
| CSV | RFC 4180, 구분자/인용 설정 | | 헤더 → 구조체 필드 매핑 |

### 4.4 `path`
- JSONPath (RFC 9535 서브셋: 자식, 재귀, 와일드카드, 슬라이스, 필터 표현식) — zoltraak JSON.GET 요구
- JSON Pointer (RFC 6901), JSON Patch (RFC 6902), Merge Patch (RFC 7386)
- `Value` 위에서 동작하므로 TOML/YAML 트리에도 그대로 적용

### 4.5 `config`

```zig
var cfg = try sigil.config.load(AppConfig, allocator, .{
    .files = &.{ "/etc/app.toml", "~/.config/app.toml", "./app.toml" },  // 뒤가 우선
    .env_prefix = "APP_",          // APP_SERVER__PORT=9090 → server.port
    .args = std.os.argv,           // --server.port=9090
});
```
- 우선순위: defaults < files(순서) < env < args
- `sigil.config.watch(path, callback)` — 파일 변경 감지(polling/kqueue/inotify — sirocco 이후 이벤트 기반)
- 검증: `Schema(T)` — 범위, 정규식(간단), 필수 조건. Diagnostics로 "어느 파일 어느 줄"까지 보고

## 5. 성능 목표

| 지표 | 목표 |
|---|---|
| JSON 파싱 (DOM, 1MB, twitter.json) | > 500 MB/s |
| JSON 파싱 (reflect → struct) | > 300 MB/s |
| JSON 직렬화 | > 800 MB/s |
| TOML 파싱 (100KB) | < 1 ms |
| MessagePack 인코딩 | > 1 GB/s |
| 메모리 | DOM은 입력의 2× 이내 (아레나) |

## 6. 마일스톤

### Phase 1 — Core & Reflect
- 1A `core/value.zig`, `core/tree.zig`, `core/diagnostics.zig`
- 1B `core/number.zig` — 정확한 정수/부동 파싱(Eisel-Lemire는 std 활용), 포맷팅
- 1C `core/unicode.zig` — UTF-8 검증, 이스케이프
- 1D `reflect/parse.zig`, `reflect/stringify.zig`, `reflect/options.zig`

### Phase 2 — JSON
- 2A `json/scanner.zig` — pull 토크나이저
- 2B `json/dom.zig` — Value 빌더
- 2C `json/writer.zig` — pretty/minify
- 2D `json/reflect.zig` — 스트리밍 직접 구조체 파싱 (DOM 우회)
- 2E `path/{pointer,jsonpath,patch,merge}.zig`
- 2F JSON 파서 fuzz 캠페인, JSONTestSuite 통과

### Phase 3 — TOML & YAML
- 3A `toml/lexer.zig`, `toml/parser.zig`, `toml/writer.zig` — toml-test 통과
- 3B `yaml/scanner.zig`, `yaml/parser.zig`, `yaml/writer.zig`
- 3C zr의 TOML/YAML 파서를 sigil로 교체 (PoC 브랜치)

### Phase 4 — Binary Formats
- 4A `msgpack/{decoder,encoder}.zig`
- 4B `cbor/{decoder,encoder}.zig`
- 4C `proto/{wire,reflect}.zig`
- 4D `csv/{reader,writer}.zig`

### Phase 5 — Config
- 5A `config/layered.zig` — files/env/args 병합
- 5B `config/schema.zig` — 검증
- 5C `config/watch.zig` — 폴링 기반, sirocco 어댑터 훅

### Phase 6 — Integration
- 6A zoltraak JSON.* 명령을 `sigil.json` + `sigil.path`로 이식
- 6B silica JSON 타입 파싱을 sigil로
- 6C sailor state_persist를 `sigil.reflect`로
- 6D synod 메시지 인코딩을 `sigil.proto` 또는 `msgpack`으로

## 7. 설계 원칙

- **파서는 입력을 신뢰하지 않는다**: 깊이 제한(기본 128), 크기 제한, 별칭 확장 제한, 정수 오버플로 → 명시적 에러
- **진단이 1급**: 모든 파싱 에러는 line:col + 메시지. "어디가 틀렸는지" 없이 실패하지 않는다
- **아레나 소유권**: DOM은 `ValueTree`가 소유, 한 번에 해제. 리플렉션 결과는 트리 수명에 묶임
- **라운드트립**: TOML/YAML은 파싱 → 직렬화 → 파싱이 동일 Value (주석 제외)
- **`@panic` 금지**, `std.debug.print` 금지

## 8. 테스트 전략

- 공식 스위트: JSONTestSuite, toml-test, yaml-test-suite(서브셋), msgpack/CBOR 테스트 벡터
- fuzz: 모든 파서 `std.testing.fuzz` + 깊이/크기 폭탄
- 프로퍼티: 임의 Value → 직렬화 → 파싱 == 원본
- 리플렉션: 모든 지원 타입 조합 매트릭스

## 9. 리스크

| 리스크 | 완화 |
|---|---|
| YAML 전체 스펙은 늪 | 코어 서브셋 고정, 태그/복잡 키 명시적 미지원 |
| comptime 리플렉션 컴파일 시간 | 대형 구조체 벤치, 필요 시 lazy 인스턴스화 |
| zr 파서 교체 시 호환성 회귀 | zr 기존 테스트 전체를 sigil 백엔드로 실행 |

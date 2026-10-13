> Inherited roadmap, frozen at the kingdom restructure (2026-09-05). New work is planned in docs/plans/NNN-*.md via plan PRs (citadel/protocol/GITHUB.md).

# sigil — Milestones

> 마일스톤은 **이름(테마)** 으로 관리한다. 버전 번호는 릴리즈 시점에 `build.zig.zon` 현재 버전 + 1 로 결정한다.
> 상세 요구사항: `docs/PRD.md`. 진행 상황은 이 파일의 체크박스가 단일 진실이다.

## 현재 상태

- **Phase**: Bootstrap 완료 → Phase 1 착수
- **버전**: 0.1.0 (미릴리즈)
- **CI**: 초기 워크플로우 등록

## Phase 1 — Core & Reflect

- [x] 1A `core/{value,tree,diagnostics}.zig`
- [x] 1B `core/number.zig`
- [x] 1C `core/unicode.zig`
- [x] 1D `reflect/{parse,stringify,options}.zig`

## Phase 2 — JSON

- [ ] 2A `json/scanner.zig`
- [ ] 2B `json/dom.zig`
- [ ] 2C `json/writer.zig`
- [ ] 2D `json/reflect.zig` — streaming to struct
- [ ] 2E `path/{pointer,jsonpath,patch,merge}.zig`
- [ ] 2F fuzz + JSONTestSuite

## Phase 3 — TOML & YAML

- [ ] 3A `toml/{lexer,parser,writer}.zig` — toml-test
- [ ] 3B `yaml/{scanner,parser,writer}.zig`
- [ ] 3C zr TOML/YAML on sigil (PoC)

## Phase 4 — Binary Formats

- [ ] 4A `msgpack/`
- [ ] 4B `cbor/`
- [ ] 4C `proto/`
- [ ] 4D `csv/`

## Phase 5 — Config

- [ ] 5A `config/layered.zig` + env + args
- [ ] 5B `reflect/schema.zig` validation
- [ ] 5C `config/watch.zig`

## Phase 6 — Integration

- [ ] 6A zoltraak JSON.* on sigil
- [ ] 6B silica JSON type on sigil
- [ ] 6C sailor state_persist on sigil.reflect
- [ ] 6D synod message encoding on sigil


## 성능 목표

`docs/PRD.md` §5 참조. 각 Phase 완료 시 `zig build bench` 결과를 아래에 기록한다.

| 날짜 | 지표 | 측정값 | 목표 | 비고 |
|---|---|---|---|---|
| 2026-10-13 | JSON 파싱 (DOM, 1MB 생성 문서) | 약 145-175 MB/s | > 500 MB/s | `json.dom.parse`, arena 5.67 B/입력 B |
| 2026-10-13 | JSON 파싱 (reflect → struct) | 약 165 MB/s | > 300 MB/s | `json.parse(T)`, arena 5.67 B/입력 B |
| 2026-10-13 | JSON 직렬화 (minified) | 약 480-490 MB/s | > 800 MB/s | `json.write.minified` |

측정 조건: Apple Silicon 로컬, `zig build bench` (ReleaseFast), 시드 고정 약 1 MiB 생성 문서(twitter.json
아님), 16회 반복, 워밍업 1회 제외, 수 회 실행 중 근사 중앙값. 첫 벤치는 실행 순서에 따라 최대 약 20% 흔들린다. 목표 미달은 plan 004의
범위 밖이며(측정만 수행), 튜닝은 별도 plan에서 다룬다.

# sigil — Project Context

## Current State (2026-09-05)

- **Phase**: Bootstrap complete. Next: Phase 1 (see `docs/milestones.md`)
- **Version**: 0.1.0 (unreleased)
- **Build**: `zig build test` green on skeleton
- **CI**: workflow registered, first run pending

## Immediate Next Steps

- 1A: `Value`/`ValueTree`/`Diagnostics` — 테스트: 아레나 해제, 동등성, Map 삽입 순서 보존
- 1B: `Number` 파싱 — 테스트: i64/u64/f64 경계, `-0`, 지수, 오버플로 에러
- 2A: JSON 스캐너 — 테스트: 토큰 스트림, 깊이 제한, 이스케이프, fuzz 스텁

## Session Log

**Session 0 (2026-09-05) — Bootstrap**
- Repository scaffolded from `citadel/templates/repo` by `citadel/scripts/scaffold.py`
- PRD written (`docs/PRD.md`), milestones enumerated, agent/command definitions installed
- Module stubs compile; each module has a placeholder test

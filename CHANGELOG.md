# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions per
`citadel/protocol/VERSIONING.md` (MINOR may break during `0.x`).

## [Unreleased]

Nothing yet — plan 002 (Phase 1A: `core/{value,tree,diagnostics}.zig`) starts the first real
implementation work.

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

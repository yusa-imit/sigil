//! sigil.config — Layered config: defaults < files < env < args; schema validation; change
//! watching.
//!
//! Planned files (see docs/PRD.md):
//!   - `config/layered.zig`
//!   - `config/env.zig`
//!   - `config/args.zig`
//!   - `config/watch.zig`
//!
//! Status: stub. No public declarations until Phase 5. The final signatures of `load` and
//! `Watcher` are fixed by `docs/adr/0001-io-convention.md`; they are not compiled here because
//! a tagged API must not ship an entry point that returns `error.NotImplemented`.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "config: module compiles" {
    std.testing.refAllDecls(@This());
}

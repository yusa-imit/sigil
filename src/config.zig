//! sigil.config — Layered config: defaults < files < env < args; schema validation; change watch hook.
//!
//! Planned files (see docs/PRD.md):
//!   - `config/layered.zig`
//!   - `config/env.zig`
//!   - `config/args.zig`
//!   - `config/watch.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "config: module compiles" {
    std.testing.refAllDecls(@This());
}

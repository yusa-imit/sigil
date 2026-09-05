//! sigil.core — Value union, arena-owned ValueTree, Number parsing/formatting, Timestamp, Diagnostics (line:col), UTF-8/escape utils.
//!
//! Planned files (see docs/PRD.md):
//!   - `core/value.zig`
//!   - `core/tree.zig`
//!   - `core/number.zig`
//!   - `core/timestamp.zig`
//!   - `core/diagnostics.zig`
//!   - `core/unicode.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "core: module compiles" {
    std.testing.refAllDecls(@This());
}

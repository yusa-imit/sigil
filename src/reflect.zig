//! sigil.reflect — comptime struct ↔ Value mapping: parse(T), stringify(T), field options (rename, defaults, deny_unknown), custom hooks, Schema(T) validation.
//!
//! Planned files (see docs/PRD.md):
//!   - `reflect/parse.zig`
//!   - `reflect/stringify.zig`
//!   - `reflect/options.zig`
//!   - `reflect/schema.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "reflect: module compiles" {
    std.testing.refAllDecls(@This());
}

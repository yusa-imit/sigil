//! sigil.reflect — comptime struct ↔ Value mapping: parse(T), stringify(T), field options
//! (rename, defaults, deny_unknown), custom hooks, Schema(T) validation.
//!
//! Files (see docs/PRD.md and docs/adr/0002-reflect-contract.md):
//!   - `reflect/options.zig` — landed: `sigil_options` resolved at comptime into a field table
//!   - `reflect/parse.zig`, `reflect/stringify.zig`, `reflect/schema.zig` — planned
//!
//! Status: partial. Public declarations are added as plan 003 items land.

const std = @import("std");

pub const options = @import("reflect/options.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "reflect: module compiles" {
    std.testing.refAllDecls(@This());
}

//! sigil.core — Value union, arena-owned ValueTree, Number parsing/formatting, Timestamp,
//! Diagnostics (line:col), UTF-8/escape utils.
//!
//! Status: `value` and `tree` have landed (plan 002 items 1-2); the remaining files are
//! added as PRD phases land (see docs/PRD.md and docs/plans/).

const std = @import("std");

pub const value = @import("core/value.zig");
pub const Value = value.Value;
pub const Timestamp = value.Timestamp;
pub const Map = value.Map;
pub const tree = @import("core/tree.zig");
pub const ValueTree = tree.ValueTree;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "core: module compiles" {
    std.testing.refAllDecls(@This());
}

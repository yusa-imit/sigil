//! sigil.core — Value union, arena-owned ValueTree, Number parsing/formatting, Timestamp,
//! Diagnostics (line:col), UTF-8/escape utils.
//!
//! Status: `value`, `tree`, and `diagnostics` have landed (plan 002 items 1-3); the
//! remaining files are added as PRD phases land (see docs/PRD.md and docs/plans/).

const std = @import("std");

pub const value = @import("core/value.zig");
pub const Value = value.Value;
pub const Timestamp = value.Timestamp;
pub const Map = value.Map;
pub const tree = @import("core/tree.zig");
pub const ValueTree = tree.ValueTree;
pub const diagnostics = @import("core/diagnostics.zig");
pub const Diagnostics = diagnostics.Diagnostics;
pub const DiagnosticsType = diagnostics.DiagnosticsType;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "core: module compiles" {
    std.testing.refAllDecls(@This());
}

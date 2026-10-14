//! sigil.path — JSON Pointer (RFC 6901), JSONPath (RFC 9535 subset), JSON Patch (RFC 6902),
//! Merge Patch (RFC 7386) — all over Value (ADR 0004).
//!
//! Landed: `path/pointer.zig` (parse, resolve, format). Planned, one file per plan 005 item:
//!   - `path/merge.zig`
//!   - `path/patch.zig`
//!   - `path/jsonpath.zig`
//!
//! The stub `Error = error{NotImplemented}` is gone (ADR 0004 section 5): each file declares
//! its own typed error sets. `path` imports `core` only and never a format module.

const std = @import("std");

pub const pointer = @import("path/pointer.zig");

test "path: module compiles" {
    std.testing.refAllDecls(@This());
}

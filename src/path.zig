//! sigil.path — JSON Pointer (RFC 6901), JSONPath (RFC 9535 subset), JSON Patch (RFC 6902),
//! Merge Patch (RFC 7386) — all over Value (ADR 0004).
//!
//! Landed: `path/pointer.zig` (parse, resolve, format), `path/merge.zig` (RFC 7386, with the
//! internal `path/clone.zig`), `path/patch.zig` (RFC 6902), `path/jsonpath.zig` (query parsing),
//! `path/select.zig` (`jsonpath.select`; filters follow in plan 005 item 7).
//!
//! The stub `Error = error{NotImplemented}` is gone (ADR 0004 section 5): each file declares
//! its own typed error sets. `path` imports `core` only and never a format module (its
//! tests parse JSON fixtures through `json.dom`; no production code does).

const std = @import("std");

pub const pointer = @import("path/pointer.zig");
pub const merge = @import("path/merge.zig");
pub const patch = @import("path/patch.zig");
pub const jsonpath = @import("path/jsonpath.zig");

test "path: module compiles" {
    std.testing.refAllDecls(@This());
}

//! sigil.path — JSON Pointer (RFC 6901), JSONPath (RFC 9535 subset), JSON Patch (RFC 6902), Merge Patch (RFC 7386) — all over Value.
//!
//! Planned files (see docs/PRD.md):
//!   - `path/pointer.zig`
//!   - `path/jsonpath.zig`
//!   - `path/patch.zig`
//!   - `path/merge.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "path: module compiles" {
    std.testing.refAllDecls(@This());
}

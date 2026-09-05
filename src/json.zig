//! sigil.json — RFC 8259 pull scanner, DOM builder, pretty/minify writer, direct-to-struct streaming parse.
//!
//! Planned files (see docs/PRD.md):
//!   - `json/scanner.zig`
//!   - `json/dom.zig`
//!   - `json/writer.zig`
//!   - `json/reflect.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "json: module compiles" {
    std.testing.refAllDecls(@This());
}

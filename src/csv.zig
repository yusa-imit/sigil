//! sigil.csv — RFC 4180 reader/writer, configurable delimiter/quote, header → struct mapping.
//!
//! Planned files (see docs/PRD.md):
//!   - `csv/reader.zig`
//!   - `csv/writer.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "csv: module compiles" {
    std.testing.refAllDecls(@This());
}

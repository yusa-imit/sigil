//! sigil.toml — TOML v1.0.0 lexer, parser, writer (order-preserving). toml-test suite.
//!
//! Planned files (see docs/PRD.md):
//!   - `toml/lexer.zig`
//!   - `toml/parser.zig`
//!   - `toml/writer.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "toml: module compiles" {
    std.testing.refAllDecls(@This());
}

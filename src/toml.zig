//! sigil.toml — TOML v1.0.0 lexer, parser, writer (order-preserving). toml-test suite.
//!
//! Files (see docs/PRD.md and ADR 0005):
//!   - `toml/lexer.zig`, `toml/scalar.zig`: tokens and scalar classification (done)
//!   - `toml/scratch.zig`, `toml/parser.zig`: keys and tables (done); arrays and inline
//!     tables, then the `parse_value` facade (plan 006 items 6-7)
//!   - `toml/writer.zig`: planned
//!
//! Status: in progress. The module-level API lands with plan 006 item 7.

const std = @import("std");

pub const lexer = @import("toml/lexer.zig");
pub const scalar = @import("toml/scalar.zig");
pub const parser = @import("toml/parser.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test {
    _ = @import("toml/lexer_test.zig");
    _ = @import("toml/scalar_test.zig");
    _ = @import("toml/scratch_test.zig");
    _ = @import("toml/parser_test.zig");
    _ = @import("toml/parser_value_test.zig");
}

test "toml: module compiles" {
    std.testing.refAllDecls(@This());
}

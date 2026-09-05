//! sigil.proto — Protobuf wire format (varint/64/len/32) with comptime field-number mapping — no schema compiler.
//!
//! Planned files (see docs/PRD.md):
//!   - `proto/wire.zig`
//!   - `proto/reflect.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "proto: module compiles" {
    std.testing.refAllDecls(@This());
}

//! sigil.cbor — CBOR (RFC 8949) core + tags 0–3, deterministic encoding option.
//!
//! Planned files (see docs/PRD.md):
//!   - `cbor/decoder.zig`
//!   - `cbor/encoder.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

pub const decoder = @import("cbor/decoder.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "cbor: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("cbor/decoder_test.zig");
}

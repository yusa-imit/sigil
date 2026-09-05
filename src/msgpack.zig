//! sigil.msgpack — MessagePack encoder/decoder, all types + ext, zero-copy bin/str.
//!
//! Planned files (see docs/PRD.md):
//!   - `msgpack/decoder.zig`
//!   - `msgpack/encoder.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "msgpack: module compiles" {
    std.testing.refAllDecls(@This());
}

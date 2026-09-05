//! sigil.yaml — YAML 1.2 core-schema subset: block/flow collections, scalars, anchors/aliases (bounded), multi-doc.
//!
//! Planned files (see docs/PRD.md):
//!   - `yaml/scanner.zig`
//!   - `yaml/parser.zig`
//!   - `yaml/writer.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "yaml: module compiles" {
    std.testing.refAllDecls(@This());
}

//! sigil — Marks that carry meaning — serialization and configuration formats for Zig
//!
//! Library root. Consumers `@import("sigil")` and reach modules as
//! `sigil.<module>`. Every module is independent; import only what you use.
//!
//! See docs/PRD.md for the full design and docs/plans/ for milestone progress.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub const core = @import("core.zig");
pub const reflect = @import("reflect.zig");
pub const json = @import("json.zig");
pub const path = @import("path.zig");
pub const toml = @import("toml.zig");
pub const yaml = @import("yaml.zig");
pub const msgpack = @import("msgpack.zig");
pub const cbor = @import("cbor.zig");
pub const proto = @import("proto.zig");
pub const csv = @import("csv.zig");
pub const config = @import("config.zig");

test {
    std.testing.refAllDecls(@This());
}

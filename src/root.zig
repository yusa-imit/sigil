//! sigil — Marks that carry meaning — serialization and configuration formats for Zig
//!
//! Library root. Consumers `@import("sigil")` and reach modules as
//! `sigil.<module>`. Every module is independent; import only what you use.
//!
//! See docs/PRD.md for the full design and docs/plans/ for milestone progress.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

comptime {
    // REALM.md's release quirk: 0.x means "nothing shippable yet" (Phase 1
    // gates the first tag) — a major bump here is a deliberate release
    // decision, never an accidental edit.
    std.debug.assert(version.major == 0);
    // Kingdom convention: no pre-release/build metadata suffixes on a plain
    // semantic version.
    std.debug.assert(version.pre == null);
    std.debug.assert(version.build == null);
}

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

test "io convention: every format module puts `io` in the same parameter slot" {
    const formats = .{ json, toml, yaml, msgpack, cbor, proto, csv };
    inline for (formats) |module| {
        if (@hasDecl(module, "parseFile")) {
            const params = @typeInfo(@TypeOf(module.parseFile)).@"fn".params;
            try std.testing.expectEqual(@as(usize, 6), params.len);
            try std.testing.expectEqual(type, params[0].type.?);
            try std.testing.expectEqual(std.Io, params[1].type.?);
            try std.testing.expectEqual(std.mem.Allocator, params[2].type.?);
            try std.testing.expectEqual(std.Io.Dir, params[3].type.?);
            try std.testing.expectEqual([]const u8, params[4].type.?);
        }
        if (@hasDecl(module, "stringifyFile")) {
            const params = @typeInfo(@TypeOf(module.stringifyFile)).@"fn".params;
            try std.testing.expectEqual(@as(usize, 6), params.len);
            try std.testing.expectEqual(std.Io, params[0].type.?);
            try std.testing.expectEqual([]u8, params[1].type.?);
            try std.testing.expectEqual(std.Io.Dir, params[2].type.?);
            try std.testing.expectEqual([]const u8, params[3].type.?);
        }
    }
}

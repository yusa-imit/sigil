//! reflect/parse struct tests — structs (ADR 0002 sections 2, 3 and 5): field lookup through the
//! options table, defaults, `MissingField` and `UnknownField` in their pinned order, the exact
//! messages and the key paths. Arrays, slices, allocation and depth are in `parse_slice_test.zig`,
//! the seeded model and the fuzz run in `parse_model_test.zig`.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Context = context_mod.Context;
const Path = context_mod.Path;
const ParseError = context_mod.ParseError;
const parse = parse_mod.parse;
const parse_value = parse_mod.parse_value;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const nesting_max = core.value.nesting_max;
const Rig = rig_mod.Rig;
const Pair = rig_mod.Pair;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;
const expect_untouched = rig_mod.expect_untouched;
const Point = rig_mod.Point;
const Server = rig_mod.Server;
const Wrapper = rig_mod.Wrapper;
const Fleet = rig_mod.Fleet;
const Empty = rig_mod.Empty;

const Color = enum { red, green };
const Needs = struct { a: u8, b: ?u8 };
const Defaults = struct { a: u8, b: ?u8 = null };
const Lenient = struct {
    a: u8,
    pub const sigil_options = .{ .deny_unknown_fields = false };
};
const Kebab = struct {
    max_size: u32,
    io_mode: bool = false,
    pub const sigil_options = .{ .rename_all = .kebab_case };
};
const Renamed = struct {
    id: u32,
    label: []const u8 = "none",
    pub const sigil_options = .{ .rename = .{ .id = "ID" } };
};
const Outer = struct {
    inner_cfg: Kebab,
    pub const sigil_options = .{ .rename_all = .kebab_case };
};
const Mixed = struct { when: core.Timestamp, any: Value, color: Color };

test "struct: a map parses field by field, in any key order" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const forward = try rig.obj(&.{ kv("x", int(1)), kv("y", int(-2)) });
    try testing.expectEqual(Point{ .x = 1, .y = -2 }, try rig.ok(Point, forward));
    const reversed = try rig.obj(&.{ kv("y", .{ .uint = 7 }), kv("x", int(-9)) });
    try testing.expectEqual(Point{ .x = -9, .y = 7 }, try rig.ok(Point, reversed));
}

test "struct: every non-map value is a type mismatch naming its tag" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const stamp: core.Timestamp = .{ .seconds = 0, .nanoseconds = 0, .offset_minutes = null };
    try rig.mismatch(Point, .null, "map", "null");
    try rig.mismatch(Point, .{ .bool = true }, "map", "bool");
    try rig.mismatch(Point, int(1), "map", "int");
    try rig.mismatch(Point, .{ .uint = 1 }, "map", "uint");
    try rig.mismatch(Point, .{ .float = 1.5 }, "map", "float");
    try rig.mismatch(Point, str("x"), "map", "string");
    try rig.mismatch(Point, .{ .bytes = "x" }, "map", "bytes");
    try rig.mismatch(Point, .{ .timestamp = stamp }, "map", "timestamp");
    try rig.mismatch(Point, try rig.ints(&.{ 1, 2 }), "map", "array");
    try rig.mismatch(Empty, .null, "map", "null");
}

test "struct: arrays and slices reject every non-array value, naming its tag" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const empty_map = try rig.obj(&.{});
    inline for (.{ [3]u8, []const u32, []u32, [0]u8 }) |T| {
        try rig.mismatch(T, .null, "array", "null");
        try rig.mismatch(T, int(3), "array", "int");
        try rig.mismatch(T, str("abc"), "array", "string");
        try rig.mismatch(T, .{ .bytes = "abc" }, "array", "bytes");
        try rig.mismatch(T, empty_map, "array", "map");
    }
}

test "struct: an absent field takes its Zig default, a present one overrides it" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const bare = try rig.obj(&.{kv("host", str("a"))});
    const got = try rig.ok(Server, bare);
    try testing.expectEqualStrings("a", got.host);
    try testing.expectEqual(@as(u16, 8080), got.port);
    const full = try rig.obj(&.{ kv("port", int(1)), kv("host", str("b")) });
    try testing.expectEqual(@as(u16, 1), (try rig.ok(Server, full)).port);
}

test "struct: a field without a default that is absent is MissingField by wire name" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const port_only = try rig.obj(&.{kv("port", int(1))});
    try rig.fails(Server, port_only, error.MissingField, "missing field \"host\"");
    const none = try rig.obj(&.{});
    try rig.fails(Kebab, none, error.MissingField, "missing field \"max-size\"");
    try rig.fails(Renamed, none, error.MissingField, "missing field \"ID\"");
}

test "struct: MissingField reports the first absent field in declaration order" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.fails(Point, try rig.obj(&.{}), error.MissingField, "missing field \"x\"");
    const only_y = try rig.obj(&.{kv("y", int(1))});
    try rig.fails(Point, only_y, error.MissingField, "missing field \"x\"");
    const only_x = try rig.obj(&.{kv("x", int(1))});
    try rig.fails(Point, only_x, error.MissingField, "missing field \"y\"");
}

test "struct: MissingField carries the path of the struct that lacks the field" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const server = try rig.obj(&.{kv("port", int(1))});
    const wrapper = try rig.obj(&.{kv("server", server)});
    const message = "server: missing field \"host\"";
    try rig.fails(Wrapper, wrapper, error.MissingField, message);
    const servers = try rig.arr(&.{ try rig.obj(&.{kv("host", str("a"))}), server });
    const fleet = try rig.obj(&.{ kv("name", str("n")), kv("servers", servers) });
    try rig.fails(Fleet, fleet, error.MissingField, "servers[1]: missing field \"host\"");
}

test "struct: an optional field without a default is MissingField when absent" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const absent = try rig.obj(&.{kv("a", int(1))});
    try rig.fails(Needs, absent, error.MissingField, "missing field \"b\"");
    const explicit_null = try rig.obj(&.{ kv("a", int(1)), kv("b", .null) });
    try testing.expectEqual(Needs{ .a = 1, .b = null }, try rig.ok(Needs, explicit_null));
    const given = try rig.obj(&.{ kv("a", int(1)), kv("b", int(2)) });
    try testing.expectEqual(Needs{ .a = 1, .b = 2 }, try rig.ok(Needs, given));
}

test "struct: an optional field with a default is null when absent" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const absent = try rig.obj(&.{kv("a", int(1))});
    try testing.expectEqual(Defaults{ .a = 1, .b = null }, try rig.ok(Defaults, absent));
    const given = try rig.obj(&.{ kv("a", int(1)), kv("b", int(2)) });
    try testing.expectEqual(Defaults{ .a = 1, .b = 2 }, try rig.ok(Defaults, given));
}

test "struct: deny_unknown_fields is the default and names the key at the struct's path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const extra = try rig.obj(&.{ kv("x", int(1)), kv("y", int(2)), kv("z", int(3)) });
    try rig.fails(Point, extra, error.UnknownField, "unknown field \"z\"");
    const server = try rig.obj(&.{ kv("host", str("a")), kv("colour", str("red")) });
    const wrapper = try rig.obj(&.{kv("server", server)});
    try rig.fails(Wrapper, wrapper, error.UnknownField, "server: unknown field \"colour\"");
}

test "struct: a typo reports UnknownField before MissingField" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const typo = try rig.obj(&.{ kv("xx", int(1)), kv("y", int(2)) });
    try rig.fails(Point, typo, error.UnknownField, "unknown field \"xx\"");
    const port_typo = try rig.obj(&.{kv("hots", str("a"))});
    try rig.fails(Server, port_typo, error.UnknownField, "unknown field \"hots\"");
}

test "struct: unknown keys are checked in map order and before any field is parsed" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const two = try rig.obj(&.{ kv("zz", int(1)), kv("ww", int(2)) });
    try rig.fails(Point, two, error.UnknownField, "unknown field \"zz\"");
    const flipped = try rig.obj(&.{ kv("ww", int(2)), kv("zz", int(1)) });
    try rig.fails(Point, flipped, error.UnknownField, "unknown field \"ww\"");
    const bad_and_unknown = try rig.obj(&.{ kv("x", str("bad")), kv("z", int(1)) });
    try rig.fails(Point, bad_and_unknown, error.UnknownField, "unknown field \"z\"");
}

test "struct: an unknown key longer than the reason budget is cut with the truncation marker" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const long_key = "k" ** 200;
    const input = try rig.obj(&.{ kv("x", int(1)), kv("y", int(2)), kv(long_key, int(3)) });
    try testing.expectError(error.UnknownField, parse(Point, &rig.tree, input, &rig.diag));
    const message = rig.diag.message();
    try testing.expectEqual(@as(usize, context_mod.reason_len_max), message.len);
    try testing.expect(std.mem.startsWith(u8, message, "unknown field \"kkk"));
    try testing.expect(std.mem.endsWith(u8, message, core.diagnostics.truncation_marker));
}

test "struct: deny_unknown_fields = false ignores unknown keys but not missing fields" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const noisy = try rig.obj(&.{ kv("extra", .null), kv("a", int(5)), kv("more", int(1)) });
    try testing.expectEqual(Lenient{ .a = 5 }, try rig.ok(Lenient, noisy));
    const only_noise = try rig.obj(&.{kv("extra", int(1))});
    try rig.fails(Lenient, only_noise, error.MissingField, "missing field \"a\"");
    const bad = try rig.obj(&.{ kv("extra", int(1)), kv("a", str("s")) });
    try rig.fails(Lenient, bad, error.TypeMismatch, "a: expected integer, found string");
}

test "struct: rename and rename_all decide the wire names, the Zig names become unknown" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const kebab = try rig.obj(&.{ kv("io-mode", .{ .bool = true }), kv("max-size", int(64)) });
    try testing.expectEqual(Kebab{ .max_size = 64, .io_mode = true }, try rig.ok(Kebab, kebab));
    const renamed = try rig.obj(&.{ kv("ID", int(9)), kv("label", str("l")) });
    const got = try rig.ok(Renamed, renamed);
    try testing.expectEqual(@as(u32, 9), got.id);
    try testing.expectEqualStrings("l", got.label);
    const zig_name = try rig.obj(&.{kv("max_size", int(64))});
    try rig.fails(Kebab, zig_name, error.UnknownField, "unknown field \"max_size\"");
    const old_name = try rig.obj(&.{kv("id", int(9))});
    try rig.fails(Renamed, old_name, error.UnknownField, "unknown field \"id\"");
}

test "struct: the key path uses wire names" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const inner = try rig.obj(&.{kv("max-size", str("big"))});
    const outer = try rig.obj(&.{kv("inner-cfg", inner)});
    const message = "inner-cfg.max-size: expected integer, found string";
    try rig.fails(Outer, outer, error.TypeMismatch, message);
    const inner_missing = try rig.obj(&.{});
    const outer_missing = try rig.obj(&.{kv("inner-cfg", inner_missing)});
    const missing = "inner-cfg: missing field \"max-size\"";
    try rig.fails(Outer, outer_missing, error.MissingField, missing);
}

test "struct: a field error carries the key path, an element error the index" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const good = try rig.obj(&.{kv("host", str("a"))});
    const bad = try rig.obj(&.{kv("host", int(5))});
    const servers = try rig.arr(&.{ good, good, bad });
    const fleet = try rig.obj(&.{ kv("name", str("n")), kv("servers", servers) });
    const message = "servers[2].host: expected string, found int";
    try rig.fails(Fleet, fleet, error.TypeMismatch, message);
    const wide = try rig.obj(&.{ kv("x", .{ .int = 3_000_000_000 }), kv("y", int(0)) });
    try rig.fails(Point, wide, error.IntegerOutOfRange, "x: 3000000000 is out of range for i32");
}

test "struct: fields are filled in declaration order and the first failure is reported" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const both_bad = try rig.obj(&.{ kv("y", str("b")), kv("x", str("a")) });
    try rig.fails(Point, both_bad, error.TypeMismatch, "x: expected integer, found string");
    const y_bad = try rig.obj(&.{ kv("y", .null), kv("x", int(1)) });
    try rig.fails(Point, y_bad, error.TypeMismatch, "y: expected integer, found null");
}

test "struct: scalar, Value, Timestamp and enum fields parse in one struct" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const stamp: core.Timestamp = .{ .seconds = 5, .nanoseconds = 6, .offset_minutes = 60 };
    const input = try rig.obj(&.{
        kv("color", str("green")),
        kv("any", .null),
        kv("when", .{ .timestamp = stamp }),
    });
    const got = try rig.ok(Mixed, input);
    try testing.expectEqual(stamp, got.when);
    try testing.expectEqual(Color.green, got.color);
    try testing.expect(got.any == .null);
    const no_any = try rig.obj(&.{ kv("color", str("red")), kv("when", .{ .timestamp = stamp }) });
    try rig.fails(Mixed, no_any, error.MissingField, "missing field \"any\"");
    const when = Value{ .timestamp = stamp };
    const stamped = try rig.obj(&.{ kv("when", when), kv("any", .null), kv("color", str("teal")) });
    const message = "color: unknown " ++ @typeName(Color) ++ " \"teal\"";
    try rig.fails(Mixed, stamped, error.UnknownEnumValue, message);
}

test "struct: a bytes value is not a string field" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const input = try rig.obj(&.{kv("host", .{ .bytes = "ab" })});
    try rig.fails(Server, input, error.TypeMismatch, "host: expected string, found bytes");
}

test "struct: an empty struct takes an empty map and rejects any key" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try testing.expectEqual(Empty{}, try rig.ok(Empty, try rig.obj(&.{})));
    const one = try rig.obj(&.{kv("a", int(1))});
    try rig.fails(Empty, one, error.UnknownField, "unknown field \"a\"");
    const arr_one = try rig.arr(&.{try rig.obj(&.{kv("a", int(1))})});
    try rig.fails([1]Empty, arr_one, error.UnknownField, "[0]: unknown field \"a\"");
}

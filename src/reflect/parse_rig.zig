//! reflect/parse test rig — the shared fixture of the struct, array, slice and model tests of
//! `reflect/parse`: a `ValueTree` that owns the input and the output of one test, a sentinel
//! `Diagnostics`, and small `Value` builders. Test code only; `reflect` never imports it.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const ParseError = context_mod.ParseError;
const parse = parse_mod.parse;
const assert = std.debug.assert;
const testing = std.testing;
const position_none = core.diagnostics.position_none;

pub const Point = struct { x: i32, y: i32 };
pub const Server = struct { host: []const u8, port: u16 = 8080 };
pub const Wrapper = struct { server: Server };
pub const Fleet = struct { name: []const u8, servers: []const Server };
pub const Empty = struct {};

pub fn sentinel() Diagnostics {
    const diag = Diagnostics.init(7, 9, "untouched", null);
    assert(diag.line == 7 and diag.col == 9);
    assert(std.mem.eql(u8, diag.message(), "untouched"));
    return diag;
}

pub fn expect_untouched(diag: *const Diagnostics) !void {
    assert(diag.message().len <= core.diagnostics.default_limits.message_len_max);
    assert(diag.snippet_text() == null);
    try testing.expectEqual(@as(u32, 7), diag.line);
    try testing.expectEqual(@as(u32, 9), diag.col);
    try testing.expectEqualStrings("untouched", diag.message());
}

pub fn int(number: i64) Value {
    const value: Value = .{ .int = number };
    assert(value == .int);
    assert(value.int == number);
    return value;
}

pub fn str(text: []const u8) Value {
    const value: Value = .{ .string = text };
    assert(value == .string);
    assert(value.string.len == text.len);
    return value;
}

pub const Pair = struct { key: []const u8, value: Value };

pub fn kv(key: []const u8, value: Value) Pair {
    assert(key.len < std.math.maxInt(u32));
    const pair: Pair = .{ .key = key, .value = value };
    assert(pair.key.len == key.len);
    return pair;
}

/// A tree that owns the input and the output of one test, plus a sentinel diagnostics.
pub const Rig = struct {
    tree: ValueTree,
    diag: Diagnostics,

    pub fn init(rig: *Rig) void {
        rig.tree.init(testing.allocator);
        rig.diag = sentinel();
        assert(rig.tree.root == .null);
        assert(std.mem.eql(u8, rig.diag.message(), "untouched"));
    }

    pub fn deinit(rig: *Rig) void {
        assert(rig.diag.message().len <= core.diagnostics.default_limits.message_len_max);
        assert(@intFromPtr(rig) != 0);
        rig.tree.deinit();
    }

    pub fn obj(rig: *Rig, pairs: []const Pair) !Value {
        assert(pairs.len < std.math.maxInt(u32));
        var map = try rig.tree.new_map(@intCast(pairs.len));
        for (pairs) |pair| try map.put(try rig.tree.dupe_key(pair.key), pair.value);
        map.check_invariants();
        assert(map.count == pairs.len);
        return .{ .map = map };
    }

    pub fn arr(rig: *Rig, items: []const Value) !Value {
        const value = try rig.tree.dupe_array(items);
        assert(value == .array);
        assert(value.array.len == items.len);
        return value;
    }

    pub fn ints(rig: *Rig, numbers: []const i64) !Value {
        const items = try rig.tree.arena.allocator().alloc(Value, numbers.len);
        assert(items.len == numbers.len);
        for (numbers, items) |number, *item| item.* = int(number);
        assert(items.len == 0 or items[0] == .int);
        return .{ .array = items };
    }

    /// Parses `value` as `T`, which must succeed and leave the diagnostics untouched.
    pub fn ok(rig: *Rig, comptime T: type, value: Value) !T {
        assert(@intFromPtr(rig) != 0);
        rig.diag = sentinel();
        const got = try parse(T, &rig.tree, value, &rig.diag);
        try expect_untouched(&rig.diag);
        assert(rig.diag.line == 7);
        return got;
    }

    /// Expects `err` and a diagnostics of exactly `message` at `position_none`.
    pub fn fails(
        rig: *Rig,
        comptime T: type,
        value: Value,
        err: ParseError,
        message: []const u8,
    ) !void {
        assert(message.len > 0);
        assert(@intFromPtr(rig) != 0);
        rig.diag = sentinel();
        try testing.expectError(err, parse(T, &rig.tree, value, &rig.diag));
        try testing.expectEqualStrings(message, rig.diag.message());
        try testing.expectEqual(position_none, rig.diag.line);
        try testing.expectEqual(position_none, rig.diag.col);
        try testing.expect(rig.diag.snippet_text() == null);
    }

    /// `value` into `T` is `TypeMismatch`: "expected {kind}, found {tag}".
    pub fn mismatch(
        rig: *Rig,
        comptime T: type,
        value: Value,
        kind: []const u8,
        tag: []const u8,
    ) !void {
        assert(kind.len > 0);
        assert(tag.len > 0);
        var buf: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "expected {s}, found {s}", .{ kind, tag });
        try rig.fails(T, value, error.TypeMismatch, message);
    }
};

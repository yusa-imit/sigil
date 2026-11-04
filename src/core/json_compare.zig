//! Test-only comparator between a `std.json.Value` expectation and a decoded `core.Value`, for
//! the vendored vector suites of the binary formats (plan 007 item 8, ADR 0006 section 10). The
//! expectation is decoded with `std.json`, never `sigil.json`, so no format module imports a
//! sibling. Walks an explicit bounded stack; allocates nothing; the first mismatch ends it.
//!
//! Rules: JSON null/bool/string compare exactly; a JSON integer equals `.int`; an integer
//! beyond i64 (std.json keeps it as a digit string) equals `.uint` printed in decimal; a JSON
//! float equals `.float` bit for bit; arrays compare by length and element; an object equals a
//! map of the same count whose every key holds an equal value. `.bytes` and `.timestamp` never
//! match: the vector files that hold them are judged by their own runners.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const expect = std.testing.expect;

const Value = core.Value;

/// Pairs awaiting comparison; the vendored vectors are far shallower than this.
pub const pending_max: u32 = 256;

/// Pairs compared in total before `matches` gives up with false.
pub const pairs_max: u32 = 4096;

const Pair = struct { want: *const std.json.Value, got: *const Value };

/// True when `got` is the value `want` describes. Returns false, never asserts, on any
/// mismatch, including a structure deeper than `pending_max` pending pairs.
pub fn matches(want: *const std.json.Value, got: *const Value) bool {
    var pending: [pending_max]Pair = undefined;
    comptime assert(pending_max > 0);
    var len: u32 = 1;
    pending[0] = .{ .want = want, .got = got };
    for (0..pairs_max) |_| {
        if (len == 0) return true;
        len -= 1;
        const pair = pending[len];
        const pushed = compare_step(pair, pending[len..]) orelse return false;
        assert(pushed <= pending.len - len);
        len += pushed;
        assert(len <= pending.len);
    }
    return false;
}

/// Compares one pair; scalars end here, containers write their child pairs to `room` and
/// return how many. Null is a mismatch (including a full `room`).
fn compare_step(pair: Pair, room: []Pair) ?u32 {
    assert(room.len > 0);
    switch (pair.want.*) {
        .null => return if (pair.got.* == .null) 0 else null,
        .bool => |want| return if (pair.got.* == .bool and pair.got.bool == want) 0 else null,
        .integer => |want| return if (pair.got.* == .int and pair.got.int == want) 0 else null,
        .float => |want| {
            if (pair.got.* != .float) return null;
            return if (@as(u64, @bitCast(pair.got.float)) == @as(u64, @bitCast(want))) 0 else null;
        },
        .number_string => |text| return if (uint_matches(text, pair.got)) 0 else null,
        .string => |want| {
            if (pair.got.* != .string) return null;
            return if (std.mem.eql(u8, want, pair.got.string)) 0 else null;
        },
        .array => |want| return push_array(want.items, pair.got, room),
        .object => |want| return push_object(want, pair.got, room),
    }
}

fn uint_matches(text: []const u8, got: *const Value) bool {
    if (got.* != .uint) return false;
    var buffer: [20]u8 = undefined;
    const printed = std.fmt.bufPrint(&buffer, "{d}", .{got.uint}) catch return false;
    return std.mem.eql(u8, printed, text);
}

fn push_array(items: []const std.json.Value, got: *const Value, room: []Pair) ?u32 {
    if (got.* != .array) return null;
    if (got.array.len != items.len) return null;
    if (items.len > room.len) return null;
    for (items, 0..) |*item, index| {
        room[index] = .{ .want = item, .got = &got.array[index] };
    }
    return @intCast(items.len);
}

fn push_object(want: std.json.ObjectMap, got: *const Value, room: []Pair) ?u32 {
    if (got.* != .map) return null;
    if (got.map.count != want.count()) return null;
    if (want.count() > room.len) return null;
    var index: u32 = 0;
    for (want.keys(), want.values()) |key, *value| {
        const found = got.map.get(key) orelse return null;
        room[index] = .{ .want = value, .got = found };
        index += 1;
    }
    assert(index == want.count());
    return index;
}

fn probe(json_text: []const u8, got: Value) !bool {
    const gpa = std.testing.allocator;
    var decoded = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer decoded.deinit();

    return matches(&decoded.value, &got);
}

test "json_compare: scalars match exactly and nothing else" {
    try expect(try probe("null", .null));
    try expect(!try probe("null", .{ .bool = false }));
    try expect(try probe("true", .{ .bool = true }));
    try expect(!try probe("true", .{ .bool = false }));
    try expect(try probe("-7", .{ .int = -7 }));
    try expect(!try probe("-7", .{ .int = 7 }));
    try expect(!try probe("7", .{ .float = 7.0 }));
    try expect(try probe("1.5", .{ .float = 1.5 }));
    try expect(!try probe("1.5", .{ .int = 1 }));
    try expect(try probe("\"ab\"", .{ .string = "ab" }));
    try expect(!try probe("\"ab\"", .{ .string = "abc" }));
    try expect(!try probe("\"ab\"", .{ .bytes = "ab" }));
}

test "json_compare: an integer beyond i64 equals a uint of the same digits" {
    const max = std.math.maxInt(u64);
    try expect(try probe("18446744073709551615", .{ .uint = max }));
    try expect(!try probe("18446744073709551614", .{ .uint = max }));
    try expect(!try probe("18446744073709551615", .{ .int = -1 }));
}

test "json_compare: floats compare by bits, nesting works, limits end in false" {
    try expect(!try probe("0.0", .{ .float = -0.0 }));
    try expect(try probe("-0.0", .{ .float = -0.0 }));
    try expect(!try probe("18446744073709551615", .{ .int = 5 }));
    try expect(!try probe("1", .{ .timestamp = .{
        .kind = .instant,
        .seconds = 1,
        .nanoseconds = 0,
        .offset_minutes = null,
    } }));

    var inner: [1]core.value.Map.Entry = undefined;
    var inner_map = core.value.Map.init(&inner);
    try inner_map.put("k", .{ .bool = true });
    const items = [_]Value{ .{ .map = inner_map }, .null };
    var outer: [1]core.value.Map.Entry = undefined;
    var outer_map = core.value.Map.init(&outer);
    try outer_map.put("list", .{ .array = &items });
    try expect(try probe("{\"list\":[{\"k\":true},null]}", .{ .map = outer_map }));
    try expect(!try probe("{\"list\":[{\"k\":false},null]}", .{ .map = outer_map }));

    const wide = [_]Value{.null} ** (pending_max + 1);
    const text = "[" ++ "null," ** pending_max ++ "null]";
    try expect(!try probe(text, .{ .array = &wide }));
}

test "json_compare: arrays and maps compare by shape and content" {
    const items = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };
    try expect(try probe("[1,\"x\"]", .{ .array = &items }));
    try expect(!try probe("[1,\"y\"]", .{ .array = &items }));
    try expect(!try probe("[1]", .{ .array = &items }));
    try expect(!try probe("[1,\"x\"]", .{ .int = 1 }));

    var entries: [2]core.value.Map.Entry = undefined;
    var map = core.value.Map.init(&entries);
    try map.put("a", .{ .int = 1 });
    try map.put("b", .null);
    try expect(try probe("{\"b\":null,\"a\":1}", .{ .map = map }));
    try expect(!try probe("{\"a\":1}", .{ .map = map }));
    try expect(!try probe("{\"a\":1,\"c\":null}", .{ .map = map }));
    try expect(!try probe("{\"a\":2,\"b\":null}", .{ .map = map }));
}

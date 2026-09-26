//! core/value — the `Value` union every sigil format parses into and stringifies from.
//!
//! Invariants: `Map` keeps insertion order and never holds a duplicate key
//! (`Map.check_invariants`). Allocation contract: this file never allocates. A `Map` writes
//! into an entry buffer the caller supplies; `ValueTree` (core/tree.zig) owns that memory.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum container nesting `eql` walks; matches the parsers' default depth limit
/// (REALM.md: "default depth limit 128"), so any tree a parser built fits.
pub const nesting_max: u32 = 128;

/// A dynamically typed document node. Plain data: slices point into memory owned by a
/// `ValueTree` arena (core/tree.zig), never freed individually.
pub const Value = union(enum) {
    null,
    bool: bool,
    /// Signed integers stay distinct from `uint` and `float`; no silent coercion.
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    timestamp: Timestamp,
    array: []const Value,
    map: Map,
};

/// A point in time: TOML datetime, CBOR tag 0/1.
pub const Timestamp = struct {
    /// Seconds since the Unix epoch, UTC.
    seconds: i64,
    /// Sub-second part, `0..999_999_999` inclusive.
    nanoseconds: u32,
    /// UTC offset in minutes, or null for a local (offset-less) time.
    offset_minutes: ?i16,
};

/// An insertion-ordered string-keyed map over a caller-supplied entry buffer.
/// Lookup is a linear scan: format maps are small, and order is the contract (TOML/YAML
/// round-trip), which a hash map would not keep.
pub const Map = struct {
    /// The full buffer; `entries[0..count]` are live.
    entries: []Entry,
    count: u32,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    /// `buffer` is the capacity and stays owned by the caller (normally a `ValueTree` arena).
    pub fn init(buffer: []Entry) Map {
        assert(buffer.len <= std.math.maxInt(u32));
        const map: Map = .{ .entries = buffer, .count = 0 };
        assert(map.items().len == 0);
        return map;
    }

    /// Appends `key`, keeping insertion order. `key` must outlive the map.
    /// Precondition: the map came from `init` (`count <= entries.len`).
    pub fn put(map: *Map, key: []const u8, value: Value) error{ DuplicateKey, OutOfSpace }!void {
        assert(map.count <= map.entries.len);

        // Duplicate scan is O(n) via `get`; full `check_invariants` is O(n^2), so callers and
        // tests run it explicitly rather than on every put.
        if (map.get(key) != null) return error.DuplicateKey;
        if (map.count == map.entries.len) return error.OutOfSpace;
        const count_before = map.count;
        map.entries[map.count] = .{ .key = key, .value = value };
        map.count += 1;
        assert(map.count == count_before + 1);
        assert(map.get(key) != null);
    }

    /// Returns the value stored under `key`, or null. Points into the map's buffer.
    pub fn get(map: *const Map, key: []const u8) ?*const Value {
        assert(map.count <= map.entries.len);
        for (map.items()) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                assert(entry.key.len == key.len);
                return &entry.value;
            }
        }
        return null;
    }

    /// The live entries in insertion order.
    pub fn items(map: *const Map) []const Entry {
        assert(map.count <= map.entries.len);
        const live = map.entries[0..map.count];
        assert(live.len == map.count);
        return live;
    }

    /// Asserts `count` is within capacity and no two live keys are equal.
    pub fn check_invariants(map: *const Map) void {
        assert(map.count <= map.entries.len);
        const live = map.items();
        for (live, 0..) |entry, index| {
            for (live[0..index]) |earlier| {
                assert(!std.mem.eql(u8, entry.key, earlier.key));
            }
        }
    }
};

const Frame = struct {
    a: Value,
    b: Value,
    index: usize,
};

/// Structural equality. Maps compare in insertion order; `int` never equals `uint`; floats
/// compare bit-for-bit, so `0.0 != -0.0` and NaN equals NaN (round-trip identity, not IEEE).
/// Nesting deeper than `nesting_max` is data, not a contract violation: `error.TooDeep`.
pub fn eql(a: Value, b: Value) error{TooDeep}!bool {
    var frames: [nesting_max]Frame = undefined;
    var depth: u32 = 0;

    if (!eql_shallow(a, b)) return false;
    if (is_container(a)) {
        frames[0] = .{ .a = a, .b = b, .index = 0 };
        depth = 1;
    }
    while (depth > 0) {
        assert(depth <= nesting_max);
        const top = &frames[depth - 1];
        const length = container_len(top.a);
        assert(length == container_len(top.b));
        assert(top.index <= length);
        if (top.index == length) {
            depth -= 1;
            continue;
        }
        const child_a = container_child(top.a, top.index);
        const child_b = container_child(top.b, top.index);
        top.index += 1;
        if (!eql_shallow(child_a, child_b)) return false;
        if (is_container(child_a)) {
            if (depth == nesting_max) return error.TooDeep;
            frames[depth] = .{ .a = child_a, .b = child_b, .index = 0 };
            depth += 1;
        }
    }
    assert(depth == 0);
    return true;
}

fn is_container(value: Value) bool {
    return switch (value) {
        .array, .map => true,
        else => false,
    };
}

fn container_len(value: Value) usize {
    return switch (value) {
        .array => |items| items.len,
        .map => |map| map.count,
        else => unreachable, // Callers gate on `is_container`.
    };
}

fn container_child(value: Value, index: usize) Value {
    return switch (value) {
        .array => |items| items[index],
        .map => |map| map.items()[index].value,
        else => unreachable, // Callers gate on `is_container`.
    };
}

/// Compares tags and scalars; for containers compares length (and map keys) only.
fn eql_shallow(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .int => |x| x == b.int,
        .uint => |x| x == b.uint,
        .float => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .string => |x| std.mem.eql(u8, x, b.string),
        .bytes => |x| std.mem.eql(u8, x, b.bytes),
        .timestamp => |x| std.meta.eql(x, b.timestamp),
        .array => |x| x.len == b.array.len,
        .map => |x| blk: {
            if (x.count != b.map.count) break :blk false;
            for (x.items(), b.map.items()) |left, right| {
                if (!std.mem.eql(u8, left.key, right.key)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "value: every variant constructs and switches exhaustively" {
    const items = [_]Value{
        .null,
        .{ .bool = true },
        .{ .int = -1 },
        .{ .uint = std.math.maxInt(u64) },
        .{ .float = 1.5 },
        .{ .string = "s" },
        .{ .bytes = "b" },
        .{ .timestamp = .{ .seconds = 0, .nanoseconds = 0, .offset_minutes = null } },
        .{ .array = &.{} },
        .{ .map = Map.init(&.{}) },
    };
    var seen: u32 = 0;
    for (items) |item| {
        switch (item) {
            .null => seen |= 1 << 0,
            .bool => seen |= 1 << 1,
            .int => seen |= 1 << 2,
            .uint => seen |= 1 << 3,
            .float => seen |= 1 << 4,
            .string => seen |= 1 << 5,
            .bytes => seen |= 1 << 6,
            .timestamp => seen |= 1 << 7,
            .array => seen |= 1 << 8,
            .map => seen |= 1 << 9,
        }
    }
    try std.testing.expectEqual(@as(u32, 0x3ff), seen);
    try std.testing.expectEqual(@typeInfo(Value).@"union".fields.len, 10);
}

test "map: insertion order survives put, get, iterate" {
    var buffer: [3]Map.Entry = undefined;
    var map = Map.init(&buffer);
    try map.put("c", .{ .int = 3 });
    try map.put("a", .{ .int = 1 });
    try map.put("b", .{ .int = 2 });
    map.check_invariants();

    const entries = map.items();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("c", entries[0].key);
    try std.testing.expectEqualStrings("a", entries[1].key);
    try std.testing.expectEqualStrings("b", entries[2].key);
    try std.testing.expectEqual(@as(i64, 1), map.get("a").?.int);
    try std.testing.expect(map.get("z") == null);
}

test "map: empty, one, capacity boundary, capacity plus one" {
    var empty = Map.init(&.{});
    try std.testing.expectEqual(@as(usize, 0), empty.items().len);
    try std.testing.expectError(error.OutOfSpace, empty.put("k", .null));

    var buffer: [1]Map.Entry = undefined;
    var one = Map.init(&buffer);
    try one.put("k", .null);
    try std.testing.expectEqual(@as(usize, 1), one.items().len);
    try std.testing.expectError(error.OutOfSpace, one.put("j", .null));
    one.check_invariants();
}

test "map: duplicate key is an operating error and leaves the map unchanged" {
    var buffer: [2]Map.Entry = undefined;
    var map = Map.init(&buffer);
    try map.put("k", .{ .int = 1 });
    try std.testing.expectError(error.DuplicateKey, map.put("k", .{ .int = 2 }));
    try std.testing.expectEqual(@as(usize, 1), map.items().len);
    try std.testing.expectEqual(@as(i64, 1), map.get("k").?.int);
    map.check_invariants();
}

test "value: eql is structural, order-sensitive for maps, and int is not uint" {
    var buffer_a: [2]Map.Entry = undefined;
    var buffer_b: [2]Map.Entry = undefined;
    var map_a = Map.init(&buffer_a);
    var map_b = Map.init(&buffer_b);
    try map_a.put("x", .{ .int = 1 });
    try map_a.put("y", .null);
    try map_b.put("x", .{ .int = 1 });
    try map_b.put("y", .null);
    try std.testing.expect(try eql(.{ .map = map_a }, .{ .map = map_b }));

    var buffer_c: [2]Map.Entry = undefined;
    var map_c = Map.init(&buffer_c);
    try map_c.put("y", .null);
    try map_c.put("x", .{ .int = 1 });
    try std.testing.expect(!try eql(.{ .map = map_a }, .{ .map = map_c }));

    try std.testing.expect(!try eql(.{ .int = 1 }, .{ .uint = 1 }));
    const inner = [_]Value{ .{ .int = 1 }, .{ .string = "s" } };
    try std.testing.expect(try eql(.{ .array = &inner }, .{ .array = &inner }));
    try std.testing.expect(!try eql(.{ .array = &inner }, .{ .array = inner[0..1] }));
    try std.testing.expect(!try eql(.{ .float = 0.0 }, .{ .float = -0.0 }));
    const nan = std.math.nan(f64);
    try std.testing.expect(try eql(.{ .float = nan }, .{ .float = nan }));
}

test "value: eql descends nested containers and finds deep and trailing mismatches" {
    const leaf_a = [_]Value{ .{ .int = 1 }, .{ .array = &.{} } };
    const leaf_b = [_]Value{ .{ .int = 1 }, .{ .array = &.{} } };
    const leaf_c = [_]Value{ .{ .int = 1 }, .{ .array = &[_]Value{.null} } };
    var buffer_a: [1]Map.Entry = undefined;
    var buffer_b: [1]Map.Entry = undefined;
    var buffer_c: [1]Map.Entry = undefined;
    var map_a = Map.init(&buffer_a);
    var map_b = Map.init(&buffer_b);
    var map_c = Map.init(&buffer_c);
    try map_a.put("k", .{ .array = &leaf_a });
    try map_b.put("k", .{ .array = &leaf_b });
    try map_c.put("k", .{ .array = &leaf_c });
    const outer_a = [_]Value{ .{ .map = map_a }, .{ .string = "tail" } };
    const outer_b = [_]Value{ .{ .map = map_b }, .{ .string = "tail" } };
    const outer_c = [_]Value{ .{ .map = map_c }, .{ .string = "tail" } };
    const outer_d = [_]Value{ .{ .map = map_b }, .{ .string = "tale" } };
    try std.testing.expect(try eql(.{ .array = &outer_a }, .{ .array = &outer_b }));
    try std.testing.expect(!try eql(.{ .array = &outer_a }, .{ .array = &outer_c }));
    try std.testing.expect(!try eql(.{ .array = &outer_a }, .{ .array = &outer_d }));
}

test "value: eql accepts nesting_max and rejects one deeper with TooDeep" {
    var levels: [nesting_max + 1]Value = undefined;
    levels[nesting_max] = .{ .array = &.{} };
    var depth: u32 = nesting_max;
    while (depth > 0) : (depth -= 1) {
        levels[depth - 1] = .{ .array = levels[depth .. depth + 1] };
    }
    // levels[0] holds nesting_max + 1 containers, levels[1] holds nesting_max.
    try std.testing.expect(try eql(levels[1], levels[1]));
    try std.testing.expectError(error.TooDeep, eql(levels[0], levels[0]));
}

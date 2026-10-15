//! path/clone — deep copy of a borrowed `Value` into a `ValueTree` (ADR 0004 section 3).
//!
//! Merge Patch and Patch take their operands from the caller, whose lifetime the tree cannot
//! assume, so everything that lands in the tree is copied: strings, bytes, map keys, and every
//! array and map buffer. The walk uses an explicit stack of `nesting_max` frames, no recursion.
//!
//! Invariants: the result shares no byte with the source and has the same shape; every
//! container it holds nests at most `core.value.nesting_max` levels below the document root.
//! Allocation: only `tree.arena`, exactly one allocation per string, byte slice, key and
//! container buffer; a failure leaves garbage in the arena and the source untouched.
//! Cost: O(nodes) time, O(nesting_max) stack.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Map = core.Map;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;

pub const CloneError = error{ TooDeep, OutOfMemory };

/// A container being copied: `source` is read, `items` or `map` is the destination.
const Frame = struct {
    source: Value,
    items: []Value,
    map: Map,
    index: u32,
};

/// Deep-copies `value` into `tree` and returns the copy. `level` is the nesting level of the
/// container that will hold the copy (0 when the copy becomes the document root), so the
/// result's containers occupy levels `level + 1` and deeper; one past `nesting_max` is
/// `error.TooDeep`. Preconditions: `tree` was initialized; `level <= nesting_max`; `value`
/// holds no map with a duplicate key (a `Map` invariant).
pub fn deep(tree: *ValueTree, value: Value, level: u32) CloneError!Value {
    assert(level <= nesting_max);
    if (!is_container(value)) return try copy_leaf(tree, value);
    if (level == nesting_max) return error.TooDeep;

    var frames: [nesting_max]Frame = undefined;
    frames[0] = try open(tree, value);
    var depth: u32 = 1;
    var result: Value = .null;
    while (depth > 0) {
        assert(depth <= nesting_max);
        const top = &frames[depth - 1];
        assert(top.index <= length_of(top.source));
        if (top.index == length_of(top.source)) {
            const done = finish(top);
            depth -= 1;
            if (depth == 0) {
                result = done;
            } else {
                try store_item(tree, &frames[depth - 1], done);
            }
            continue;
        }
        const child = child_of(top, top.index);
        top.index += 1;
        if (is_container(child)) {
            if (level + depth == nesting_max) return error.TooDeep;
            frames[depth] = try open(tree, child);
            depth += 1;
        } else {
            try store_item(tree, top, try copy_leaf(tree, child));
        }
    }
    assert(is_container(result));
    return result;
}

fn is_container(value: Value) bool {
    return switch (value) {
        .array, .map => true,
        .null, .bool, .int, .uint, .float, .string, .bytes, .timestamp => false,
    };
}

fn length_of(source: Value) u32 {
    assert(is_container(source));
    return switch (source) {
        .array => |items| @intCast(items.len),
        .map => |map| map.count,
        else => unreachable, // proof: frames hold containers only.
    };
}

/// The value of the `index`th child of the frame's source.
fn child_of(frame: *const Frame, index: u32) Value {
    assert(index < length_of(frame.source));
    assert(frame.index == index);
    return switch (frame.source) {
        .array => |items| items[index],
        .map => |map| map.items()[index].value,
        else => unreachable, // proof: frames hold containers only.
    };
}

fn open(tree: *ValueTree, source: Value) CloneError!Frame {
    assert(is_container(source));
    assert(length_of(source) <= std.math.maxInt(u32));
    switch (source) {
        .array => |items| {
            const buffer = try tree.arena.allocator().alloc(Value, items.len);
            return .{ .source = source, .items = buffer, .map = Map.init(&.{}), .index = 0 };
        },
        .map => |map| {
            const copy = try tree.new_map(map.count);
            return .{ .source = source, .items = &.{}, .map = copy, .index = 0 };
        },
        else => unreachable, // proof: callers gate on `is_container`.
    }
}

fn finish(frame: *const Frame) Value {
    assert(frame.index == length_of(frame.source));
    assert(is_container(frame.source));
    switch (frame.source) {
        .array => {
            assert(frame.items.len == frame.index);
            return .{ .array = frame.items };
        },
        .map => {
            assert(frame.map.count == frame.index);
            return .{ .map = frame.map };
        },
        else => unreachable, // proof: frames hold containers only.
    }
}

/// Stores the copy of the child just consumed (`frame.index - 1`); a map child gets a copy of
/// its key too. Keys are unique in the source, so appending cannot collide.
fn store_item(tree: *ValueTree, frame: *Frame, copy: Value) CloneError!void {
    assert(frame.index > 0);
    const slot = frame.index - 1;
    switch (frame.source) {
        .array => frame.items[slot] = copy,
        .map => |map| {
            assert(frame.map.count == slot);
            assert(frame.map.count < frame.map.entries.len);
            const key = try tree.dupe_key(map.items()[slot].key);
            frame.map.entries[slot] = .{ .key = key, .value = copy };
            frame.map.count += 1;
        },
        else => unreachable, // proof: frames hold containers only.
    }
}

fn copy_leaf(tree: *ValueTree, value: Value) CloneError!Value {
    assert(!is_container(value));
    return switch (value) {
        .string => |text| try tree.dupe_string(text),
        .bytes => |data| try tree.dupe_bytes(data),
        .null, .bool, .int, .uint, .float, .timestamp => value,
        .array, .map => unreachable, // proof: the assert above rules containers out.
    };
}

const testing = std.testing;

test "clone: a deep copy shares no byte with its source" {
    var source_tree: ValueTree = undefined;
    source_tree.init(testing.allocator);
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var text = [_]u8{ 'a', 'b' };
    var data = [_]u8{ 1, 2 };
    var inner = try source_tree.new_map(2);
    try inner.put(try source_tree.dupe_key("key"), try source_tree.dupe_string(&text));
    try inner.put("blob", try source_tree.dupe_bytes(&data));
    const big: Value = .{ .uint = std.math.maxInt(u64) };
    const list = try source_tree.dupe_array(&.{ .{ .map = inner }, big });
    const copy = try deep(&tree, list, 0);
    source_tree.deinit(); // Freed: a copy that aliased it would read garbage below.

    try testing.expectEqual(@as(usize, 2), copy.array.len);
    const map = copy.array[0].map;
    map.check_invariants();
    try testing.expectEqualStrings("ab", map.get("key").?.string);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, map.get("blob").?.bytes);
    try testing.expectEqual(std.math.maxInt(u64), copy.array[1].uint);
    try testing.expectEqual(@as(u32, 2), map.count);
    try testing.expect(map.entries.ptr != inner.entries.ptr);
}

test "clone: strings, bytes, keys and buffers are fresh allocations" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const text: []const u8 = "text";
    const data: []const u8 = "data";
    var inner = try tree.new_map(1);
    try inner.put("key", .{ .string = text });
    const items = [_]Value{ .{ .bytes = data }, .{ .map = inner } };
    const copy = try deep(&tree, .{ .array = &items }, 0);

    try testing.expect(copy.array.ptr != &items);
    try testing.expect(copy.array[0].bytes.ptr != data.ptr);
    const map = copy.array[1].map;
    try testing.expect(map.entries.ptr != inner.entries.ptr);
    try testing.expect(map.items()[0].key.ptr != inner.items()[0].key.ptr);
    try testing.expect(map.get("key").?.string.ptr != text.ptr);
    const when: core.value.Timestamp = .{ .seconds = 5, .nanoseconds = 7, .offset_minutes = -60 };
    const stamp: Value = .{ .timestamp = when };
    try testing.expect(try core.value.eql(stamp, try deep(&tree, stamp, 0)));
}

test "clone: scalars copy as themselves and empty containers stay empty" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    try testing.expect((try deep(&tree, .null, nesting_max)) == .null);
    try testing.expectEqual(@as(i64, -3), (try deep(&tree, .{ .int = -3 }, 0)).int);
    try testing.expectEqual(@as(usize, 0), (try deep(&tree, .{ .array = &.{} }, 0)).array.len);
    const empty_map = try deep(&tree, .{ .map = Map.init(&.{}) }, 0);
    try testing.expectEqual(@as(u32, 0), empty_map.map.count);
}

test "clone: the copy's containers may reach nesting_max levels and no further" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var node: Value = .null;
    for (0..nesting_max) |_| node = try tree.dupe_array(&.{node});
    // 128 nested arrays under a scalar-free root fit at level 0 and not under a level-1 parent.
    const fits = try deep(&tree, node, 0);
    try testing.expect(try core.value.eql(fits, node));
    try testing.expectError(error.TooDeep, deep(&tree, node, 1));
    try testing.expectError(error.TooDeep, deep(&tree, node, nesting_max));
    const wider = try tree.dupe_array(&.{node});
    try testing.expectError(error.TooDeep, deep(&tree, wider, 0));
}

test "clone: allocation failure is a typed error" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();

    const items = [_]Value{ .{ .string = "s" }, .null };
    try testing.expectError(error.OutOfMemory, deep(&tree, .{ .array = &items }, 0));
    try testing.expectError(error.OutOfMemory, deep(&tree, .{ .string = "s" }, 0));
}

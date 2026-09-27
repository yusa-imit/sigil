//! core/tree — `ValueTree`, the arena that owns every byte a parsed `Value` points at.
//!
//! Invariants: every string, byte slice, array and map buffer reachable from `root` was
//! allocated from `arena`; `deinit` frees them all at once. Allocation contract: `init` takes
//! the backing `gpa` and the arena grows on demand while a document is built (a document's
//! size is unknown up front, so the caller's `gpa` bounds it); after building, nothing
//! allocates. Values handed out live exactly as long as the tree.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Map = value_mod.Map;

pub const ValueTree = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub const BuildError = error{OutOfMemory};

    /// Initializes `tree` in place with a `null` root. `gpa` backs the arena.
    pub fn init(tree: *ValueTree, gpa: Allocator) void {
        tree.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .root = .null };
        assert(tree.root == .null);
        assert(tree.arena.queryCapacity() == 0);
    }

    /// Frees every allocation of the tree. Every `Value` and slice obtained from the tree is
    /// invalid afterwards; the tree must not be used again.
    pub fn deinit(tree: *ValueTree) void {
        if (tree.root == .map) assert(tree.root.map.count <= tree.root.map.entries.len);
        if (tree.root == .array) assert(tree.root.array.len < std.math.maxInt(u32));
        tree.arena.deinit();
        tree.* = undefined;
    }

    /// Copies `text` into the tree; the result lives until `deinit`.
    pub fn dupe_string(tree: *ValueTree, text: []const u8) BuildError!Value {
        const copy = try tree.arena.allocator().dupe(u8, text);
        assert(copy.len == text.len);
        assert(std.mem.eql(u8, copy, text));
        return .{ .string = copy };
    }

    /// Copies `data` into the tree; the result lives until `deinit`.
    pub fn dupe_bytes(tree: *ValueTree, data: []const u8) BuildError!Value {
        const copy = try tree.arena.allocator().dupe(u8, data);
        assert(copy.len == data.len);
        assert(std.mem.eql(u8, copy, data));
        return .{ .bytes = copy };
    }

    /// Copies the `items` slice (shallow: children keep pointing where they pointed, so they
    /// must already belong to this tree). The result lives until `deinit`.
    pub fn dupe_array(tree: *ValueTree, items: []const Value) BuildError!Value {
        const copy = try tree.arena.allocator().dupe(Value, items);
        assert(copy.len == items.len);
        assert(copy.len == 0 or copy.ptr != items.ptr);
        return .{ .array = copy };
    }

    /// An empty map with room for `capacity` entries, backed by the tree. Keys passed to
    /// `Map.put` must outlive the tree's use of them; use `dupe_key` for transient keys.
    pub fn new_map(tree: *ValueTree, capacity: u32) BuildError!Map {
        const buffer = try tree.arena.allocator().alloc(Map.Entry, capacity);
        const map = Map.init(buffer);
        assert(map.count == 0);
        assert(map.entries.len == capacity);
        return map;
    }

    /// Copies `key` into the tree for use with `Map.put`.
    pub fn dupe_key(tree: *ValueTree, key: []const u8) BuildError![]const u8 {
        const copy = try tree.arena.allocator().dupe(u8, key);
        assert(copy.len == key.len);
        assert(std.mem.eql(u8, copy, key));
        return copy;
    }
};

const testing = std.testing;

test "ValueTree: builds a nested document and frees it all without leaks" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var scratch = [_]u8{ 'a', 'b' };
    const name = try tree.dupe_string(&scratch);
    scratch[0] = 'z'; // The tree must own a copy, not alias the caller's buffer.
    try testing.expectEqualStrings("ab", name.string);

    const blob = try tree.dupe_bytes(&[_]u8{ 0, 1, 2 });
    const list = try tree.dupe_array(&.{ name, blob, .{ .int = -1 } });
    try testing.expectEqual(@as(usize, 3), list.array.len);

    var map = try tree.new_map(2);
    try map.put(try tree.dupe_key("name"), name);
    try map.put(try tree.dupe_key("list"), list);
    map.check_invariants();
    tree.root = .{ .map = map };

    try testing.expect(tree.root.map.get("list").?.array[1].bytes[2] == 2);
    try testing.expectEqual(@as(u32, 2), tree.root.map.count);
}

test "ValueTree: empty inputs and full map" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), (try tree.dupe_string("")).string.len);
    try testing.expectEqual(@as(usize, 0), (try tree.dupe_array(&.{})).array.len);
    var map = try tree.new_map(1);
    try map.put("a", .null);
    try testing.expectError(error.OutOfSpace, map.put("b", .null));
    var zero = try tree.new_map(0);
    try testing.expectError(error.OutOfSpace, zero.put("a", .null));
}

test "ValueTree: allocation failure is a typed error and leaves no leak" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();

    try testing.expectError(error.OutOfMemory, tree.dupe_string("x"));
    try testing.expectError(error.OutOfMemory, tree.dupe_bytes("x"));
    try testing.expectError(error.OutOfMemory, tree.dupe_array(&.{.null}));
    try testing.expectError(error.OutOfMemory, tree.new_map(1));
    try testing.expectError(error.OutOfMemory, tree.dupe_key("k"));
}

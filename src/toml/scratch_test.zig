//! Tests for `toml/scratch.zig`: the ADR 0005 section 4 state table, the hash index, depth,
//! and `materialize` (plan 006 item 5). Array and inline-table states are driven here directly
//! because the parser only grows them in item 6.

const std = @import("std");
const core = @import("../core.zig");
const scratch_module = @import("scratch.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Scratch = scratch_module.Scratch;
const Key = scratch_module.Key;
const State = scratch_module.State;
const Value = core.Value;
const ValueTree = core.ValueTree;
const root = scratch_module.root_index;

fn key(bytes: []const u8, offset: u32) Key {
    return .{ .bytes = bytes, .offset = offset, .owned = false };
}

fn new_scratch(depth_max: u16) !Scratch {
    var scratch: Scratch = undefined;
    try scratch.init(std.testing.allocator, 256, depth_max);
    return scratch;
}

test "scratch: init is exact and two allocations, deinit frees them" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    scratch.check_invariants();
    try expectEqual(@as(u32, 1), scratch.node_count);
    try expectEqual(State.header, scratch.state_of(root));
    try expectEqual(@as(u32, 0), scratch.child_count(root));
}

test "scratch: init reports each allocation failing" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var scratch: Scratch = undefined;
        try expectError(error.OutOfMemory, scratch.init(failing.allocator(), 64, 8));
    }
}

test "scratch: an implicit table becomes a header once, then is closed" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const a = try scratch.header_pass(root, key("a", 1));
    try expectEqual(State.implicit, scratch.state_of(a));
    try expectEqual(a, try scratch.header_pass(root, key("a", 9)));
    try expectEqual(a, try scratch.header_end(root, key("a", 20), false));
    try expectEqual(State.header, scratch.state_of(a));
    try expectError(error.TableRedefined, scratch.header_end(root, key("a", 30), false));
    try expectEqual(@as(u32, 20), scratch.conflict_offset);
    scratch.check_invariants();
}

test "scratch: a dotted table can be passed by a header but not ended or reopened" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const apple = try scratch.dotted_pass(root, key("apple", 5));
    try expectEqual(State.dotted, scratch.state_of(apple));
    try expectEqual(apple, try scratch.dotted_pass(root, key("apple", 40)));
    try expectEqual(apple, try scratch.header_pass(root, key("apple", 60)));
    try expectError(error.TableRedefined, scratch.header_end(root, key("apple", 70), false));
    try expectEqual(@as(u32, 5), scratch.conflict_offset);
}

test "scratch: a dotted key through a header table is TableRedefined" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const b = try scratch.header_end(root, key("b", 3), false);
    try expectEqual(State.header, scratch.state_of(b));
    try expectError(error.TableRedefined, scratch.dotted_pass(root, key("b", 20)));
    try expectEqual(@as(u32, 3), scratch.conflict_offset);

    _ = try scratch.header_pass(root, key("c", 30));
    try expectError(error.TableRedefined, scratch.dotted_pass(root, key("c", 40)));
}

test "scratch: an array of tables appends elements and header paths enter the newest" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const first = try scratch.header_end(root, key("a", 2), true);
    const second = try scratch.header_end(root, key("a", 10), true);
    try expect(first != second);
    try expectEqual(State.header, scratch.state_of(second));
    try expectEqual(second, try scratch.header_pass(root, key("a", 20)));
    try expectError(error.TypeConflict, scratch.dotted_pass(root, key("a", 30)));
    try expectError(error.TypeConflict, scratch.header_end(root, key("a", 40), false));
    try expectEqual(@as(u32, 2), scratch.conflict_offset);
    scratch.check_invariants();
}

test "scratch: [[a]] over a table, a scalar or a static array is TypeConflict" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    _ = try scratch.header_end(root, key("t", 1), false);
    try scratch.insert_scalar(root, key("s", 5), .{ .int = 1 });
    _ = try scratch.insert_container(root, key("l", 9), .array_static);
    for ([_][]const u8{ "t", "s", "l" }) |name| {
        try expectError(error.TypeConflict, scratch.header_end(root, key(name, 50), true));
    }
}

test "scratch: a static array is closed to headers, dotted keys and redefinition" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const list = try scratch.insert_container(root, key("a", 7), .array_static);
    try expectEqual(State.array_static, scratch.state_of(list));
    try expectError(error.TypeConflict, scratch.header_pass(root, key("a", 20)));
    try expectError(error.TypeConflict, scratch.header_end(root, key("a", 20), false));
    try expectError(error.TypeConflict, scratch.dotted_pass(root, key("a", 20)));
    try expectError(error.DuplicateKey, scratch.insert_scalar(root, key("a", 20), .null));
    try expectEqual(@as(u32, 7), scratch.conflict_offset);
}

test "scratch: an inline table is frozen against headers and dotted keys" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const inline_table = try scratch.insert_container(root, key("t", 4), .inline_table);
    try scratch.insert_scalar(inline_table, key("x", 8), .{ .int = 1 });
    try expectError(error.TableRedefined, scratch.header_pass(root, key("t", 30)));
    try expectError(error.TableRedefined, scratch.header_end(root, key("t", 30), false));
    try expectError(error.TableRedefined, scratch.dotted_pass(root, key("t", 30)));
    try expectError(error.DuplicateKey, scratch.insert_scalar(root, key("t", 30), .null));
    try expectEqual(@as(u32, 4), scratch.conflict_offset);
    try expectError(error.DuplicateKey, scratch.insert_scalar(inline_table, key("x", 31), .null));
    scratch.check_invariants();
}

test "scratch: a scalar cannot be passed, reopened or assigned twice" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    try scratch.insert_scalar(root, key("a", 0), .{ .bool = true });
    try expectError(error.DuplicateKey, scratch.insert_scalar(root, key("a", 9), .null));
    try expectError(error.TypeConflict, scratch.header_pass(root, key("a", 9)));
    try expectError(error.TypeConflict, scratch.header_end(root, key("a", 9), false));
    try expectError(error.TypeConflict, scratch.dotted_pass(root, key("a", 9)));
    try expectEqual(@as(u32, 0), scratch.conflict_offset);
}

test "scratch: depth counts the root; a leaf does not add a level" {
    var scratch = try new_scratch(3);
    defer scratch.deinit(std.testing.allocator);

    const a = try scratch.header_pass(root, key("a", 1));
    const b = try scratch.header_pass(a, key("b", 3));
    try scratch.insert_scalar(b, key("leaf", 5), .{ .int = 1 });
    try expectError(error.TooDeep, scratch.header_pass(b, key("c", 11)));
    try expectEqual(@as(u32, 11), scratch.conflict_offset);
    try expectError(error.TooDeep, scratch.header_end(b, key("c", 12), true));
    try expectError(error.TooDeep, scratch.insert_container(b, key("d", 13), .array_static));
}

test "scratch: [[a]] costs two levels" {
    var scratch = try new_scratch(2);
    defer scratch.deinit(std.testing.allocator);

    try expectError(error.TooDeep, scratch.header_end(root, key("a", 2), true));
    var wide = try new_scratch(3);
    defer wide.deinit(std.testing.allocator);

    _ = try wide.header_end(root, key("a", 2), true);
}

test "scratch: materialize keeps document order and exact sizes" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    try scratch.insert_scalar(root, key("z", 0), .{ .int = 1 });
    const table = try scratch.header_end(root, key("m", 5), false);
    try scratch.insert_scalar(table, key("k", 9), .{ .int = 2 });
    const first = try scratch.header_end(root, key("a", 15), true);
    try scratch.insert_scalar(first, key("n", 19), .{ .int = 3 });
    _ = try scratch.header_end(root, key("a", 25), true);
    scratch.check_invariants();

    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const value = try scratch_module.materialize(&scratch, &tree);
    value.map.check_invariants();
    try expectEqual(@as(u32, 3), value.map.count);
    try expectEqual(value.map.entries.len, value.map.count);
    const names = [_][]const u8{ "z", "m", "a" };
    for (names, value.map.items()) |name, entry| {
        try std.testing.expectEqualStrings(name, entry.key);
    }
    const list = value.map.get("a").?.array;
    try expectEqual(@as(usize, 2), list.len);
    try expectEqual(@as(i64, 3), list[0].map.get("n").?.int);
    try expectEqual(@as(u32, 0), list[1].map.count);
    try expectEqual(@as(i64, 2), value.map.get("m").?.map.get("k").?.int);
}

test "scratch: materialize reports each arena allocation failing" {
    var scratch = try new_scratch(8);
    defer scratch.deinit(std.testing.allocator);

    const table = try scratch.header_end(root, key("m", 5), false);
    try scratch.insert_scalar(table, key("k", 9), .{ .int = 2 });
    var reached_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();

        const result = scratch_module.materialize(&scratch, &tree);
        if (result) |value| {
            try expectEqual(@as(u32, 1), value.map.count);
            reached_success = true;
        } else |err| {
            try std.testing.expectEqualStrings("OutOfMemory", @errorName(err));
        }
    }
    try expect(reached_success);
}

test "scratch: 2,000 keys in one table are found through the hash index" {
    const count = 2000;
    var scratch: Scratch = undefined;
    try scratch.init(std.testing.allocator, count * 8, 8);
    defer scratch.deinit(std.testing.allocator);

    var storage: [count][8]u8 = undefined;
    for (&storage, 0..) |*slot, index| {
        _ = std.fmt.bufPrint(slot, "key{d:0>5}", .{index}) catch unreachable; // proof: 8 bytes fit.
        try scratch.insert_scalar(root, key(slot, @intCast(index)), .{ .int = @intCast(index) });
    }
    for (&storage, 0..) |*slot, index| {
        try expectError(error.DuplicateKey, scratch.insert_scalar(root, key(slot, 0), .null));
        try expectEqual(@as(u32, @intCast(index)), scratch.conflict_offset);
    }
    scratch.check_invariants();

    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const value = try scratch_module.materialize(&scratch, &tree);
    value.map.check_invariants();
    try expectEqual(@as(u32, count), value.map.count);
    for (value.map.items(), 0..) |entry, index| {
        try expectEqual(@as(i64, @intCast(index)), entry.value.int);
    }
}

test "scratch: model test, 300 seeds of inserts into two tables against a reference" {
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (0..300) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var scratch = try new_scratch(8);
        defer scratch.deinit(std.testing.allocator);

        const table = try scratch.header_end(root, key("t", 0), false);
        var taken = [_]bool{false} ** (2 * names.len);
        for (0..40) |step| {
            const in_table = random.boolean();
            const which = random.uintLessThan(usize, names.len);
            const slot = which + if (in_table) names.len else 0;
            const parent = if (in_table) table else root;
            const name_key = key(names[which], @intCast(step));
            if (taken[slot]) {
                try expectError(error.DuplicateKey, scratch.insert_scalar(parent, name_key, .null));
            } else {
                try scratch.insert_scalar(parent, name_key, .{ .int = @intCast(step) });
                taken[slot] = true;
            }
        }
        scratch.check_invariants();
        var expected_root: u32 = 1; // The table `t` itself.
        var expected_table: u32 = 0;
        for (taken, 0..) |is_taken, slot| {
            if (!is_taken) continue;
            if (slot >= names.len) expected_table += 1 else expected_root += 1;
        }
        try expectEqual(expected_root, scratch.child_count(root));
        try expectEqual(expected_table, scratch.child_count(table));
    }
}

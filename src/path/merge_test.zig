//! Tests for `path/merge.zig` (plan 005 item 3): the RFC 7386 appendix A table verbatim, the
//! section 3 example, no aliasing of the patch, sharing of untouched subtrees, the unchanged
//! root on `TooDeep` and `OutOfMemory`, the `nesting_max` boundary, and a seeded model against
//! the RFC pseudocode. The fixtures are JSON text parsed by `json.dom` (a test-only import:
//! `path` itself imports `core` alone).

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("../json/dom.zig");
const merge = @import("merge.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;
const parse_options: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .reject };

fn parse_json(tree: *ValueTree, text: []const u8) !Value {
    var diag = Diagnostics.init(0, 0, "", null);
    return try dom.parse(tree, text, parse_options, &diag);
}

/// Walks every node of `root`, asserting each map's invariants and the nesting limit, and
/// returns the deepest container level (0 for a scalar).
fn check_tree(root: Value) !u32 {
    const Walk = struct { value: Value, index: u32 };
    var stack: [nesting_max]Walk = undefined;
    var depth: u32 = 0;
    var deepest: u32 = 0;
    if (is_container(root)) {
        stack[0] = .{ .value = root, .index = 0 };
        depth = 1;
        deepest = 1;
    }
    while (depth > 0) {
        const top = &stack[depth - 1];
        const count: u32 = switch (top.value) {
            .array => |items| @intCast(items.len),
            .map => |map| blk: {
                map.check_invariants();
                break :blk map.count;
            },
            else => unreachable, // proof: the stack holds containers only.
        };
        if (top.index == count) {
            depth -= 1;
            continue;
        }
        const child = switch (top.value) {
            .array => |items| items[top.index],
            .map => |map| map.items()[top.index].value,
            else => unreachable, // proof: the stack holds containers only.
        };
        top.index += 1;
        if (!is_container(child)) continue;
        try expect(depth < nesting_max);
        stack[depth] = .{ .value = child, .index = 0 };
        depth += 1;
        deepest = @max(deepest, depth);
    }
    return deepest;
}

fn is_container(value: Value) bool {
    return value == .array or value == .map;
}

/// Merges `patch_text` into `target_text` and compares with `expected_text`. The patch tree is
/// freed before the comparison, so a result that aliased it would read freed memory.
fn expect_merge(target_text: []const u8, patch_text: []const u8, expected_text: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, target_text);
    {
        var patch_tree: ValueTree = undefined;
        patch_tree.init(std.testing.allocator);
        defer patch_tree.deinit();
        const patch = try parse_json(&patch_tree, patch_text);
        try merge.apply(&tree, &patch);
    }
    var expected_tree: ValueTree = undefined;
    expected_tree.init(std.testing.allocator);
    defer expected_tree.deinit();
    const expected = try parse_json(&expected_tree, expected_text);
    _ = try check_tree(tree.root);
    try expect(try core.value.eql(tree.root, expected));
}

test "merge: the RFC 7386 appendix A table, verbatim" {
    const Row = struct { target: []const u8, patch: []const u8, result: []const u8 };
    const table = [_]Row{
        .{ .target = "{\"a\":\"b\"}", .patch = "{\"a\":\"c\"}", .result = "{\"a\":\"c\"}" },
        .{
            .target = "{\"a\":\"b\"}",
            .patch = "{\"b\":\"c\"}",
            .result = "{\"a\":\"b\",\"b\":\"c\"}",
        },
        .{ .target = "{\"a\":\"b\"}", .patch = "{\"a\":null}", .result = "{}" },
        .{
            .target = "{\"a\":\"b\",\"b\":\"c\"}",
            .patch = "{\"a\":null}",
            .result = "{\"b\":\"c\"}",
        },
        .{ .target = "{\"a\":[\"b\"]}", .patch = "{\"a\":\"c\"}", .result = "{\"a\":\"c\"}" },
        .{ .target = "{\"a\":\"c\"}", .patch = "{\"a\":[\"b\"]}", .result = "{\"a\":[\"b\"]}" },
        .{
            .target = "{\"a\":{\"b\":\"c\"}}",
            .patch = "{\"a\":{\"b\":\"d\",\"c\":null}}",
            .result = "{\"a\":{\"b\":\"d\"}}",
        },
        .{ .target = "{\"a\":[{\"b\":\"c\"}]}", .patch = "{\"a\":[1]}", .result = "{\"a\":[1]}" },
        .{ .target = "[\"a\",\"b\"]", .patch = "[\"c\",\"d\"]", .result = "[\"c\",\"d\"]" },
        .{ .target = "{\"a\":\"b\"}", .patch = "[\"c\"]", .result = "[\"c\"]" },
        .{ .target = "{\"a\":\"foo\"}", .patch = "null", .result = "null" },
        .{ .target = "{\"a\":\"foo\"}", .patch = "\"bar\"", .result = "\"bar\"" },
        .{ .target = "{\"e\":null}", .patch = "{\"a\":1}", .result = "{\"e\":null,\"a\":1}" },
        .{ .target = "[1,2]", .patch = "{\"a\":\"b\",\"c\":null}", .result = "{\"a\":\"b\"}" },
        .{
            .target = "{}",
            .patch = "{\"a\":{\"bb\":{\"ccc\":null}}}",
            .result = "{\"a\":{\"bb\":{}}}",
        },
    };
    try expectEqual(@as(usize, 15), table.len);
    for (table) |row| try expect_merge(row.target, row.patch, row.result);
}

test "merge: the RFC 7386 section 3 example keeps target order, appends new keys" {
    const target =
        \\{"title":"Goodbye!","author":{"givenName":"John","familyName":"Doe"},
        \\"tags":["example","sample"],"content":"This will be unchanged"}
    ;
    const patch =
        \\{"title":"Hello!","phoneNumber":"+01-123-456-7890","author":{"familyName":null},
        \\"tags":["example"]}
    ;
    const result =
        \\{"title":"Hello!","author":{"givenName":"John"},"tags":["example"],
        \\"content":"This will be unchanged","phoneNumber":"+01-123-456-7890"}
    ;
    try expect_merge(target, patch, result);
}

test "merge: null deletes only what exists, objects replace scalars with nulls stripped" {
    try expect_merge("{\"a\":1}", "{\"b\":null}", "{\"a\":1}");
    try expect_merge("{\"a\":1}", "{\"a\":{\"b\":null,\"c\":2}}", "{\"a\":{\"c\":2}}");
    try expect_merge("{\"a\":1}", "{}", "{\"a\":1}");
    try expect_merge("[1]", "{}", "{}");
    try expect_merge("5", "{\"a\":null}", "{}");
    try expect_merge("{}", "{}", "{}");
    // Arrays and what is inside them are values, not patches: nulls and objects stay verbatim.
    try expect_merge("{\"a\":1}", "{\"a\":[null,{\"b\":null}]}", "{\"a\":[null,{\"b\":null}]}");
    // Deleting the first, middle and last of three keeps the order of the rest.
    const three = "{\"a\":1,\"b\":2,\"c\":3}";
    try expect_merge(three, "{\"a\":null}", "{\"b\":2,\"c\":3}");
    try expect_merge(three, "{\"b\":null}", "{\"a\":1,\"c\":3}");
    try expect_merge(three, "{\"c\":null}", "{\"a\":1,\"b\":2}");
    try expect_merge(three, "{\"a\":null,\"b\":null,\"c\":null}", "{}");
}

test "merge: numbers keep their kind, int stays distinct from uint and float" {
    try expect_merge(
        "{\"a\":1}",
        "{\"a\":-1,\"b\":18446744073709551615,\"c\":1.5}",
        "{\"a\":-1,\"b\":18446744073709551615,\"c\":1.5}",
    );
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, "{}");
    const patch = Value{ .map = try one_entry(&tree, "n", .{ .uint = 7 }) };
    try merge.apply(&tree, &patch);
    try expectEqual(@as(u64, 7), tree.root.map.get("n").?.uint);
}

fn one_entry(tree: *ValueTree, key: []const u8, value: Value) !Map {
    var map = try tree.new_map(1);
    try map.put(key, value);
    return map;
}

test "merge: untouched subtrees are shared and the old root keeps its content" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, "{\"keep\":[1,2,3],\"a\":{\"x\":1,\"y\":2},\"b\":1}");
    const before = tree.root;
    const keep_before = before.map.get("keep").?.array;

    var patch_tree: ValueTree = undefined;
    patch_tree.init(std.testing.allocator);
    defer patch_tree.deinit();
    const patch = try parse_json(&patch_tree, "{\"a\":{\"x\":null},\"b\":null}");
    try merge.apply(&tree, &patch);

    // Nothing is mutated in place: the previous root still reads as it did.
    try expectEqual(@as(u32, 3), before.map.count);
    try expectEqual(@as(u32, 2), before.map.get("a").?.map.count);
    try expectEqual(@as(i64, 1), before.map.get("b").?.int);
    try expect(tree.root.map.entries.ptr != before.map.entries.ptr);
    // The untouched sibling is the same slice, not a copy.
    try expect(tree.root.map.get("keep").?.array.ptr == keep_before.ptr);
    try expectEqual(@as(u32, 2), tree.root.map.count);
    try expectEqual(@as(u32, 1), tree.root.map.get("a").?.map.count);
    _ = try check_tree(tree.root);
}

/// `levels` nested one-entry maps (`{"k":{"k":...leaf}}`), built inside out.
fn nested_maps(tree: *ValueTree, levels: u32, leaf: Value) !Value {
    var node = leaf;
    for (0..levels) |_| {
        // Not `node = .{ .map = try one_entry(.., node) }`: the result location aliases `node`.
        const wrapped = try one_entry(tree, "k", node);
        node = .{ .map = wrapped };
    }
    return node;
}

/// `levels` nested one-element arrays (`[[...leaf]]`), built inside out.
fn nested_arrays(tree: *ValueTree, levels: u32, leaf: Value) !Value {
    var node = leaf;
    for (0..levels) |_| node = try tree.dupe_array(&.{node});
    return node;
}

/// Applies `patch` to a tree holding `target`, expects `err`, and checks the root is the
/// very same value afterwards: same buffer, same content.
fn expect_unchanged_on(tree: *ValueTree, patch: Value, err: merge.MergeError) !void {
    const before = tree.root;
    try std.testing.expectError(err, merge.apply(tree, &patch));
    try expectEqual(std.meta.activeTag(before), std.meta.activeTag(tree.root));
    if (before == .map) try expect(before.map.entries.ptr == tree.root.map.entries.ptr);
    try expect(try core.value.eql(before, tree.root));
    _ = try check_tree(tree.root);
}

test "merge: nesting_max is accepted and one level past it is TooDeep with the root intact" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, "{\"a\":1}");

    // A map patch of exactly nesting_max levels merges; one more level is TooDeep.
    const maps_too_deep = try nested_maps(&tree, nesting_max + 1, .{ .int = 1 });
    try expect_unchanged_on(&tree, maps_too_deep, error.TooDeep);
    // An array inside a map patch: 1 map level + 127 array levels fits, 128 does not.
    const fits = try nested_arrays(&tree, nesting_max - 1, .{ .int = 1 });
    const too_deep = try nested_arrays(&tree, nesting_max, .{ .int = 1 });
    try expect_unchanged_on(&tree, .{ .map = try one_entry(&tree, "x", too_deep) }, error.TooDeep);
    // A non-map patch replaces the root and is checked from level 0.
    try expect_unchanged_on(&tree, try nested_arrays(&tree, nesting_max + 1, .null), error.TooDeep);

    const ok_maps = try nested_maps(&tree, nesting_max, .{ .int = 1 });
    try merge.apply(&tree, &ok_maps);
    try expectEqual(@as(u32, nesting_max), try check_tree(tree.root));
    try expectEqual(@as(i64, 1), tree.root.map.get("a").?.int);

    tree.root = .{ .map = try tree.new_map(0) };
    const ok_array = Value{ .map = try one_entry(&tree, "x", fits) };
    try merge.apply(&tree, &ok_array);
    try expectEqual(@as(u32, nesting_max), try check_tree(tree.root));

    const root_array = try nested_arrays(&tree, nesting_max, .null);
    try merge.apply(&tree, &root_array);
    try expectEqual(@as(u32, nesting_max), try check_tree(tree.root));
}

test "merge: a merge into a full-depth target keeps depth, never exceeds it" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try nested_maps(&tree, nesting_max, .{ .int = 1 });
    try expectEqual(@as(u32, nesting_max), try check_tree(tree.root));

    // `{"k":...{"k":{"x":1}}}`: the innermost patch map lands at level 128, merging with {"k":1}.
    const leaf = Value{ .map = try one_entry(&tree, "x", .{ .int = 2 }) };
    const patch = try nested_maps(&tree, nesting_max - 1, leaf);
    try merge.apply(&tree, &patch);
    try expectEqual(@as(u32, nesting_max), try check_tree(tree.root));

    // One more level of patch would put a map at level 129.
    const deeper = try nested_maps(&tree, nesting_max, leaf);
    try expect_unchanged_on(&tree, deeper, error.TooDeep);
}

test "merge: allocation failure at every point leaves the root unchanged" {
    var target_tree: ValueTree = undefined;
    target_tree.init(std.testing.allocator);
    defer target_tree.deinit();
    const target_text = "{\"a\":{\"b\":1,\"c\":2},\"d\":[1,2],\"e\":3}";
    const target = try parse_json(&target_tree, target_text);
    var patch_tree: ValueTree = undefined;
    patch_tree.init(std.testing.allocator);
    defer patch_tree.deinit();
    const patch = try parse_json(
        &patch_tree,
        "{\"a\":{\"b\":null,\"f\":{\"g\":1}},\"h\":[1,\"x\",{\"y\":2}],\"i\":\"str\"}",
    );
    const expected_text = "{\"a\":{\"c\":2,\"f\":{\"g\":1}},\"d\":[1,2],\"e\":3," ++
        "\"h\":[1,\"x\",{\"y\":2}],\"i\":\"str\"}";
    var expected_tree: ValueTree = undefined;
    expected_tree.init(std.testing.allocator);
    defer expected_tree.deinit();
    const expected = try parse_json(&expected_tree, expected_text);

    var failures: u32 = 0;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        // The target lives outside this arena, so every arena allocation is the merge's own.
        tree.root = target;
        // proof: `MergeError` is {TooDeep, OutOfMemory}; no I/O happens, so no `error.Canceled`.
        merge.apply(&tree, &patch) catch |err| switch (err) {
            error.OutOfMemory => {
                failures += 1;
                try expect(tree.root.map.entries.ptr == target.map.entries.ptr);
                try expect(try core.value.eql(tree.root, target));
                continue;
            },
            error.TooDeep => return error.TestUnexpectedResult,
        };
        try expect(try core.value.eql(tree.root, expected));
        _ = try check_tree(tree.root);
        break;
    }
    // The arena batches its requests to the failing allocator, so only a few points exist.
    try expect(failures >= 2);
    try expect(failures < 64);
}

const ModelError = error{ OutOfMemory, DuplicateKey, OutOfSpace };
const key_names = [_][]const u8{ "a", "b", "c", "d" };
const generate_depth_max: u32 = 3;

/// A random value for the model: scalars, short arrays of scalars, small maps with distinct
/// keys in random order. `patch_mode` skews towards `null` so deletions happen often.
fn generate(
    tree: *ValueTree,
    random: std.Random,
    depth_left: u32,
    patch_mode: bool,
) ModelError!Value {
    const choice = random.uintLessThan(u32, 12);
    if (choice < 2) return if (patch_mode) .null else .{ .bool = choice == 0 };
    if (patch_mode and choice < 4) return .null;
    switch (choice) {
        2, 3, 4 => return .{ .int = random.intRangeAtMost(i64, -2, 2) },
        5 => return .{ .uint = std.math.maxInt(u64) - random.uintLessThan(u64, 3) },
        6 => return .{ .string = if (random.boolean()) "x" else "y" },
        7 => {
            const items = try tree.arena.allocator().alloc(Value, random.uintLessThan(u32, 3));
            for (items) |*item| item.* = .{ .int = random.intRangeAtMost(i64, 0, 1) };
            return .{ .array = items };
        },
        else => {},
    }
    if (depth_left == 0) return .{ .float = 1.5 };
    var names = key_names;
    random.shuffle([]const u8, &names);
    const count = random.uintLessThan(u32, key_names.len + 1);
    var map = try tree.new_map(count);
    for (names[0..count]) |name| {
        const child = try generate(tree, random, depth_left - 1, patch_mode);
        try map.put(name, child);
    }
    return .{ .map = map };
}

/// RFC 7386's pseudocode, literally, by recursion bounded by the generator's depth. Built in
/// `tree`; values taken whole from `patch` are shared with it.
fn reference(tree: *ValueTree, target: Value, patch: Value, depth: u32) ModelError!Value {
    std.debug.assert(depth <= generate_depth_max + 1);
    if (patch != .map) return patch;
    const kept: []const Map.Entry = if (target == .map) target.map.items() else &.{};
    const capacity: u32 = @intCast(kept.len + patch.map.count);
    var out = try tree.new_map(capacity);
    for (kept) |entry| try out.put(entry.key, entry.value);
    for (patch.map.items()) |entry| {
        const existing: Value = if (out.get(entry.key)) |found| found.* else .null;
        if (entry.value == .null) {
            var rebuilt = try tree.new_map(capacity);
            for (out.items()) |kept_entry| {
                if (std.mem.eql(u8, kept_entry.key, entry.key)) continue;
                try rebuilt.put(kept_entry.key, kept_entry.value);
            }
            out = rebuilt;
            continue;
        }
        const merged = try reference(tree, existing, entry.value, depth + 1);
        if (out.index_of(entry.key)) |index| {
            out.entries[index].value = merged;
        } else {
            try out.put(entry.key, merged);
        }
    }
    return .{ .map = out };
}

test "merge: model against the RFC pseudocode over 1,000 seeds" {
    var tally_delete: u32 = 0;
    var tally_nested: u32 = 0;
    var tally_replace_root: u32 = 0;
    for (0..1000) |seed| {
        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        tree.root = try generate(&tree, prng.random(), generate_depth_max, false);
        var patch_tree: ValueTree = undefined;
        patch_tree.init(std.testing.allocator);
        defer patch_tree.deinit();
        const patch = try generate(&patch_tree, prng.random(), generate_depth_max, true);

        // The same seed rebuilds the same target: the snapshot detects any in-place mutation.
        var snapshot_tree: ValueTree = undefined;
        snapshot_tree.init(std.testing.allocator);
        defer snapshot_tree.deinit();
        var again = std.Random.DefaultPrng.init(seed);
        const snapshot = try generate(&snapshot_tree, again.random(), generate_depth_max, false);

        var model_tree: ValueTree = undefined;
        model_tree.init(std.testing.allocator);
        defer model_tree.deinit();
        const expected = try reference(&model_tree, tree.root, patch, 0);

        const before = tree.root;
        try merge.apply(&tree, &patch);
        try expect(try core.value.eql(tree.root, expected));
        try expect(try core.value.eql(before, snapshot));
        _ = try check_tree(tree.root);

        if (patch != .map) tally_replace_root += 1;
        if (patch == .map and before == .map) {
            for (patch.map.items()) |entry| {
                if (entry.value == .null and before.map.get(entry.key) != null) tally_delete += 1;
                if (entry.value == .map and before.map.get(entry.key) != null) tally_nested += 1;
            }
        }
    }
    // The generator reaches deletions, nested merges and whole-root replacement.
    try expect(tally_delete > 0);
    try expect(tally_nested > 0);
    try expect(tally_replace_root > 0);
}

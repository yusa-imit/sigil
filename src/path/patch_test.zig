//! Tests for `path/patch.zig` (plan 005 item 4): RFC 6902 appendix A (the successes and the
//! failing A.9, A.12, A.15), every `PatchError` variant, atomicity (a failing op leaves the root
//! as it was), no aliasing of the operands, the `nesting_max` boundary, allocation failure at
//! every point, and a seeded model against a plain `ArrayList` reference. Fixtures are JSON text
//! parsed by `json.dom` (a test-only import: `path` itself imports `core` alone). Expected
//! documents list map keys in the order this implementation keeps (new keys appended), because
//! `core.value.eql` is order-sensitive although RFC 6902 does not care.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("../json/dom.zig");
const patch = @import("patch.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;
const parse_options: dom.ParseOptions = .{ .depth_max = nesting_max, .duplicate_key = .reject };

fn parse_json(tree: *ValueTree, text: []const u8) !Value {
    var diag = Diagnostics.init(0, 0, "", null);
    return try dom.parse(tree, text, parse_options, &diag);
}

fn blank_diag() Diagnostics {
    return Diagnostics.init(0, 0, "", null);
}

/// Applies `ops_text` to `doc_text` and compares with `expected_text`. The ops tree is freed
/// before the comparison, so a result that aliased it would read freed memory.
fn expect_patch(doc_text: []const u8, ops_text: []const u8, expected_text: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, doc_text);
    {
        var ops_tree: ValueTree = undefined;
        ops_tree.init(std.testing.allocator);
        defer ops_tree.deinit();
        const ops = try parse_json(&ops_tree, ops_text);
        var diag = blank_diag();
        try patch.apply(&tree, &ops, &diag);
        try expectEqual(@as(u32, 0), diag.message_len);
    }
    var expected_tree: ValueTree = undefined;
    expected_tree.init(std.testing.allocator);
    defer expected_tree.deinit();
    const expected = try parse_json(&expected_tree, expected_text);
    try expect(try core.value.eql(tree.root, expected));
}

/// Applies `ops_text` to `doc_text`, expects `err`, and returns with the diagnostics message
/// copied into `message` (so the caller can look at it). The root must be untouched.
fn expect_fail(doc_text: []const u8, ops_text: []const u8, err: anyerror, message: []u8) !usize {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, doc_text);
    const before = tree.root;
    var ops_tree: ValueTree = undefined;
    ops_tree.init(std.testing.allocator);
    defer ops_tree.deinit();
    const ops = try parse_json(&ops_tree, ops_text);
    var diag = blank_diag();
    try std.testing.expectError(err, patch.apply(&tree, &ops, &diag));
    var snapshot_tree: ValueTree = undefined;
    snapshot_tree.init(std.testing.allocator);
    defer snapshot_tree.deinit();
    try expect(try core.value.eql(tree.root, try parse_json(&snapshot_tree, doc_text)));
    try expect(try core.value.eql(tree.root, before));
    @memcpy(message[0..diag.message().len], diag.message());
    return diag.message().len;
}

/// `expect_error` for a patch of the single operation `op`.
fn fails(doc_text: []const u8, comptime op: []const u8, err: anyerror) !void {
    try expect_error(doc_text, "[" ++ op ++ "]", err);
}

fn expect_error(doc_text: []const u8, ops_text: []const u8, err: anyerror) !void {
    var buffer: [256]u8 = undefined;
    const length = try expect_fail(doc_text, ops_text, err, &buffer);
    try expect(length > 0);
}

test "patch: RFC 6902 appendix A, the operations that succeed" {
    const Row = struct { doc: []const u8, ops: []const u8, result: []const u8 };
    const table = [_]Row{
        // A.1 (the RFC lists "baz" first; a new key is appended here).
        .{
            .doc = "{\"foo\":\"bar\"}",
            .ops = "[{\"op\":\"add\",\"path\":\"/baz\",\"value\":\"qux\"}]",
            .result = "{\"foo\":\"bar\",\"baz\":\"qux\"}",
        },
        // A.2
        .{
            .doc = "{\"foo\":[\"bar\",\"baz\"]}",
            .ops = "[{\"op\":\"add\",\"path\":\"/foo/1\",\"value\":\"qux\"}]",
            .result = "{\"foo\":[\"bar\",\"qux\",\"baz\"]}",
        },
        // A.3
        .{
            .doc = "{\"baz\":\"qux\",\"foo\":\"bar\"}",
            .ops = "[{\"op\":\"remove\",\"path\":\"/baz\"}]",
            .result = "{\"foo\":\"bar\"}",
        },
        // A.4
        .{
            .doc = "{\"foo\":[\"bar\",\"qux\",\"baz\"]}",
            .ops = "[{\"op\":\"remove\",\"path\":\"/foo/1\"}]",
            .result = "{\"foo\":[\"bar\",\"baz\"]}",
        },
        // A.5
        .{
            .doc = "{\"baz\":\"qux\",\"foo\":\"bar\"}",
            .ops = "[{\"op\":\"replace\",\"path\":\"/baz\",\"value\":\"boo\"}]",
            .result = "{\"baz\":\"boo\",\"foo\":\"bar\"}",
        },
        // A.6
        .{
            .doc = "{\"foo\":{\"bar\":\"baz\",\"waldo\":\"fred\"},\"qux\":{\"corge\":\"grault\"}}",
            .ops = "[{\"op\":\"move\",\"from\":\"/foo/waldo\",\"path\":\"/qux/thud\"}]",
            .result = "{\"foo\":{\"bar\":\"baz\"}," ++
                "\"qux\":{\"corge\":\"grault\",\"thud\":\"fred\"}}",
        },
        // A.7
        .{
            .doc = "{\"foo\":[\"all\",\"grass\",\"cows\",\"eat\"]}",
            .ops = "[{\"op\":\"move\",\"from\":\"/foo/1\",\"path\":\"/foo/3\"}]",
            .result = "{\"foo\":[\"all\",\"cows\",\"eat\",\"grass\"]}",
        },
        // A.8, then the same document unchanged.
        .{
            .doc = "{\"baz\":\"qux\",\"foo\":[\"a\",2,\"c\"]}",
            .ops = "[{\"op\":\"test\",\"path\":\"/baz\",\"value\":\"qux\"}," ++
                "{\"op\":\"test\",\"path\":\"/foo/1\",\"value\":2}]",
            .result = "{\"baz\":\"qux\",\"foo\":[\"a\",2,\"c\"]}",
        },
        // A.10
        .{
            .doc = "{\"foo\":\"bar\"}",
            .ops = "[{\"op\":\"add\",\"path\":\"/child\",\"value\":{\"grandchild\":{}}}]",
            .result = "{\"foo\":\"bar\",\"child\":{\"grandchild\":{}}}",
        },
        // A.11
        .{
            .doc = "{\"foo\":\"bar\"}",
            .ops = "[{\"op\":\"add\",\"path\":\"/baz\",\"value\":\"qux\",\"xyz\":123}]",
            .result = "{\"foo\":\"bar\",\"baz\":\"qux\"}",
        },
        // A.14
        .{
            .doc = "{\"/\":9,\"~1\":10}",
            .ops = "[{\"op\":\"test\",\"path\":\"/~01\",\"value\":10}]",
            .result = "{\"/\":9,\"~1\":10}",
        },
        // A.16
        .{
            .doc = "{\"foo\":[\"bar\"]}",
            .ops = "[{\"op\":\"add\",\"path\":\"/foo/-\",\"value\":[\"abc\",\"def\"]}]",
            .result = "{\"foo\":[\"bar\",[\"abc\",\"def\"]]}",
        },
    };
    try expectEqual(@as(usize, 12), table.len);
    for (table) |row| try expect_patch(row.doc, row.ops, row.result);
}

test "patch: RFC 6902 appendix A, the operations that fail" {
    // A.9 test fails; A.15 a string is not the number; A.12 the parent of an add is absent.
    try expect_error(
        "{\"baz\":\"qux\"}",
        "[{\"op\":\"test\",\"path\":\"/baz\",\"value\":\"bar\"}]",
        error.TestFailed,
    );
    try expect_error(
        "{\"/\":9,\"~1\":10}",
        "[{\"op\":\"test\",\"path\":\"/~01\",\"value\":\"10\"}]",
        error.TestFailed,
    );
    try expect_error(
        "{\"foo\":\"bar\"}",
        "[{\"op\":\"add\",\"path\":\"/baz/bat\",\"value\":\"qux\"}]",
        error.PathNotFound,
    );
}

test "patch: replace, add and remove at the root; copy and move" {
    try expect_patch("[1]", "[{\"op\":\"add\",\"path\":\"\",\"value\":{\"a\":1}}]", "{\"a\":1}");
    try expect_patch("[1]", "[{\"op\":\"replace\",\"path\":\"\",\"value\":null}]", "null");
    const same = "{\"a\":1}";
    try expect_patch(same, "[{\"op\":\"test\",\"path\":\"\",\"value\":{\"a\":1}}]", same);
    try expect_patch(
        "{\"a\":{\"b\":[1,2]},\"c\":0}",
        "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/d\"}," ++
            "{\"op\":\"add\",\"path\":\"/d/b/-\",\"value\":3}]",
        "{\"a\":{\"b\":[1,2]},\"c\":0,\"d\":{\"b\":[1,2,3]}}",
    );
    try expect_patch(
        "{\"a\":{\"b\":1},\"c\":0}",
        "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/c\"}]",
        "{\"c\":{\"b\":1}}",
    );
    // Later ops see earlier ones; moving a value onto its own location is a no-op.
    try expect_patch(
        "{\"a\":[1,2,3]}",
        "[{\"op\":\"add\",\"path\":\"/b\",\"value\":[]}," ++
            "{\"op\":\"move\",\"from\":\"/a/0\",\"path\":\"/b/0\"}," ++
            "{\"op\":\"move\",\"from\":\"/a/0\",\"path\":\"/a/0\"}]",
        "{\"a\":[2,3],\"b\":[1]}",
    );
    // A key that exists keeps its place; escapes decode into the new key.
    try expect_patch(
        "{\"x\":1,\"y\":2}",
        "[{\"op\":\"add\",\"path\":\"/x\",\"value\":5}," ++
            "{\"op\":\"add\",\"path\":\"/a~1b~0\",\"value\":6}]",
        "{\"x\":5,\"y\":2,\"a/b~\":6}",
    );
}

test "patch: every PatchError variant is provoked" {
    const doc = "{\"a\":[1,2],\"s\":\"t\"}";
    // InvalidPatch: not an array, an op that is not a map, missing or mistyped members.
    try expect_error(doc, "{\"op\":\"add\"}", error.InvalidPatch);
    try expect_error(doc, "[1]", error.InvalidPatch);
    try fails(doc, "{\"path\":\"/a\",\"value\":1}", error.InvalidPatch);
    try fails(doc, "{\"op\":7,\"path\":\"/a\",\"value\":1}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"add\",\"value\":1}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"add\",\"path\":3,\"value\":1}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"add\",\"path\":\"/z\"}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"test\",\"path\":\"/s\"}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"move\",\"path\":\"/z\"}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"copy\",\"from\":1,\"path\":\"/z\"}", error.InvalidPatch);
    try fails(doc, "{\"op\":\"remove\",\"path\":\"\"}", error.InvalidPatch);
    // UnknownOp.
    try fails(doc, "{\"op\":\"merge\",\"path\":\"/a\"}", error.UnknownOp);
    try fails(doc, "{\"op\":\"ADD\",\"path\":\"/a\",\"value\":1}", error.UnknownOp);
    // InvalidPointer in path and in from; TooDeep pointer.
    try fails(doc, "{\"op\":\"remove\",\"path\":\"a\"}", error.InvalidPointer);
    try fails(doc, "{\"op\":\"add\",\"path\":\"/~2\",\"value\":1}", error.InvalidPointer);
    try fails(doc, "{\"op\":\"move\",\"from\":\"x\",\"path\":\"/z\"}", error.InvalidPointer);
    const deep_path = "[{\"op\":\"remove\",\"path\":\"" ++ ("/a" ** (nesting_max + 1)) ++ "\"}]";
    try expect_error(doc, deep_path, error.TooDeep);
    // PathNotFound: missing key, scalar parent, malformed index, `-` where a node is needed.
    try fails(doc, "{\"op\":\"remove\",\"path\":\"/zzz\"}", error.PathNotFound);
    try fails(doc, "{\"op\":\"replace\",\"path\":\"/zzz\",\"value\":1}", error.PathNotFound);
    try fails(doc, "{\"op\":\"add\",\"path\":\"/s/x\",\"value\":1}", error.PathNotFound);
    try fails(doc, "{\"op\":\"add\",\"path\":\"/a/01\",\"value\":1}", error.PathNotFound);
    try fails(doc, "{\"op\":\"remove\",\"path\":\"/a/-\"}", error.PathNotFound);
    try fails(doc, "{\"op\":\"replace\",\"path\":\"/a/-\",\"value\":1}", error.PathNotFound);
    try fails(doc, "{\"op\":\"copy\",\"from\":\"/q\",\"path\":\"/z\"}", error.PathNotFound);
    try fails(doc, "{\"op\":\"move\",\"from\":\"/q\",\"path\":\"/z\"}", error.PathNotFound);
    try fails(doc, "{\"op\":\"test\",\"path\":\"/q\",\"value\":1}", error.PathNotFound);
    try fails(doc, "{\"op\":\"move\",\"from\":\"/q\",\"path\":\"/q\"}", error.PathNotFound);
    // IndexOutOfRange: add past the length, remove/replace/test-style access at the length.
    try fails(doc, "{\"op\":\"add\",\"path\":\"/a/3\",\"value\":1}", error.IndexOutOfRange);
    try fails(doc, "{\"op\":\"remove\",\"path\":\"/a/2\"}", error.IndexOutOfRange);
    try fails(doc, "{\"op\":\"replace\",\"path\":\"/a/2\",\"value\":1}", error.IndexOutOfRange);
    // TestFailed, InvalidMove.
    try fails(doc, "{\"op\":\"test\",\"path\":\"/a/0\",\"value\":2}", error.TestFailed);
    try fails(doc, "{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a/0\"}", error.InvalidMove);
    try fails(doc, "{\"op\":\"move\",\"from\":\"\",\"path\":\"/a\"}", error.InvalidMove);
}

test "patch: a failing op leaves the whole patch unapplied and says which op" {
    var buffer: [256]u8 = undefined;
    const length = try expect_fail(
        "{\"a\":1}",
        "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2},{\"op\":\"remove\",\"path\":\"/zzz\"}]",
        error.PathNotFound,
        &buffer,
    );
    try expect(std.mem.startsWith(u8, buffer[0..length], "op 1: "));
    try expect(std.mem.find(u8, buffer[0..length], "does not exist") != null);
    const first = try expect_fail("[]", "{}", error.InvalidPatch, &buffer);
    try expect(first > 0);
    const zero = try expect_fail(
        "[]",
        "[{\"op\":\"nope\",\"path\":\"\"}]",
        error.UnknownOp,
        &buffer,
    );
    try expect(std.mem.startsWith(u8, buffer[0..zero], "op 0: "));
    // An empty patch is valid and changes nothing.
    try expect_patch("{\"a\":[1]}", "[]", "{\"a\":[1]}");
}

test "patch: nothing the tree holds aliases the operands, and the old root keeps its content" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try parse_json(&tree, "{\"keep\":{\"deep\":[1,2,3]},\"edit\":[0,1]}");
    const before = tree.root;
    const keep = tree.root.map.get("keep").?.*;
    {
        var ops_tree: ValueTree = undefined;
        ops_tree.init(std.testing.allocator);
        defer ops_tree.deinit();
        const ops = try parse_json(
            &ops_tree,
            "[{\"op\":\"add\",\"path\":\"/edit/1\",\"value\":{\"k\":\"text\"}}," ++
                "{\"op\":\"copy\",\"from\":\"/edit/1\",\"path\":\"/edit/-\"}]",
        );
        var diag = blank_diag();
        try patch.apply(&tree, &ops, &diag);
    }
    const edit = tree.root.map.get("edit").?.array;
    try expectEqual(@as(usize, 4), edit.len);
    try expectEqualStrings("text", edit[1].map.get("k").?.string);
    try expectEqualStrings("text", edit[3].map.get("k").?.string);
    // Untouched siblings are shared; copy produced an independent subtree; the old root is whole.
    try expect(tree.root.map.get("keep").?.map.entries.ptr == keep.map.entries.ptr);
    try expect(edit[1].map.entries.ptr != edit[3].map.entries.ptr);
    try expectEqual(@as(usize, 2), before.map.get("edit").?.array.len);
    try expect(tree.root.map.entries.ptr != before.map.entries.ptr);
}

const expectEqualStrings = std.testing.expectEqualStrings;

fn nested_arrays(tree: *ValueTree, levels: u32, leaf: Value) !Value {
    var node = leaf;
    for (0..levels) |_| node = try tree.dupe_array(&.{node});
    return node;
}

fn op_add(tree: *ValueTree, path: []const u8, value: Value) !Value {
    var map = try tree.new_map(3);
    try map.put("op", .{ .string = "add" });
    try map.put("path", .{ .string = path });
    try map.put("value", value);
    return .{ .map = map };
}

test "patch: nesting_max is accepted, one level past it is TooDeep with the root intact" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    tree.root = try tree.dupe_array(&.{.null});

    // The root array is level 1; a value added at /0 may nest nesting_max - 1 more levels.
    const fits = try nested_arrays(&tree, nesting_max - 1, .null);
    const too_deep = try nested_arrays(&tree, nesting_max, .null);
    const ok_ops = Value{ .array = &.{try op_add(&tree, "/0", fits)} };
    var diag = blank_diag();
    try patch.apply(&tree, &ok_ops, &diag);

    const bad_ops = Value{ .array = &.{try op_add(&tree, "/0", too_deep)} };
    const before = tree.root;
    try std.testing.expectError(error.TooDeep, patch.apply(&tree, &bad_ops, &diag));
    try expect(tree.root.array.ptr == before.array.ptr);
    try expect(std.mem.find(u8, diag.message(), "op 0: ") != null);
    // Replacing the root is checked from level 0.
    const root_fits = try nested_arrays(&tree, nesting_max, .null);
    const root_ops = Value{ .array = &.{try op_add(&tree, "", root_fits)} };
    try patch.apply(&tree, &root_ops, &diag);
    const root_deep = try nested_arrays(&tree, nesting_max + 1, .null);
    const root_bad = Value{ .array = &.{try op_add(&tree, "", root_deep)} };
    try std.testing.expectError(error.TooDeep, patch.apply(&tree, &root_bad, &diag));
    // Moving a full-depth subtree one level further down is TooDeep too, and nothing moves.
    const full = try nested_arrays(&tree, nesting_max - 1, .null);
    tree.root = try tree.dupe_array(&.{ full, try tree.dupe_array(&.{.null}) });
    const move_ops = Value{ .array = &.{try op_move(&tree, "/0", "/1/0")} };
    try std.testing.expectError(error.TooDeep, patch.apply(&tree, &move_ops, &diag));
    try expectEqual(@as(usize, 1), tree.root.array[1].array.len);
    try expectEqual(@as(usize, 1), tree.root.array[0].array.len);
}

fn op_move(tree: *ValueTree, from: []const u8, path: []const u8) !Value {
    var map = try tree.new_map(3);
    try map.put("op", .{ .string = "move" });
    try map.put("from", .{ .string = from });
    try map.put("path", .{ .string = path });
    return .{ .map = map };
}

test "patch: allocation failure at every point leaves the root unchanged" {
    var doc_tree: ValueTree = undefined;
    doc_tree.init(std.testing.allocator);
    defer doc_tree.deinit();
    const doc = try parse_json(&doc_tree, "{\"a\":{\"b\":[1,2]},\"c\":\"x\"}");
    var ops_tree: ValueTree = undefined;
    ops_tree.init(std.testing.allocator);
    defer ops_tree.deinit();
    const ops = try parse_json(
        &ops_tree,
        "[{\"op\":\"add\",\"path\":\"/a/b/1\",\"value\":{\"k\":[true]}}," ++
            "{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/d\"}," ++
            "{\"op\":\"move\",\"from\":\"/c\",\"path\":\"/e\"}," ++
            "{\"op\":\"remove\",\"path\":\"/a/b/0\"}]",
    );
    var failures: u32 = 0;
    var finished = false;
    for (0..200) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        tree.root = doc;
        var diag = blank_diag();
        // proof: `PatchError` has no I/O variant besides the ones handled; no `error.Canceled`.
        patch.apply(&tree, &ops, &diag) catch |err| switch (err) {
            error.OutOfMemory => {
                failures += 1;
                try expect(tree.root.map.entries.ptr == doc.map.entries.ptr);
                try expect(std.mem.startsWith(u8, diag.message(), "op "));
                continue;
            },
            else => return err,
        };
        finished = true;
        break;
    }
    try expect(finished);
    try expect(failures >= 1);
}

test "patch: model against an ArrayList over 1,000 seeds" {
    var tally_failed: u32 = 0;
    var tally_move: u32 = 0;
    var tally_copy: u32 = 0;
    for (0..1000) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();
        var model: std.ArrayList(i64) = .empty;
        defer model.deinit(std.testing.allocator);
        const start_len = random.uintLessThan(u32, 5);
        var start: [4]Value = undefined;
        for (0..start_len) |index| {
            start[index] = .{ .int = @intCast(index) };
            try model.append(std.testing.allocator, @intCast(index));
        }
        tree.root = try tree.dupe_array(start[0..start_len]);

        for (0..6) |_| {
            const kind = random.uintLessThan(u32, 5);
            const len: u32 = @intCast(model.items.len);
            const at = random.uintLessThan(u32, len + 2); // Sometimes past the end.
            const to = random.uintLessThan(u32, len + 2);
            var path_buf: [16]u8 = undefined;
            var from_buf: [16]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/{d}", .{at});
            const from = try std.fmt.bufPrint(&from_buf, "/{d}", .{to});
            const value: i64 = random.intRangeAtMost(i64, 10, 99);
            const op = switch (kind) {
                0 => try op_add(&tree, path, .{ .int = value }),
                1 => try op_simple(&tree, "remove", path, null),
                2 => try op_simple(&tree, "replace", path, .{ .int = value }),
                3 => try op_move(&tree, from, path),
                else => try op_copy(&tree, from, path),
            };
            const ops = Value{ .array = &.{op} };
            const ok = model_apply(&model, kind, at, to, value);
            const root_before = tree.root;
            var diag = blank_diag();
            if (patch.apply(&tree, &ops, &diag)) |_| {
                try expect(ok);
            } else |err| switch (err) { // proof: only IndexOutOfRange is expected; no I/O.
                error.IndexOutOfRange => {
                    try expect(!ok);
                    tally_failed += 1;
                    try expect(tree.root.array.ptr == root_before.array.ptr);
                },
                else => return err,
            }
            if (ok and kind == 3) tally_move += 1;
            if (ok and kind == 4) tally_copy += 1;
            try expectEqual(model.items.len, tree.root.array.len);
            for (model.items, tree.root.array) |want, got| try expectEqual(want, got.int);
        }
    }
    try expect(tally_failed > 0);
    try expect(tally_move > 0);
    try expect(tally_copy > 0);
}

fn op_simple(tree: *ValueTree, name: []const u8, path: []const u8, value: ?Value) !Value {
    var map = try tree.new_map(3);
    try map.put("op", .{ .string = name });
    try map.put("path", .{ .string = path });
    if (value) |v| try map.put("value", v);
    return .{ .map = map };
}

fn op_copy(tree: *ValueTree, from: []const u8, path: []const u8) !Value {
    var map = try tree.new_map(3);
    try map.put("op", .{ .string = "copy" });
    try map.put("from", .{ .string = from });
    try map.put("path", .{ .string = path });
    return .{ .map = map };
}

/// The reference semantics over a list of integers; false (and no change) where RFC 6902 says
/// the op fails: add past the length, anything else at or past the length.
fn model_apply(model: *std.ArrayList(i64), kind: u32, at: u32, to: u32, value: i64) bool {
    const len: u32 = @intCast(model.items.len);
    const gpa = std.testing.allocator;
    switch (kind) {
        0 => {
            if (at > len) return false;
            model.insert(gpa, at, value) catch unreachable; // proof: test allocator, tiny list.
        },
        1 => {
            if (at >= len) return false;
            _ = model.orderedRemove(at);
        },
        2 => {
            if (at >= len) return false;
            model.items[at] = value;
        },
        3 => {
            if (to >= len) return false;
            const moved = model.orderedRemove(to);
            if (at > model.items.len) {
                model.insert(gpa, to, moved) catch unreachable; // proof: restoring the removal.
                return false;
            }
            model.insert(gpa, at, moved) catch unreachable; // proof: test allocator, tiny list.
        },
        else => {
            if (to >= len) return false;
            if (at > len) return false;
            model.insert(gpa, at, model.items[to]) catch unreachable; // proof: tiny list.
        },
    }
    return true;
}

//! Tests for `path/select.zig` (plan 005 item 6): the RFC 9535 section 1.5 bookstore queries
//! that need no filter, the section 2.3 selector tables (index, wildcard, slice) and the section
//! 2.5.2 descendant examples with their expected results copied from the RFC, empty and
//! scalar inputs, duplicates, the `out` boundary (`OutOfSpace` one short), the `nesting_max`
//! boundary (`TooDeep` one deeper), and a seeded model against a level-by-level reference that
//! follows the RFC nodelist definition and Python slice arithmetic instead of the frame stack.
//! Documents are JSON text parsed by `json.dom` (a test-only import: `path` imports `core`).

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("../json/dom.zig");
const writer = @import("../json/writer.zig");
const jsonpath = @import("jsonpath.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Diagnostics = core.Diagnostics;
const Program = jsonpath.Program;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;
const parse_options: dom.ParseOptions = .{ .depth_max = nesting_max, .duplicate_key = .reject };
const render_options: writer.StringifyOptions = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = nesting_max,
};

const bookstore =
    \\{"store":{"book":[
    \\{"category":"reference","author":"Nigel Rees","title":"Sayings of the Century","price":8.95},
    \\{"category":"fiction","author":"Evelyn Waugh","title":"Sword of Honour","price":12.99},
    \\{"category":"fiction","author":"Herman Melville","title":"Moby Dick","isbn":"0-553-21311-3",
    \\"price":8.99},
    \\{"category":"fiction","author":"J. R. R. Tolkien","title":"The Lord of the Rings",
    \\"isbn":"0-395-19395-8","price":22.99}],
    \\"bicycle":{"color":"red","price":399}}}
;

fn compile(query: []const u8) !Program {
    var program: Program = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    jsonpath.compile(&program, query, &diag) catch |err| {
        std.log.err("query '{s}' failed with {s}: {f}", .{ query, @errorName(err), &diag });
        return err;
    };
    program.check_invariants();
    return program;
}

/// Parses `doc`, selects `query`, and compares the JSON rendering of each result in order.
fn expect_select(doc: []const u8, query: []const u8, expected: []const []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, doc, parse_options, &diag);
    const program = try compile(query);

    var out: [64]*const Value = undefined;
    const nodes = try jsonpath.select(&program, &root, &out);
    try expectEqual(expected.len, nodes.len);
    try expect(nodes.ptr == out[0..].ptr);
    for (nodes, expected) |node, want| {
        var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer text.deinit();
        try writer.write(&text.writer, node.*, render_options, &diag);
        try expectEqualStrings(want, text.written());
    }
}

test "select: RFC 9535 section 1.5 bookstore queries without filters" {
    try expect_select(bookstore, "$.store.book[*].author", &.{
        "\"Nigel Rees\"",
        "\"Evelyn Waugh\"",
        "\"Herman Melville\"",
        "\"J. R. R. Tolkien\"",
    });
    try expect_select(bookstore, "$..author", &.{
        "\"Nigel Rees\"",
        "\"Evelyn Waugh\"",
        "\"Herman Melville\"",
        "\"J. R. R. Tolkien\"",
    });
    try expect_select(bookstore, "$.store..price", &.{ "8.95", "12.99", "8.99", "22.99", "399" });
    try expect_select(bookstore, "$..book[2].author", &.{"\"Herman Melville\""});
    try expect_select(bookstore, "$..book[2].publisher", &.{});
    try expect_select(bookstore, "$..book[-1].title", &.{"\"The Lord of the Rings\""});
    try expect_select(bookstore, "$..book[0,1].price", &.{ "8.95", "12.99" });
    try expect_select(bookstore, "$..book[:2].price", &.{ "8.95", "12.99" });
}

test "select: bookstore child wildcard, indexed book and the whole-document wildcard" {
    try expect_select(bookstore, "$.store.*", &.{
        "[{\"category\":\"reference\",\"author\":\"Nigel Rees\"," ++
            "\"title\":\"Sayings of the Century\",\"price\":8.95}," ++
            "{\"category\":\"fiction\",\"author\":\"Evelyn Waugh\"," ++
            "\"title\":\"Sword of Honour\",\"price\":12.99}," ++
            "{\"category\":\"fiction\",\"author\":\"Herman Melville\"," ++
            "\"title\":\"Moby Dick\",\"isbn\":\"0-553-21311-3\",\"price\":8.99}," ++
            "{\"category\":\"fiction\",\"author\":\"J. R. R. Tolkien\"," ++
            "\"title\":\"The Lord of the Rings\",\"isbn\":\"0-395-19395-8\",\"price\":22.99}]",
        "{\"color\":\"red\",\"price\":399}",
    });
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, bookstore, parse_options, &diag);
    const program = try compile("$..*");
    var out: [64]*const Value = undefined;
    const nodes = try jsonpath.select(&program, &root, &out);
    try expect_select("{\"a\":[1,{\"b\":2}],\"c\":3}", "$..*", &.{
        "[1,{\"b\":2}]", "3", "1", "{\"b\":2}", "2",
    });
    // store, book, bicycle, 4 books (4+4+5+5 members), bicycle's 2 members, 18 book members.
    try expectEqual(@as(usize, 1 + 2 + 4 + 2 + 18), nodes.len);
}

test "select: RFC 9535 section 2.3 index, wildcard and slice tables" {
    const letters = "[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\"]";
    try expect_select(letters, "$[1]", &.{"\"b\""});
    try expect_select(letters, "$[-2]", &.{"\"f\""});
    try expect_select(letters, "$[7]", &.{});
    try expect_select(letters, "$[-8]", &.{});
    try expect_select(letters, "$[1:3]", &.{ "\"b\"", "\"c\"" });
    try expect_select(letters, "$[5:]", &.{ "\"f\"", "\"g\"" });
    try expect_select(letters, "$[1:5:2]", &.{ "\"b\"", "\"d\"" });
    try expect_select(letters, "$[5:1:-2]", &.{ "\"f\"", "\"d\"" });
    try expect_select(letters, "$[::-1]", &.{
        "\"g\"", "\"f\"", "\"e\"", "\"d\"", "\"c\"", "\"b\"", "\"a\"",
    });
    try expect_select(letters, "$[::0]", &.{});
    try expect_select(letters, "$[-3:]", &.{ "\"e\"", "\"f\"", "\"g\"" });
    try expect_select(letters, "$[:-5]", &.{ "\"a\"", "\"b\"" });
    try expect_select(letters, "$[100:200]", &.{});
    try expect_select(letters, "$[-100:2]", &.{ "\"a\"", "\"b\"" });
    try expect_select(letters, "$[0:100:3]", &.{ "\"a\"", "\"d\"", "\"g\"" });
    try expect_select(letters, "$[2:2]", &.{});
    try expect_select(letters, "$[10:0:-1]", &.{
        "\"g\"", "\"f\"", "\"e\"", "\"d\"", "\"c\"", "\"b\"",
    });
    try expect_select(letters, "$[:-100:-1]", &.{
        "\"g\"", "\"f\"", "\"e\"", "\"d\"", "\"c\"", "\"b\"", "\"a\"",
    });
    try expect_select(letters, "$[-100::-1]", &.{});
    try expect_select(letters, "$[0:0:-1]", &.{});
    try expect_select(letters, "$[-1:-4:-1]", &.{ "\"g\"", "\"f\"", "\"e\"" });
    try expect_select(letters, "$[::9007199254740991]", &.{"\"a\""});
    try expect_select(letters, "$[::-9007199254740991]", &.{"\"g\""});
    try expect_select(letters, "$[-9007199254740991]", &.{});
    try expect_select(letters, "$[9007199254740991]", &.{});
    try expect_select(letters, "$[-9007199254740991:9007199254740991]", &.{
        "\"a\"", "\"b\"", "\"c\"", "\"d\"", "\"e\"", "\"f\"", "\"g\"",
    });

    const object = "{\"o\":{\"j\":1,\"k\":2},\"a\":[5,3]}";
    try expect_select(object, "$[*]", &.{ "{\"j\":1,\"k\":2}", "[5,3]" });
    try expect_select(object, "$.o[*]", &.{ "1", "2" });
    try expect_select(object, "$.o[*, *]", &.{ "1", "2", "1", "2" });
    try expect_select(object, "$.a[*]", &.{ "5", "3" });
    try expect_select(object, "$['o','a']", &.{ "{\"j\":1,\"k\":2}", "[5,3]" });
    try expect_select(object, "$['a','o','a']", &.{ "[5,3]", "{\"j\":1,\"k\":2}", "[5,3]" });
}

test "select: RFC 9535 section 2.5.2 descendant examples" {
    const doc = "{\"o\":{\"j\":1,\"k\":2},\"a\":[5,3,[{\"j\":4},{\"k\":6}]]}";
    try expect_select(doc, "$..j", &.{ "1", "4" });
    try expect_select(doc, "$..[0]", &.{ "5", "{\"j\":4}" });
    try expect_select(doc, "$..[1]", &.{ "3", "{\"k\":6}" });
    try expect_select(doc, "$..[*]", &.{
        "{\"j\":1,\"k\":2}",
        "[5,3,[{\"j\":4},{\"k\":6}]]",
        "1",
        "2",
        "5",
        "3",
        "[{\"j\":4},{\"k\":6}]",
        "{\"j\":4}",
        "{\"k\":6}",
        "4",
        "6",
    });
    try expect_select(doc, "$..*", &.{
        "{\"j\":1,\"k\":2}",
        "[5,3,[{\"j\":4},{\"k\":6}]]",
        "1",
        "2",
        "5",
        "3",
        "[{\"j\":4},{\"k\":6}]",
        "{\"j\":4}",
        "{\"k\":6}",
        "4",
        "6",
    });
    try expect_select(doc, "$..o", &.{"{\"j\":1,\"k\":2}"});
    try expect_select(doc, "$.o..j", &.{"1"});
    try expect_select(doc, "$..['j','k']", &.{ "1", "2", "4", "6" });
}

test "select: the root, scalars, empty containers and selectors of the wrong kind" {
    try expect_select("{\"a\":1}", "$", &.{"{\"a\":1}"});
    try expect_select("7", "$", &.{"7"});
    try expect_select("7", "$.a", &.{});
    try expect_select("7", "$[*]", &.{});
    try expect_select("7", "$..*", &.{});
    try expect_select("null", "$..[0]", &.{});
    try expect_select("[]", "$[*]", &.{});
    try expect_select("{}", "$[*]", &.{});
    try expect_select("[]", "$..*", &.{});
    try expect_select("{}", "$..*", &.{});
    try expect_select("[]", "$[0]", &.{});
    try expect_select("[]", "$[::-1]", &.{});
    try expect_select("[1,2]", "$.a", &.{});
    try expect_select("{\"0\":1}", "$[0]", &.{});
    try expect_select("{\"0\":1}", "$[0:1]", &.{});
    try expect_select("[[1]]", "$[0][0][0]", &.{});
    try expect_select("{\"a\":{\"b\":null}}", "$.a.b", &.{"null"});
    try expect_select("{\"a\":{\"b\":null}}", "$.a.b.c", &.{});
}

test "select: duplicates are kept and a missing name selects nothing between hits" {
    try expect_select("[10,20]", "$[0,0]", &.{ "10", "10" });
    try expect_select("[10,20]", "$[1,0,1]", &.{ "20", "10", "20" });
    try expect_select("[10,20]", "$[0,5,1]", &.{ "10", "20" });
    try expect_select("[10,20]", "$[-1,1]", &.{ "20", "20" });
    try expect_select("{\"a\":[1,2]}", "$..a[*,*]", &.{ "1", "2", "1", "2" });
    try expect_select("{\"a\":{\"a\":1}}", "$..a", &.{ "{\"a\":1}", "1" });
}

test "select: a result is a pointer into the tree, not a copy" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, "{\"a\":[1,2],\"b\":3}", parse_options, &diag);
    const program = try compile("$.a[1]");
    var out: [4]*const Value = undefined;
    const nodes = try jsonpath.select(&program, &root, &out);
    try expectEqual(@as(usize, 1), nodes.len);
    try expect(nodes[0] == &root.map.get("a").?.array[1]);

    const all = try compile("$[*]");
    const children = try jsonpath.select(&all, &root, &out);
    try expect(children[0] == root.map.get("a").?);
    try expect(children[1] == root.map.get("b").?);
}

test "select: OutOfSpace exactly one past out.len, empty results need no room" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, "[1,2,3]", parse_options, &diag);
    const program = try compile("$[*]");

    var out: [3]*const Value = undefined;
    const exact = try jsonpath.select(&program, &root, &out);
    try expectEqual(@as(usize, 3), exact.len);
    try std.testing.expectError(error.OutOfSpace, jsonpath.select(&program, &root, out[0..2]));
    try std.testing.expectError(error.OutOfSpace, jsonpath.select(&program, &root, out[0..0]));

    const nothing = try compile("$[5]");
    const none = try jsonpath.select(&nothing, &root, out[0..0]);
    try expectEqual(@as(usize, 0), none.len);

    const root_query = try compile("$");
    try std.testing.expectError(error.OutOfSpace, jsonpath.select(&root_query, &root, out[0..0]));
    const one = try jsonpath.select(&root_query, &root, out[0..1]);
    try expect(one[0] == &root);

    const twice = try compile("$[0,0]");
    try std.testing.expectError(error.OutOfSpace, jsonpath.select(&twice, &root, out[0..1]));
    try expectEqual(@as(usize, 2), (try jsonpath.select(&twice, &root, out[0..2])).len);
}

/// Fills `levels[0..count]` with `count` arrays nested one in the next; the innermost is empty.
fn nest_arrays(levels: []Value, count: usize) void {
    std.debug.assert(count >= 1);
    std.debug.assert(count <= levels.len);
    levels[count - 1] = .{ .array = &.{} };
    var index = count - 1;
    while (index > 0) {
        index -= 1;
        levels[index] = .{ .array = levels[index + 1 ..][0..1] };
    }
}

test "select: nesting_max containers deep is accepted and one deeper is TooDeep" {
    var levels: [nesting_max + 1]Value = undefined;
    var out: [nesting_max + 1]*const Value = undefined;
    const program = try compile("$..*");

    nest_arrays(&levels, nesting_max);
    const found = try jsonpath.select(&program, &levels[0], &out);
    try expectEqual(@as(usize, nesting_max - 1), found.len);
    try expect(found[found.len - 1] == &levels[nesting_max - 1]);

    nest_arrays(&levels, nesting_max + 1);
    try std.testing.expectError(error.TooDeep, jsonpath.select(&program, &levels[0], &out));

    // A deep container as the last result needs no frame; a mid-query one does.
    nest_arrays(&levels, nesting_max + 1);
    const last = try compile("$[0]..[0]");
    try std.testing.expectError(error.TooDeep, jsonpath.select(&last, &levels[0], &out));
    nest_arrays(&levels, nesting_max);
    const mid = try compile("$..[0]");
    try expectEqual(@as(usize, nesting_max - 1), (try jsonpath.select(&mid, &levels[0], &out)).len);
    const tail = try compile("$[0][0]");
    nest_arrays(&levels, nesting_max + 1);
    try expectEqual(@as(usize, 1), (try jsonpath.select(&tail, &levels[0], &out)).len);
    try std.testing.expectError(error.TooDeep, jsonpath.select(&mid, &levels[0], &out));

    // A child-only query never pushes a frame for its results, so depth is not reached.
    const shallow = try compile("$[0]");
    const one = try jsonpath.select(&shallow, &levels[0], &out);
    try expectEqual(@as(usize, 1), one.len);
}

/// Python slice arithmetic (PySlice_AdjustIndices), kept apart from the RFC form in select.zig.
fn reference_slice(
    gpa: std.mem.Allocator,
    result: *std.ArrayList(*const Value),
    items: []const Value,
    slice: jsonpath.Slice,
) !void {
    if (slice.step == 0) return;
    const length: i64 = @intCast(items.len);
    var start: i64 = slice.start orelse (if (slice.step > 0) 0 else length - 1);
    var stop: i64 = slice.end orelse (if (slice.step > 0) length else -length - 1);
    for ([_]*i64{ &start, &stop }) |bound| {
        if (bound.* < 0) {
            bound.* += length;
            if (bound.* < 0) bound.* = if (slice.step > 0) 0 else -1;
        } else if (bound.* >= length) {
            bound.* = if (slice.step > 0) length else length - 1;
        }
    }
    var index = start;
    while (if (slice.step > 0) index < stop else index > stop) : (index += slice.step) {
        try result.append(gpa, &items[@intCast(index)]);
    }
}

fn reference_selector(
    gpa: std.mem.Allocator,
    result: *std.ArrayList(*const Value),
    program: *const Program,
    node: *const Value,
    selector: jsonpath.Selector,
) !void {
    switch (selector) {
        .name => |name| if (node.* == .map) {
            if (node.map.get(program.name_text(name))) |found| try result.append(gpa, found);
        },
        .index => |index| if (node.* == .array) {
            const items = node.array;
            const resolved = if (index < 0) index + @as(i64, @intCast(items.len)) else index;
            if (resolved >= 0 and resolved < items.len) {
                try result.append(gpa, &items[@intCast(resolved)]);
            }
        },
        .wildcard => switch (node.*) {
            .array => |items| for (items) |*item| try result.append(gpa, item),
            .map => |*map| for (map.items()) |*entry| try result.append(gpa, &entry.value),
            else => {},
        },
        .slice => |slice| if (node.* == .array) {
            try reference_slice(gpa, result, node.array, slice);
        },
        .filter => unreachable, // proof: the model's generated queries never contain a filter.
    }
}

/// Every node of the subtree at `root` in pre-order, found with a worklist.
fn reference_visit(
    gpa: std.mem.Allocator,
    visit: *std.ArrayList(*const Value),
    root: *const Value,
) !void {
    var work: std.ArrayList(*const Value) = .empty;
    defer work.deinit(gpa);

    try work.append(gpa, root);
    while (work.pop()) |node| {
        try visit.append(gpa, node);
        const base = work.items.len;
        switch (node.*) {
            .array => |items| for (items) |*item| try work.append(gpa, item),
            .map => |*map| for (map.items()) |*entry| try work.append(gpa, &entry.value),
            else => {},
        }
        std.mem.reverse(*const Value, work.items[base..]);
    }
}

/// The RFC 9535 nodelist semantics, one whole list per segment.
fn reference_select(
    gpa: std.mem.Allocator,
    program: *const Program,
    root: *const Value,
) !std.ArrayList(*const Value) {
    var current: std.ArrayList(*const Value) = .empty;
    errdefer current.deinit(gpa);
    try current.append(gpa, root);
    for (program.segment_list()) |segment| {
        var next: std.ArrayList(*const Value) = .empty;
        errdefer next.deinit(gpa);
        for (current.items) |node| {
            var visit: std.ArrayList(*const Value) = .empty;
            defer visit.deinit(gpa);
            if (segment.descendant) {
                try reference_visit(gpa, &visit, node);
            } else {
                try visit.append(gpa, node);
            }
            for (visit.items) |visited| {
                for (program.selector_list(segment)) |selector| {
                    try reference_selector(gpa, &next, program, visited, selector);
                }
            }
        }
        current.deinit(gpa);
        current = next;
    }
    return current;
}

const model_scalars = [_]Value{ .null, .{ .bool = true }, .{ .int = 7 }, .{ .string = "s" } };
const model_keys = [_][]const u8{ "a", "b", "c" };

/// Builds a document bottom-up from a pool: each round adds containers whose members are
/// copies of earlier pool entries, so the shape varies without recursion. The last is the root.
fn model_document(tree: *ValueTree, random: std.Random) !Value {
    var pool: [24]Value = undefined;
    var count: usize = 0;
    for (model_scalars) |scalar| {
        pool[count] = scalar;
        count += 1;
    }
    for (0..16) |_| {
        const members = random.uintAtMost(usize, 3);
        if (random.boolean()) {
            var items: [3]Value = undefined;
            for (items[0..members]) |*item| item.* = pool[random.uintLessThan(usize, count)];
            pool[count] = try tree.dupe_array(items[0..members]);
        } else {
            var map = try tree.new_map(@intCast(members));
            const first = random.uintLessThan(usize, model_keys.len);
            for (0..members) |offset| {
                const key = model_keys[(first + offset) % model_keys.len];
                try map.put(try tree.dupe_key(key), pool[random.uintLessThan(usize, count)]);
            }
            pool[count] = .{ .map = map };
        }
        count += 1;
    }
    return pool[count - 1];
}

fn model_selector(random: std.Random, w: *std.Io.Writer) !void {
    switch (random.uintLessThan(u8, 6)) {
        0 => try w.print("'{s}'", .{model_keys[random.uintLessThan(usize, 3)]}),
        1 => try w.print("{d}", .{random.intRangeAtMost(i32, -4, 4)}),
        2 => try w.writeByte('*'),
        else => {
            if (random.boolean()) try w.print("{d}", .{random.intRangeAtMost(i32, -5, 5)});
            try w.writeByte(':');
            if (random.boolean()) try w.print("{d}", .{random.intRangeAtMost(i32, -5, 5)});
            if (random.boolean()) try w.print(":{d}", .{random.intRangeAtMost(i32, -3, 3)});
        },
    }
}

fn model_query(random: std.Random, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeByte('$');
    var descendants: u32 = 0;
    for (0..random.intRangeAtMost(u8, 1, 3)) |_| {
        // One descendant at most: two nested ones multiply the result size past the reference.
        if (descendants == 0 and random.uintLessThan(u8, 3) == 0) {
            descendants += 1;
            try w.writeAll("..");
        }
        try w.writeByte('[');
        for (0..random.intRangeAtMost(u8, 1, 3)) |index| {
            if (index > 0) try w.writeByte(',');
            try model_selector(random, &w);
        }
        try w.writeByte(']');
    }
    return w.buffered();
}

test "select: seeded model against the level-by-level reference, 400 seeds" {
    const gpa = std.testing.allocator;
    var overflowed: u32 = 0;
    var nonempty: u32 = 0;
    for (0..400) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var tree: ValueTree = undefined;
        tree.init(gpa);
        defer tree.deinit();
        const root = model_document(&tree, random) catch |err| {
            std.log.err("seed {d} document {s}", .{ seed, @errorName(err) });
            return err;
        };
        var text: [256]u8 = undefined;
        const query = model_query(random, &text) catch |err| {
            std.log.err("seed {d} query build {s}", .{ seed, @errorName(err) });
            return err;
        };
        const program = try compile(query);

        var expected = try reference_select(gpa, &program, &root);
        defer expected.deinit(gpa);
        // Even seeds get room for the whole result, odd seeds only three slots.
        var out_buffer: [48]*const Value = undefined;
        const out = out_buffer[0..if (seed % 2 == 0) 48 else 3];
        if (jsonpath.select(&program, &root, out)) |nodes| {
            if (nodes.len > 0) nonempty += 1;
            errdefer std.log.err("seed {d} query '{s}'", .{ seed, query });
            try expectEqual(expected.items.len, nodes.len);
            for (nodes, expected.items) |node, want| try expect(node == want);
        } else |err| {
            errdefer std.log.err("seed {d} query '{s}'", .{ seed, query });
            try expectEqual(error.OutOfSpace, err);
            try expect(expected.items.len > out.len);
            overflowed += 1;
        }
    }
    // Both outcomes must be exercised or the model proves nothing about one of them.
    try expect(overflowed > 0);
    try expect(nonempty > 50);
}

//! reflect/parse array and slice tests — `[N]T` and `[]T` (ADR 0002 sections 2 and 5): length
//! rules, element paths, the one-allocation rule, out-of-memory, and the container depth
//! boundary (128 nested containers pass, the 129th is `TooDeep`) through a recursive type.

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

const Node = struct { children: []const Node = &.{} };

test "array: a fixed array takes exactly N elements" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const got = try rig.ok([3]u8, try rig.ints(&.{ 1, 2, 3 }));
    try testing.expectEqual([3]u8{ 1, 2, 3 }, got);
    try testing.expectEqual([0]u8{}, try rig.ok([0]u8, try rig.arr(&.{})));
    try testing.expectEqual([1]i8{-4}, try rig.ok([1]i8, try rig.ints(&.{-4})));
}

test "array: a wrong length is LengthMismatch and names both lengths" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const short = try rig.ints(&.{ 1, 2 });
    try rig.fails([3]u8, short, error.LengthMismatch, "expected array of length 3, found 2");
    const long = try rig.ints(&.{ 1, 2, 3, 4 });
    try rig.fails([3]u8, long, error.LengthMismatch, "expected array of length 3, found 4");
    const one = try rig.ints(&.{1});
    try rig.fails([0]u8, one, error.LengthMismatch, "expected array of length 0, found 1");
    const empty = try rig.arr(&.{});
    try rig.fails([1]u8, empty, error.LengthMismatch, "expected array of length 1, found 0");
}

test "array: the length is checked before any element" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const strings = try rig.arr(&.{ str("a"), str("b"), str("c") });
    try rig.fails([2]u8, strings, error.LengthMismatch, "expected array of length 2, found 3");
}

test "array: a length error inside a struct carries the field path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const Tagged = struct { tag: [2]u8 };
    const input = try rig.obj(&.{kv("tag", try rig.ints(&.{ 1, 2, 3 }))});
    const message = "tag: expected array of length 2, found 3";
    try rig.fails(Tagged, input, error.LengthMismatch, message);
}

test "array: an element error carries its index and a [N]u8 is an array of ints" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const wide = try rig.ints(&.{ 1, 256 });
    try rig.fails([2]u8, wide, error.IntegerOutOfRange, "[1]: 256 is out of range for u8");
    const mixed = try rig.arr(&.{ int(1), str("x") });
    try rig.fails([2]u8, mixed, error.TypeMismatch, "[1]: expected integer, found string");
    try rig.mismatch([3]u8, str("abc"), "array", "string");
    const Holder = struct { data: [2]u8 };
    const holder = try rig.obj(&.{kv("data", mixed)});
    try rig.fails(Holder, holder, error.TypeMismatch, "data[1]: expected integer, found string");
}

test "array: the largest array parses and arrays nest" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var numbers: [256]i64 = undefined;
    for (&numbers, 0..) |*number, index| number.* = @intCast(index);
    const got = try rig.ok([256]u8, try rig.ints(&numbers));
    for (got, 0..) |byte, index| try testing.expectEqual(@as(u8, @intCast(index)), byte);
    const grid = try rig.arr(&.{ try rig.ints(&.{ 1, 2 }), try rig.ints(&.{ 3, 4 }) });
    try testing.expectEqual([2][2]u8{ .{ 1, 2 }, .{ 3, 4 } }, try rig.ok([2][2]u8, grid));
    const ragged = try rig.arr(&.{ try rig.ints(&.{ 1, 2 }), try rig.ints(&.{3}) });
    const message = "[1]: expected array of length 2, found 1";
    try rig.fails([2][2]u8, ragged, error.LengthMismatch, message);
}

test "array: elements may be structs and optionals" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const a = try rig.obj(&.{ kv("x", int(1)), kv("y", int(2)) });
    const b = try rig.obj(&.{ kv("x", int(3)), kv("y", int(4)) });
    const got = try rig.ok([2]Point, try rig.arr(&.{ a, b }));
    try testing.expectEqual([2]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }, got);
    const holes = try rig.arr(&.{ .null, int(2), .null });
    const parsed = try rig.ok([3]?u8, holes);
    try testing.expectEqual([3]?u8{ null, 2, null }, parsed);
}

test "slice: an array becomes a slice of exactly its length" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const got = try rig.ok([]const u32, try rig.ints(&.{ 1, 2, 3 }));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, got);
    const mutable = try rig.ok([]u32, try rig.ints(&.{ 4, 5 }));
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, mutable);
    const empty = try rig.ok([]const u32, try rig.arr(&.{}));
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "slice: element errors carry the index, nested slices both indices" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const mixed = try rig.arr(&.{ int(1), str("x") });
    try rig.fails([]const u32, mixed, error.TypeMismatch, "[1]: expected integer, found string");
    const negative = try rig.ints(&.{ 1, -1 });
    const negative_message = "[1]: -1 is out of range for u32";
    try rig.fails([]const u32, negative, error.IntegerOutOfRange, negative_message);
    const nested = try rig.arr(&.{ try rig.ints(&.{ 1, 2 }), try rig.ints(&.{ 3, 70000 }) });
    const message = "[1][1]: 70000 is out of range for u16";
    try rig.fails([]const []const u16, nested, error.IntegerOutOfRange, message);
}

test "slice: []const u8 stays a borrowed string and an int array is not one" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const Named = struct { s: []const u8 };
    const text = "hello";
    const got = try rig.ok(Named, try rig.obj(&.{kv("s", str(text))}));
    try testing.expectEqual(@intFromPtr(text.ptr), @intFromPtr(got.s.ptr));
    const as_array = try rig.obj(&.{kv("s", try rig.ints(&.{ 104, 105 }))});
    try rig.fails(Named, as_array, error.TypeMismatch, "s: expected string, found array");
    const bytes_of_ints = try rig.ok([]const []const u8, try rig.arr(&.{ str("a"), str("") }));
    try testing.expectEqualStrings("a", bytes_of_ints[0]);
    try testing.expectEqual(@as(usize, 0), bytes_of_ints[1].len);
}

test "slice: slices of structs, structs of slices and optional slices" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const a = try rig.obj(&.{kv("host", str("a"))});
    const b = try rig.obj(&.{ kv("host", str("b")), kv("port", int(9)) });
    const servers = try rig.arr(&.{ a, b });
    const fleet_in = try rig.obj(&.{ kv("servers", servers), kv("name", str("f")) });
    const fleet = try rig.ok(Fleet, fleet_in);
    try testing.expectEqualStrings("f", fleet.name);
    try testing.expectEqual(@as(usize, 2), fleet.servers.len);
    try testing.expectEqual(@as(u16, 8080), fleet.servers[0].port);
    try testing.expectEqualStrings("b", fleet.servers[1].host);
    try testing.expectEqual(@as(u16, 9), fleet.servers[1].port);

    const Tags = struct { tags: ?[]const u32 = null };
    const absent = try rig.ok(Tags, try rig.obj(&.{}));
    try testing.expect(absent.tags == null);
    const null_tags = try rig.ok(Tags, try rig.obj(&.{kv("tags", .null)}));
    try testing.expect(null_tags.tags == null);
    const given = try rig.ok(Tags, try rig.obj(&.{kv("tags", try rig.ints(&.{ 7, 8 }))}));
    try testing.expectEqualSlices(u32, &.{ 7, 8 }, given.tags.?);
    const root_some = try rig.ok(?[]const u32, try rig.ints(&.{1}));
    try testing.expectEqualSlices(u32, &.{1}, root_some.?);
}

test "slice: slices of optionals and of arrays" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const holes = try rig.ok([]const ?u8, try rig.arr(&.{ .null, int(4) }));
    try testing.expectEqualSlices(?u8, &.{ null, 4 }, holes);
    const pairs_in = try rig.arr(&.{ try rig.ints(&.{ 1, 2 }), try rig.ints(&.{ 3, 4 }) });
    const pairs = try rig.ok([]const [2]u8, pairs_in);
    try testing.expectEqual([2]u8{ 3, 4 }, pairs[1]);
    const Tagged = struct { tags: []const []const u8 = &.{} };
    const tags_in = try rig.obj(&.{kv("tags", try rig.arr(&.{ str("a"), int(1) }))});
    try rig.fails(Tagged, tags_in, error.TypeMismatch, "tags[1]: expected string, found int");
}

test "slice: exactly one allocation holds the whole slice" {
    var input: ValueTree = undefined;
    input.init(testing.allocator);
    defer input.deinit();
    const items = try input.arena.allocator().alloc(Value, 4096);
    for (items, 0..) |*item, index| item.* = .{ .uint = index };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    const got = try parse([]const u32, &tree, .{ .array = items }, &diag);
    try testing.expectEqual(@as(usize, 4096), got.len);
    for (got, 0..) |element, index| try testing.expectEqual(@as(u32, @intCast(index)), element);
    try testing.expectEqual(@as(usize, 1), failing.allocations);
    try expect_untouched(&diag);
}

test "slice: an empty array allocates nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    const got = try parse([]const u32, &tree, .{ .array = &.{} }, &diag);
    try testing.expectEqual(@as(usize, 0), got.len);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try expect_untouched(&diag);
}

test "slice: an allocator that fails is OutOfMemory with the fallback message" {
    const items = [_]Value{ .{ .uint = 1 }, .{ .uint = 2 }, .{ .uint = 3 } };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    const result = parse([]const u32, &tree, .{ .array = &items }, &diag);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expectEqualStrings("parse of []const u32 failed: OutOfMemory", diag.message());
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
}

test "slice: OutOfMemory inside a struct names the field and leaks nothing" {
    const Listed = struct { list: []const u32 };
    const items = [_]Value{ .{ .uint = 1 }, .{ .uint = 2 } };
    var entries: [1]Map.Entry = undefined;
    var map = Map.init(&entries);
    try map.put("list", .{ .array = &items });
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    try testing.expectError(error.OutOfMemory, parse(Listed, &tree, .{ .map = map }, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "list: "));
    try testing.expect(std.mem.endsWith(u8, diag.message(), "failed: OutOfMemory"));
    try testing.expectEqual(position_none, diag.line);
}

test "slice: a failure after a successful slice leaks nothing" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const Two = struct { first: []const u32, second: []const u32 };
    const input = try rig.obj(&.{
        kv("first", try rig.ints(&.{ 1, 2, 3 })),
        kv("second", try rig.arr(&.{ int(1), .null })),
    });
    try rig.fails(Two, input, error.TypeMismatch, "second[1]: expected integer, found null");
}

fn node_chain(rig: *Rig, nodes: u32, innermost_array: bool) !Value {
    std.debug.assert(nodes > 0);
    const innermost = if (innermost_array) kv("children", try rig.arr(&.{})) else null;
    var current = if (innermost) |pair| try rig.obj(&.{pair}) else try rig.obj(&.{});
    var level: u32 = 1;
    while (level < nodes) : (level += 1) {
        current = try rig.obj(&.{kv("children", try rig.arr(&.{current}))});
    }
    return current;
}

fn count_nodes(node: Node) u32 {
    var total: u32 = 1;
    for (node.children) |child| total += count_nodes(child);
    return total;
}

test "depth: a recursive type through slices parses by the data's shape" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const leaf = try rig.obj(&.{});
    const mid = try rig.obj(&.{kv("children", try rig.arr(&.{ leaf, leaf }))});
    const root = try rig.obj(&.{kv("children", try rig.arr(&.{ mid, leaf }))});
    const got = try rig.ok(Node, root);
    try testing.expectEqual(@as(usize, 2), got.children.len);
    try testing.expectEqual(@as(usize, 2), got.children[0].children.len);
    try testing.expectEqual(@as(usize, 0), got.children[1].children.len);
    try testing.expectEqual(@as(u32, 5), count_nodes(got));
}

test "depth: 128 nested containers are accepted" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const short = try rig.ok(Node, try node_chain(&rig, 64, false)); // 127 containers
    try testing.expectEqual(@as(u32, 64), count_nodes(short));
    const exact = try rig.ok(Node, try node_chain(&rig, 64, true)); // 128 containers
    try testing.expectEqual(@as(u32, 64), count_nodes(exact));
}

test "depth: the 129th nested container is TooDeep and writes the diagnostics once" {
    const reason = ": exceeds nesting depth limit 128";
    inline for (.{ .{ 65, false }, .{ 65, true }, .{ 100, false } }) |shape| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        const deep = try node_chain(&rig, shape[0], shape[1]);
        try testing.expectError(error.TooDeep, parse(Node, &rig.tree, deep, &rig.diag));
        const message = rig.diag.message();
        try testing.expect(std.mem.endsWith(u8, message, reason));
        try testing.expect(std.mem.startsWith(u8, message, core.diagnostics.truncation_marker));
        try testing.expectEqual(position_none, rig.diag.line);
        try testing.expectEqual(position_none, rig.diag.col);
    }
}

test "depth: parse_value under a caller's context enters a container only below depth 128" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    const point = try rig.obj(&.{ kv("x", int(1)), kv("y", int(2)) });
    context.depth = nesting_max - 1;
    const got = try parse_value(Point, &context, point);
    try testing.expectEqual(Point{ .x = 1, .y = 2 }, got);
    try expect_untouched(&rig.diag);
    try testing.expect(!context.diag_written);
    try testing.expectEqual(nesting_max - 1, context.depth);

    context.depth = nesting_max;
    const reason = "exceeds nesting depth limit 128";
    try testing.expectError(error.TooDeep, parse_value(Point, &context, point));
    try testing.expectEqualStrings(reason, rig.diag.message());
    try testing.expect(context.diag_written);
    context.diag_written = false;
    rig.diag = sentinel();
    try testing.expectError(error.TooDeep, parse_value([2]u8, &context, try rig.ints(&.{ 1, 2 })));
    try testing.expectEqualStrings(reason, rig.diag.message());
    context.diag_written = false;
    rig.diag = sentinel();
    const empty = try rig.arr(&.{});
    try testing.expectError(error.TooDeep, parse_value([]const u32, &context, empty));
    context.diag_written = false;
    rig.diag = sentinel();
    try testing.expectError(error.TooDeep, parse_value(Empty, &context, try rig.obj(&.{})));
    try testing.expectEqualStrings(reason, rig.diag.message());
}

test "depth: a struct entered at depth 127 cannot enter a child container" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    context.depth = nesting_max - 1;
    const server = try rig.obj(&.{kv("host", str("a"))});
    const wrapper = try rig.obj(&.{kv("server", server)});
    try testing.expectError(error.TooDeep, parse_value(Wrapper, &context, wrapper));
    try testing.expectEqualStrings("server: exceeds nesting depth limit 128", rig.diag.message());
    try testing.expect(context.diag_written);
    try testing.expectEqual(@as(u32, 0), context.path.count);
    try testing.expectEqual(nesting_max - 1, context.depth);
}

test "context: after a struct parse fails the path and the depth are what they were" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    const bad = try rig.obj(&.{kv("host", int(5))});
    const input = try rig.obj(&.{ kv("name", str("n")), kv("servers", try rig.arr(&.{bad})) });
    try testing.expectError(error.TypeMismatch, parse_value(Fleet, &context, input));
    const message = "servers[0].host: expected string, found int";
    try testing.expectEqualStrings(message, rig.diag.message());
    try testing.expect(context.diag_written);
    try testing.expectEqual(@as(u32, 0), context.path.count);
    try testing.expectEqual(@as(u32, 0), context.depth);
}

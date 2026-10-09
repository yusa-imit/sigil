//! Tests for `json/dom.zig` (plan 004 item 4): numbers, strings, structure, duplicate keys,
//! every declared error, no leak, an allocation-failure sweep, and a seeded model.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("dom.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Value = core.Value;
const Map = core.Map;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;

const options_reject: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .reject };
const options_last: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .last };

const sentinel_line: u32 = 777;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Parses `input` into `tree`; asserts success left `diag` untouched.
fn parse_ok(tree: *ValueTree, input: []const u8, options: dom.ParseOptions) !Value {
    var diag = fresh_diag();
    const value = try dom.parse(tree, input, options, &diag);
    try expectEqual(sentinel_line, diag.line);
    return value;
}

/// Parses `input` and expects `err` with the diagnostic at `line:col`.
fn expect_fail(
    input: []const u8,
    options: dom.ParseOptions,
    err: dom.ParseValueError,
    line: u32,
    col: u32,
) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    try std.testing.expectError(err, dom.parse(&tree, input, options, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(diag.message().len > 0);
    try expect(tree.root == .null);
}

test "dom: scalar roots" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expect((try parse_ok(&tree, "null", options_reject)) == .null);
    try expect((try parse_ok(&tree, " true\n", options_reject)).bool);
    try expect(!(try parse_ok(&tree, "false", options_reject)).bool);
    try expectEqualStrings("hi", (try parse_ok(&tree, "\"hi\"", options_reject)).string);
    try expectEqualStrings("", (try parse_ok(&tree, "\"\"", options_reject)).string);
    try expectEqual(@as(i64, 42), (try parse_ok(&tree, "42", options_reject)).int);
}

test "dom: integers keep i64 and u64 distinct at the boundaries" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const text = "[18446744073709551615,-9223372036854775808,9223372036854775807," ++
        "9223372036854775808,-0,0]";
    const items = (try parse_ok(&tree, text, options_reject)).array;
    try expectEqual(@as(usize, 6), items.len);
    try expectEqual(std.math.maxInt(u64), items[0].uint);
    try expectEqual(std.math.minInt(i64), items[1].int);
    try expectEqual(std.math.maxInt(i64), items[2].int);
    try expectEqual(@as(u64, 1) << 63, items[3].uint);
    try expectEqual(@as(i64, 0), items[4].int);
    try expectEqual(@as(i64, 0), items[5].int);
}

test "dom: floats keep their sign bit and underflow to zero" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const items = (try parse_ok(&tree, "[-0.0,1e-400,5e-324,1E2,2.5]", options_reject)).array;
    try expect(std.math.signbit(items[0].float));
    try expectEqual(@as(f64, 0.0), items[0].float);
    try expect(!std.math.signbit(items[1].float));
    try expectEqual(@as(f64, 0.0), items[1].float);
    try expectEqual(std.math.floatTrueMin(f64), items[2].float);
    try expectEqual(@as(f64, 100.0), items[3].float);
    try expectEqual(@as(f64, 2.5), items[4].float);
}

test "dom: number range errors are typed and positioned" {
    try expect_fail("[1, 18446744073709551616]", options_reject, error.IntegerAboveMax, 1, 5);
    try expect_fail("[-9223372036854775809]", options_reject, error.IntegerBelowMin, 1, 2);
    try expect_fail("{\"a\":1e400}", options_reject, error.FloatOutOfRange, 1, 6);
    try expect_fail("-1e400", options_reject, error.FloatOutOfRange, 1, 1);
}

test "dom: strings and keys are decoded copies, not borrowed from the input" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var input_buffer = "{\"k\\u00e9\":\"a\\n\\u00e9\\ud83d\\ude00\\\\\"}".*;
    const value = try parse_ok(&tree, &input_buffer, options_reject);
    @memset(&input_buffer, 'X');

    try expectEqual(@as(u32, 1), value.map.count);
    const entry = value.map.items()[0];
    try expectEqualStrings("k\u{e9}", entry.key);
    try expectEqualStrings("a\n\u{e9}\u{1F600}\\", entry.value.string);
}

test "dom: NUL escapes decode to a NUL byte" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const value = try parse_ok(&tree, "\"a\\u0000b\"", options_reject);
    try expectEqualStrings("a\x00b", value.string);
}

test "dom: a nested document has the exact shape" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const text =
        \\ {"a":[1,-2,18446744073709551615,2.5,"x\ty"],"b":{},"c":[],"d":null,
        \\  "e":true,"f":{"g":[[]]}}
    ;
    const value = try parse_ok(&tree, text, options_reject);

    var none: [0]Map.Entry = .{};
    const a_items = [_]Value{
        .{ .int = 1 },
        .{ .int = -2 },
        .{ .uint = std.math.maxInt(u64) },
        .{ .float = 2.5 },
        .{ .string = "x\ty" },
    };
    const g_items = [_]Value{.{ .array = &.{} }};
    var g_entries = [_]Map.Entry{.{ .key = "g", .value = .{ .array = &g_items } }};
    var entries = [_]Map.Entry{
        .{ .key = "a", .value = .{ .array = &a_items } },
        .{ .key = "b", .value = .{ .map = .{ .entries = &none, .count = 0 } } },
        .{ .key = "c", .value = .{ .array = &.{} } },
        .{ .key = "d", .value = .null },
        .{ .key = "e", .value = .{ .bool = true } },
        .{ .key = "f", .value = .{ .map = .{ .entries = &g_entries, .count = 1 } } },
    };
    const expected: Value = .{ .map = .{ .entries = &entries, .count = entries.len } };
    try expect(try core.value.eql(expected, value));
    value.map.check_invariants();
}

test "dom: empty containers have zero length" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const array = try parse_ok(&tree, " [ ] ", options_reject);
    try expectEqual(@as(usize, 0), array.array.len);
    const map = try parse_ok(&tree, "{ }", options_reject);
    try expectEqual(@as(u32, 0), map.map.count);
}

test "dom: reject refuses a repeated key at the second key" {
    try expect_fail("{\"a\":1,\"b\":2,\"a\":3}", options_reject, error.DuplicateKey, 1, 14);
    try expect_fail("{\n  \"x\": 1,\n  \"x\": 2\n}", options_reject, error.DuplicateKey, 3, 3);
    try expect_fail("[{\"k\":1},{\"k\":1,\"k\":2}]", options_reject, error.DuplicateKey, 1, 17);
}

test "dom: reject compares decoded keys" {
    try expect_fail("{\"a\":1,\"\\u0061\":2}", options_reject, error.DuplicateKey, 1, 8);
}

test "dom: a duplicate key is reported before a bad number that follows it" {
    try expect_fail("{\"a\":1,\"a\":1e400}", options_reject, error.DuplicateKey, 1, 8);
}

test "dom: last keeps the first position and the last value" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const value = try parse_ok(&tree, "{\"a\":1,\"b\":2,\"a\":3}", options_last);
    try expectEqual(@as(u32, 2), value.map.count);
    try expect(value.map.entries.len > value.map.count);
    try expectEqualStrings("a", value.map.items()[0].key);
    try expectEqual(@as(i64, 3), value.map.items()[0].value.int);
    try expectEqualStrings("b", value.map.items()[1].key);
    try expectEqual(@as(i64, 2), value.map.items()[1].value.int);
    value.map.check_invariants();

    const escaped = try parse_ok(&tree, "{\"a\":1,\"\\u0061\":2}", options_last);
    try expectEqual(@as(u32, 1), escaped.map.count);
    try expectEqual(@as(i64, 2), escaped.map.items()[0].value.int);
}

test "dom: the same key in different objects is not a duplicate" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const text = "{\"a\":{\"a\":1},\"b\":{\"a\":2},\"c\":[{\"a\":3},{\"a\":4}]}";
    const value = try parse_ok(&tree, text, options_reject);
    try expectEqual(@as(u32, 3), value.map.count);
    try expectEqual(@as(i64, 2), value.map.get("b").?.map.get("a").?.int);
    try expectEqual(@as(i64, 4), value.map.get("c").?.array[1].map.get("a").?.int);
}

test "dom: scan errors surface with their position and leave no root" {
    try expect_fail("", options_reject, error.UnexpectedEnd, 1, 1);
    try expect_fail("{\"a\":[", options_reject, error.UnexpectedEnd, 1, 7);
    try expect_fail("[1,]", options_reject, error.UnexpectedToken, 1, 4);
    try expect_fail("[1] x", options_reject, error.TrailingData, 1, 5);
    try expect_fail("[01]", options_reject, error.InvalidNumber, 1, 2);
    try expect_fail("[\"\\x\"]", options_reject, error.InvalidEscape, 1, 3);
    try expect_fail("[\"\\ud800\"]", options_reject, error.LoneSurrogate, 1, 3);
    try expect_fail("[\"a\tb\"]", options_reject, error.ControlCharacter, 1, 4);
    try expect_fail("[\"\xff\"]", options_reject, error.InvalidUtf8, 1, 3);
}

test "dom: nesting passes at depth_max and fails one deeper" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const open = "[" ** 129;
    const close = "]" ** 129;
    const at_limit = open[0..128] ++ close[0..128];
    const value = try parse_ok(&tree, at_limit, options_reject);
    try expectEqual(@as(usize, 1), value.array.len);

    try expect_fail(open ++ close, options_reject, error.TooDeep, 1, 129);
    try expect_fail("[[[]]]", .{ .depth_max = 2, .duplicate_key = .reject }, error.TooDeep, 1, 3);
    const shallow = try parse_ok(&tree, "[[]]", .{ .depth_max = 2, .duplicate_key = .reject });
    try expectEqual(@as(usize, 1), shallow.array.len);
}

test "dom: input past maxInt(u32) is InputTooLarge before any byte is read" {
    // A slice header with a length past maxInt(u32); the bytes are never read.
    const len = @as(usize, std.math.maxInt(u32)) + 1;
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(4096))[0..len];
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    try std.testing.expectError(
        error.InputTooLarge,
        dom.parse(&tree, huge, options_reject, &diag),
    );
    try expect(diag.line != sentinel_line);
    try expect(diag.message().len > 0);
}

test "dom: one tree holds several documents and its root stays untouched" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try parse_ok(&tree, "{\"layer\":\"base\"}", options_reject);
    const second = try parse_ok(&tree, "{\"layer\":\"local\"}", options_reject);
    try expectEqualStrings("base", first.map.get("layer").?.string);
    try expectEqualStrings("local", second.map.get("layer").?.string);
    try expect(tree.root == .null);
}

fn parse_for_oom(gpa: std.mem.Allocator, input: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = fresh_diag();
    const value = try dom.parse(&tree, input, options_last, &diag);
    try expect(value != .null);
}

test "dom: every allocation failure is OutOfMemory and leaks nothing" {
    const text =
        \\{"a":[1,"x\ty",{"b":[true,null]}],"c":{"d":"e\u00e9"},"a":"again","f":[]}
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_for_oom, .{text});
}

test "dom: OutOfMemory writes the diagnostic once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();

    var diag = fresh_diag();
    try std.testing.expectError(
        error.OutOfMemory,
        dom.parse(&tree, "[1]", options_reject, &diag),
    );
    try expect(diag.line != sentinel_line);
    try expect(diag.message().len > 0);
}

// ---- Seeded model: a trivial reference writer feeds the parser. ----

const model_depth_max: u32 = 4;
const model_seeds: u32 = 400;
const model_strings = [_][]const u8{
    "",
    "a",
    "quote\"inside",
    "back\\slash",
    "line\nbreak",
    "tab\t",
    "\x01\x1f",
    "nul\x00byte",
    "caf\u{e9}",
    "\u{1F600}",
    "\u{7f}",
    "solidus/",
};
const model_keys = [_][]const u8{ "k0", "k1", "", "k\"3", "k\u{e9}", "k5", "k6", "k7" };

/// Builds a random `Value` at most `model_depth_max` deep. The bound is a literal depth counter,
/// the same bounded-recursion trade-off the reflect round-trip test makes.
fn generate(rng: std.Random, arena: std.mem.Allocator, depth: u32) !Value {
    const containers_allowed = depth < model_depth_max;
    const kinds: u32 = if (containers_allowed) 9 else 7;
    switch (rng.uintLessThan(u32, kinds)) {
        0 => return .null,
        1 => return .{ .bool = rng.boolean() },
        2 => return .{ .int = rng.int(i64) },
        3 => return .{ .uint = @as(u64, std.math.maxInt(i64)) + 1 + rng.int(u32) },
        4 => return .{ .string = model_strings[rng.uintLessThan(usize, model_strings.len)] },
        5 => return .{ .int = rng.intRangeAtMost(i64, -3, 3) },
        6 => return .{ .string = model_strings[0] },
        7 => {
            const items = try arena.alloc(Value, rng.uintLessThan(usize, 5));
            for (items) |*item| item.* = try generate(rng, arena, depth + 1);
            return .{ .array = items };
        },
        else => {
            const entries = try arena.alloc(Map.Entry, rng.uintLessThan(usize, 5));
            for (entries, 0..) |*entry, index| {
                const value = try generate(rng, arena, depth + 1);
                entry.* = .{ .key = model_keys[index], .value = value };
            }
            return .{ .map = .{ .entries = entries, .count = @intCast(entries.len) } };
        },
    }
}

fn write_string(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0...0x1f => try w.print("\\u{x:0>4}", .{byte}),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

/// The reference serializer: separate code from the parser under test.
fn write_value(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |flag| try w.writeAll(if (flag) "true" else "false"),
        .int => |number| try w.print("{d}", .{number}),
        .uint => |number| try w.print("{d}", .{number}),
        .string => |text| try write_string(w, text),
        .array => |items| {
            try w.writeAll("[ ");
            for (items, 0..) |item, index| {
                if (index > 0) try w.writeAll(" , ");
                try write_value(w, item);
            }
            try w.writeAll(" ]");
        },
        .map => |map| {
            try w.writeAll("{\n");
            for (map.items(), 0..) |entry, index| {
                if (index > 0) try w.writeAll(",\n");
                try write_string(w, entry.key);
                try w.writeAll(" :");
                try write_value(w, entry.value);
            }
            try w.writeAll("}");
        },
        .float, .bytes, .timestamp => unreachable, // proof: `generate` never makes these.
    }
}

test "dom: seeded model, reference writer output parses back to the same Value" {
    for (0..model_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var model_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer model_arena.deinit();
        const expected = try generate(prng.random(), model_arena.allocator(), 0);

        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write_value(&out.writer, expected);

        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();
        var diag = fresh_diag();
        const parsed = dom.parse(&tree, out.written(), options_reject, &diag) catch |err| {
            std.log.err("seed {d}: {s} on {s}", .{ seed, @errorName(err), out.written() });
            return err;
        };
        if (!try core.value.eql(expected, parsed)) {
            std.log.err("seed {d}: mismatch on {s}", .{ seed, out.written() });
            return error.TestUnexpectedResult;
        }
    }
}

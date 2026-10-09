//! Tests for `json/writer.zig` (plan 004 item 5): golden output per layout, floats, key sorting,
//! every refused kind with its key path, every declared error, a full-writer sweep, and a seeded
//! model checked against `std.json.validate` and against `dom.parse`.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("dom.zig");
const writer = @import("writer.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Value = core.Value;
const Map = core.Map;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const StringifyOptions = writer.StringifyOptions;

const minified: StringifyOptions = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = 128,
};
const sentinel_line: u32 = 777;

fn pretty(indent_spaces: u8) StringifyOptions {
    return .{
        .layout = .{ .pretty = .{ .indent_spaces = indent_spaces } },
        .sort_keys = false,
        .escape = .minimal,
        .depth_max = 128,
    };
}

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Writes `value` into an allocating writer; asserts success left `diag` untouched.
fn write_ok(aw: *std.Io.Writer.Allocating, value: Value, options: StringifyOptions) !void {
    var diag = fresh_diag();
    try writer.write(&aw.writer, value, options, &diag);
    try expectEqual(sentinel_line, diag.line);
}

fn expect_output(value: Value, options: StringifyOptions, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try write_ok(&aw, value, options);
    try expectEqualStrings(expected, aw.written());
}

/// Expects `err` and a diagnostic message equal to `message`, at `position_none`.
fn expect_fail(
    value: Value,
    options: StringifyOptions,
    err: writer.WriteValueError,
    message: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try std.testing.expectError(err, writer.write(&aw.writer, value, options, &diag));
    try expectEqualStrings(message, diag.message());
    try expectEqual(core.diagnostics.position_none, diag.line);
}

/// A map over `entries` filled with `keys`/`values`, in order.
fn map_of(entries: []Map.Entry, keys: []const []const u8, values: []const Value) !Value {
    std.debug.assert(keys.len == values.len);
    var map = Map.init(entries);
    for (keys, values) |key, value| try map.put(key, value);
    map.check_invariants();
    return .{ .map = map };
}

test "writer: scalars" {
    try expect_output(.null, minified, "null");
    try expect_output(.{ .bool = true }, minified, "true");
    try expect_output(.{ .bool = false }, minified, "false");
    try expect_output(.{ .int = 0 }, minified, "0");
    try expect_output(.{ .int = std.math.minInt(i64) }, minified, "-9223372036854775808");
    try expect_output(.{ .uint = std.math.maxInt(u64) }, minified, "18446744073709551615");
    try expect_output(.{ .string = "" }, minified, "\"\"");
    const text = "a\"b\\c\n\x01\x7f";
    try expect_output(.{ .string = text }, minified, "\"a\\\"b\\\\c\\n\\u0001\\u007f\"");
}

test "writer: escape policy reaches strings and keys" {
    var entries: [1]Map.Entry = undefined;
    const value = try map_of(&entries, &.{"k\xC3\xA9"}, &.{.{ .string = "\xF0\x9F\x98\x80" }});
    try expect_output(value, minified, "{\"k\xC3\xA9\":\"\xF0\x9F\x98\x80\"}");
    var ascii = minified;
    ascii.escape = .ascii_only;
    try expect_output(value, ascii, "{\"k\\u00e9\":\"\\ud83d\\ude00\"}");
}

test "writer: floats always re-parse as floats" {
    const cases = [_]struct { value: f64, text: []const u8 }{
        .{ .value = 0.1, .text = "0.1" },
        .{ .value = 1.0, .text = "1.0" },
        .{ .value = -0.0, .text = "-0.0" },
        .{ .value = 0.0, .text = "0.0" },
        .{ .value = 5e-324, .text = "5e-324" },
        .{ .value = 1e300, .text = "1e300" },
        .{ .value = 1.5e300, .text = "1.5e300" },
        .{ .value = 1e21, .text = "1e21" },
        .{ .value = 1e20, .text = "100000000000000000000.0" },
        .{ .value = 1e-6, .text = "0.000001" },
        .{ .value = 1e-7, .text = "1e-7" },
        .{ .value = 123456789.125, .text = "123456789.125" },
        .{ .value = -2.5, .text = "-2.5" },
        .{ .value = std.math.floatMax(f64), .text = "1.7976931348623157e308" },
    };
    for (cases) |case| {
        try expect_output(.{ .float = case.value }, minified, case.text);

        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();
        var diag = fresh_diag();
        const parse_options: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .reject };
        const parsed = try dom.parse(&tree, case.text, parse_options, &diag);
        try expect(parsed == .float);
        try expectEqual(@as(u64, @bitCast(case.value)), @as(u64, @bitCast(parsed.float)));
    }
}

test "writer: minified containers carry no whitespace" {
    var inner_entries: [1]Map.Entry = undefined;
    const inner = try map_of(&inner_entries, &.{"b"}, &.{.null});
    const items = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, inner };
    var entries: [2]Map.Entry = undefined;
    const values = [_]Value{ .{ .array = &items }, .{ .string = "x" } };
    const value = try map_of(&entries, &.{ "a", "c" }, &values);
    try expect_output(value, minified, "{\"a\":[1,2,{\"b\":null}],\"c\":\"x\"}");
    try expect_output(.{ .array = &.{} }, minified, "[]");
    try expect_output(.{ .map = Map.init(&.{}) }, minified, "{}");
}

test "writer: pretty indents per level and keeps empty containers inline" {
    const empty_items = [_]Value{};
    var empty_entries: [0]Map.Entry = .{};
    const empty_map: Value = .{ .map = Map.init(&empty_entries) };
    const items = [_]Value{ .{ .int = 1 }, .{ .array = &empty_items }, empty_map };
    var entries: [2]Map.Entry = undefined;
    const values = [_]Value{ .{ .array = &items }, .{ .bool = true } };
    const value = try map_of(&entries, &.{ "a", "b" }, &values);
    const expected2 = "{\n  \"a\": [\n    1,\n    [],\n    {}\n  ],\n  \"b\": true\n}";
    try expect_output(value, pretty(2), expected2);
    const expected4 =
        "{\n    \"a\": [\n        1,\n        [],\n        {}\n    ],\n    \"b\": true\n}";
    try expect_output(value, pretty(4), expected4);
    try expect_output(.{ .array = &.{} }, pretty(2), "[]");
    try expect_output(.{ .int = 3 }, pretty(8), "3");
}

test "writer: sort_keys orders by key bytes at every level and ignores insertion order" {
    var inner_entries: [2]Map.Entry = undefined;
    const inner = try map_of(&inner_entries, &.{ "z", "y" }, &.{ .null, .null });
    var entries: [5]Map.Entry = undefined;
    const keys = [_][]const u8{ "b", "a", "ab", "B", "c" };
    const values = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 }, inner };
    const value = try map_of(&entries, &keys, &values);

    const original = "{\"b\":1,\"a\":2,\"ab\":3,\"B\":4,\"c\":{\"z\":null,\"y\":null}}";
    try expect_output(value, minified, original);
    var sorted = minified;
    sorted.sort_keys = true;
    const ordered = "{\"B\":4,\"a\":2,\"ab\":3,\"b\":1,\"c\":{\"y\":null,\"z\":null}}";
    try expect_output(value, sorted, ordered);
}

test "writer: sort_keys on a map whose live count is below its capacity" {
    var entries: [4]Map.Entry = undefined;
    const value = try map_of(&entries, &.{ "y", "x" }, &.{ .{ .int = 1 }, .{ .int = 2 } });
    var sorted = minified;
    sorted.sort_keys = true;
    try expect_output(value, sorted, "{\"x\":2,\"y\":1}");
}

test "writer: bytes, timestamp, NaN and infinities are refused with their key path" {
    const stamp: core.Timestamp = .{ .seconds = 0, .nanoseconds = 0, .offset_minutes = null };
    const unrepresentable = error.Unrepresentable;
    const bytes_text = "bytes cannot be written as JSON";
    try expect_fail(.{ .bytes = "ab" }, minified, unrepresentable, bytes_text);
    const stamp_text = "timestamp cannot be written as JSON";
    try expect_fail(.{ .timestamp = stamp }, minified, unrepresentable, stamp_text);
    const nan = std.math.nan(f64);
    try expect_fail(.{ .float = nan }, minified, unrepresentable, "NaN cannot be written as JSON");
    const inf = std.math.inf(f64);
    const inf_text = "infinity cannot be written as JSON";
    try expect_fail(.{ .float = inf }, minified, unrepresentable, inf_text);
    try expect_fail(.{ .float = -inf }, minified, unrepresentable, inf_text);

    var deep_entries: [1]Map.Entry = undefined;
    const deep = try map_of(&deep_entries, &.{"b c"}, &.{.{ .bytes = "" }});
    const items = [_]Value{ .null, deep };
    var entries: [1]Map.Entry = undefined;
    const value = try map_of(&entries, &.{"a"}, &.{.{ .array = &items }});
    const message = "a[1][\"b c\"]: bytes cannot be written as JSON";
    try expect_fail(value, minified, unrepresentable, message);
    try expect_fail(value, pretty(2), unrepresentable, message);
}

test "writer: a refused value stops the output at that point" {
    const items = [_]Value{ .{ .int = 1 }, .{ .bytes = "" }, .{ .int = 3 } };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = writer.write(&aw.writer, .{ .array = &items }, minified, &diag);
    try std.testing.expectError(error.Unrepresentable, result);
    try expectEqualStrings("[1,", aw.written());
    try expectEqualStrings("[1]: bytes cannot be written as JSON", diag.message());
}

/// `depth` nested single-element arrays around `null`, built from `arena`.
fn nested_arrays(arena: std.mem.Allocator, depth: u32) !Value {
    var value: Value = .null;
    for (0..depth) |_| {
        const slot = try arena.alloc(Value, 1);
        slot[0] = value;
        value = .{ .array = slot };
    }
    return value;
}

test "writer: depth_max is exact and the 129th container is TooDeep" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write_ok(&aw, try nested_arrays(arena, 128), minified);
    try expectEqual(@as(usize, 128 * 2 + 4), aw.written().len);

    const message = "[0][0]: exceeds the depth limit";
    var shallow = minified;
    shallow.depth_max = 2;
    try expect_fail(try nested_arrays(arena, 3), shallow, error.TooDeep, message);
    try write_ok(&aw, try nested_arrays(arena, 2), shallow);
    shallow.depth_max = 1;
    try write_ok(&aw, .{ .array = &.{} }, shallow);
    const too_deep = try nested_arrays(arena, 2);
    try expect_fail(too_deep, shallow, error.TooDeep, "[0]: exceeds the depth limit");
}

test "writer: invalid UTF-8 and oversized text are typed errors with a path" {
    var entries: [1]Map.Entry = undefined;
    const bad_value = try map_of(&entries, &.{"k"}, &.{.{ .string = "\xFF" }});
    try expect_fail(bad_value, minified, error.InvalidUtf8, "k: string is not valid UTF-8");
    const bad_key = try map_of(&entries, &.{"k\xC3"}, &.{.null});
    const key_message = "[\"k\xC3\"]: string is not valid UTF-8";
    try expect_fail(bad_key, minified, error.InvalidUtf8, key_message);

    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    const backing: [1]u8 = .{'a'};
    const length_max: usize = std.math.maxInt(u32);
    const oversized = @as([*]const u8, &backing)[0 .. length_max + 1];
    try expect_fail(.{ .string = oversized }, minified, error.InputTooLarge, "string is too large");
}

test "writer: a full fixed writer fails at every capacity below the output length" {
    const items = [_]Value{ .{ .int = 12 }, .{ .string = "ab" }, .null };
    var entries: [1]Map.Entry = undefined;
    const value = try map_of(&entries, &.{"key"}, &.{.{ .array = &items }});

    for ([_]StringifyOptions{ minified, pretty(2) }) |options| {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try write_ok(&aw, value, options);
        const output_len = aw.written().len;

        var buffer: [128]u8 = undefined;
        for (0..output_len + 1) |capacity| {
            var fixed: std.Io.Writer = .fixed(buffer[0..capacity]);
            var diag = fresh_diag();
            const result = writer.write(&fixed, value, options, &diag);
            if (capacity < output_len) {
                try std.testing.expectError(error.WriteFailed, result);
                try expect(std.mem.endsWith(u8, diag.message(), "output writer failed"));
            } else {
                try result;
                try expectEqualStrings(aw.written(), fixed.buffered());
            }
        }
    }
}

test "writer: pretty and sort_keys together into a fixed buffer" {
    var buffer: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    var entries: [2]Map.Entry = undefined;
    const value = try map_of(&entries, &.{ "k", "j" }, &.{ .{ .float = 0.25 }, .null });
    var options = pretty(2);
    options.sort_keys = true;
    var diag = fresh_diag();
    try writer.write(&fixed, value, options, &diag);
    try expectEqualStrings("{\n  \"j\": null,\n  \"k\": 0.25\n}", fixed.buffered());
}

/// A random Value the writer accepts: finite floats, UTF-8 strings, unique keys, `.uint` only
/// above `maxInt(i64)` (the canonical form). Built in `arena`.
const uint_min: u64 = std.math.maxInt(i64) + 1;

fn random_value(arena: std.mem.Allocator, random: std.Random, depth: u32) !Value {
    const container_kinds: u8 = if (depth < 6) 2 else 0;
    switch (random.uintLessThan(u8, 6 + container_kinds)) {
        0 => return .null,
        1 => return .{ .bool = random.boolean() },
        2 => return .{ .int = random.int(i64) },
        3 => return .{ .uint = random.intRangeAtMost(u64, uint_min, std.math.maxInt(u64)) },
        4 => return .{ .float = random_float(random) },
        5 => return .{ .string = try random_text(arena, random) },
        6 => {
            const items = try arena.alloc(Value, random.uintLessThan(usize, 4));
            for (items) |*item| item.* = try random_value(arena, random, depth + 1);
            return .{ .array = items };
        },
        else => {
            const entries = try arena.alloc(Map.Entry, random.uintLessThan(usize, 5));
            var map = Map.init(entries);
            for (0..entries.len) |index| {
                const prefix = try random_text(arena, random);
                const key = try std.fmt.allocPrint(arena, "{s}{d}", .{ prefix, index });
                try map.put(key, try random_value(arena, random, depth + 1));
            }
            map.check_invariants();
            return .{ .map = map };
        },
    }
}

fn random_float(random: std.Random) f64 {
    // A random bit pattern is non-finite one time in 2048, so 64 tries cannot all miss in practice.
    for (0..64) |_| {
        const candidate: f64 = @bitCast(random.int(u64));
        if (std.math.isFinite(candidate)) return candidate;
    }
    return 0.5;
}

fn random_text(arena: std.mem.Allocator, random: std.Random) ![]const u8 {
    const pieces = [_][]const u8{
        "a",    "Z",    " ",        "\"",           "\\",               "\n",
        "\x01", "\x7f", "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80",
    };
    var text: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(usize, 6)) |_| {
        try text.appendSlice(arena, pieces[random.uintLessThan(usize, pieces.len)]);
    }
    return text.items;
}

/// `pretty_text` with every whitespace byte outside a string removed.
fn strip_layout(arena: std.mem.Allocator, pretty_text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    var escaped = false;
    for (pretty_text) |byte| {
        if (in_string) {
            if (byte == '"' and !escaped) in_string = false;
            escaped = byte == '\\' and !escaped;
            try out.append(arena, byte);
        } else if (byte == '"') {
            in_string = true;
            try out.append(arena, byte);
        } else if (byte != ' ' and byte != '\n') {
            try out.append(arena, byte);
        }
    }
    return out.items;
}

test "writer: seeded model, layouts agree and std.json accepts every output" {
    for (0..300) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const value = try random_value(arena, prng.random(), 0);
        errdefer std.log.err("writer model failed, seed {d}", .{seed});

        var min_aw: std.Io.Writer.Allocating = .init(arena);
        try write_ok(&min_aw, value, minified);
        var pretty_aw: std.Io.Writer.Allocating = .init(arena);
        try write_ok(&pretty_aw, value, pretty(@intCast(1 + seed % 8)));
        try expectEqualStrings(min_aw.written(), try strip_layout(arena, pretty_aw.written()));
        try expect(try std.json.validate(arena, min_aw.written()));
        try expect(try std.json.validate(arena, pretty_aw.written()));

        var sorted = minified;
        sorted.sort_keys = true;
        var sorted_aw: std.Io.Writer.Allocating = .init(arena);
        try write_ok(&sorted_aw, value, sorted);
        try expectEqual(min_aw.written().len, sorted_aw.written().len);
        try expect(try std.json.validate(arena, sorted_aw.written()));
    }
}

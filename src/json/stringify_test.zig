//! Tests for `json.stringify(T, tree, w, value, options, diag)` (plan 004 item 8, ADR 0003
//! sections 3, 7 and 8): a Zig value to JSON text through `reflect.stringify` and the writer.
//! Golden text per layout is written by hand from the contract (struct fields in declaration
//! order under their wire names, `"key": value` when pretty, empty containers inline), never
//! taken from the implementation's output. Every `StringifyError` variant is provoked, `diag` is
//! written exactly once on error (its message is the first writer's, never a fallback) at
//! `position_none` with `"{path}: {reason}"`, and success never touches it. Round trips go
//! through `json.parse`; a seeded model compares `stringify(Value)` with `write_value`.

const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json.zig");
const writer_test = @import("writer_test.zig");
const testing = std.testing;

const Value = core.Value;
const Map = core.Map;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Options = json.StringifyOptions;
const position_none = core.diagnostics.position_none;
const sentinel_line: u32 = 777;

const minified: Options = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = 128,
};

fn pretty(indent_spaces: u8) Options {
    return .{
        .layout = .{ .pretty = .{ .indent_spaces = indent_spaces } },
        .sort_keys = false,
        .escape = .minimal,
        .depth_max = 128,
    };
}

fn sorted(options: Options) Options {
    var copy = options;
    copy.sort_keys = true;
    return copy;
}

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

fn expect_untouched(diag: *const Diagnostics) !void {
    try testing.expectEqual(sentinel_line, diag.line);
    try testing.expectEqual(@as(u32, 5), diag.col);
    try testing.expectEqualStrings("untouched", diag.message());
}

/// Stringifies `value` and expects exactly `expected`, with `diag` untouched.
fn expect_text(comptime T: type, value: T, options: Options, expected: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try json.stringify(T, &tree, &aw.writer, value, options, &diag);
    try expect_untouched(&diag);
    try testing.expectEqualStrings(expected, aw.written());
}

/// Expects `err`, nothing written to a writer when `empty_output`, and a position-less message
/// equal to `message` (or starting with it when `prefix`). A second write would replace it.
fn expect_fail(
    comptime T: type,
    value: T,
    options: Options,
    err: json.StringifyError,
    message: []const u8,
    comptime prefix: bool,
) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = json.stringify(T, &tree, &aw.writer, value, options, &diag);
    try testing.expectError(err, result);
    if (prefix) {
        try testing.expect(std.mem.startsWith(u8, diag.message(), message));
    } else {
        try testing.expectEqualStrings(message, diag.message());
    }
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
}

const Tls = struct { cert: []const u8, key: []const u8 };

/// The PRD section 4.2 example, verbatim.
const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    tags: []const []const u8 = &.{},
    tls: ?Tls = null,

    pub const sigil_options = .{
        .rename = .{ .name = "server_name" },
        .rename_all = .snake_case,
        .deny_unknown_fields = true,
    };
};

const Mode = enum { fast, slow };
const Shape = union(enum) { none, circle: f64, rect: struct { w: u32, h: u32 } };
const Unsorted = struct { z: u8, a: u8, m: u8 };

test "stringify: a struct is its fields in declaration order under their wire names" {
    const plain: Config = .{ .name = "edge" };
    const plain_text = "{\"server_name\":\"edge\",\"port\":8080,\"tags\":[],\"tls\":null}";
    try expect_text(Config, plain, minified, plain_text);

    const full: Config = .{
        .name = "edge",
        .port = 9090,
        .tags = &.{ "a", "b" },
        .tls = .{ .cert = "c.pem", .key = "k.pem" },
    };
    const full_text = "{\"server_name\":\"edge\",\"port\":9090,\"tags\":[\"a\",\"b\"]," ++
        "\"tls\":{\"cert\":\"c.pem\",\"key\":\"k.pem\"}}";
    try expect_text(Config, full, minified, full_text);
}

test "stringify: pretty puts every member on its own line and keeps empty containers inline" {
    const value: Config = .{ .name = "edge", .tags = &.{ "a", "b" } };
    const expected2 =
        \\{
        \\  "server_name": "edge",
        \\  "port": 8080,
        \\  "tags": [
        \\    "a",
        \\    "b"
        \\  ],
        \\  "tls": null
        \\}
    ;
    try expect_text(Config, value, pretty(2), expected2);
    const empty_tags: Config = .{ .name = "x" };
    const expected4 = "{\n    \"server_name\": \"x\",\n    \"port\": 8080,\n    \"tags\": [],\n" ++
        "    \"tls\": null\n}";
    try expect_text(Config, empty_tags, pretty(4), expected4);
    try expect_text([]const u8, "s", pretty(8), "\"s\"");
}

test "stringify: sort_keys orders struct fields and string maps by key bytes" {
    const value: Unsorted = .{ .z = 1, .a = 2, .m = 3 };
    try expect_text(Unsorted, value, minified, "{\"z\":1,\"a\":2,\"m\":3}");
    try expect_text(Unsorted, value, sorted(minified), "{\"a\":2,\"m\":3,\"z\":1}");
    const pretty_sorted = "{\n  \"a\": 2,\n  \"m\": 3,\n  \"z\": 1\n}";
    try expect_text(Unsorted, value, sorted(pretty(2)), pretty_sorted);

    var map: std.array_hash_map.String(i8) = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "b", -1);
    try map.put(testing.allocator, "a", 2);
    const Map8 = std.array_hash_map.String(i8);
    try expect_text(Map8, map, minified, "{\"b\":-1,\"a\":2}");
    try expect_text(Map8, map, sorted(minified), "{\"a\":2,\"b\":-1}");
}

test "stringify: optionals, enums, slices, arrays and unions" {
    try expect_text(?u8, null, minified, "null");
    try expect_text(?u8, 3, minified, "3");
    try expect_text(?[]const u8, "x", minified, "\"x\"");
    try expect_text(Mode, .slow, minified, "\"slow\"");
    try expect_text(?Mode, null, minified, "null");
    try expect_text([]const i32, &.{ 1, -2, 3 }, minified, "[1,-2,3]");
    try expect_text([]const i32, &.{}, minified, "[]");
    try expect_text([2]u8, .{ 7, 8 }, minified, "[7,8]");
    const certs: []const Tls = &.{.{ .cert = "c", .key = "k" }};
    try expect_text([]const Tls, certs, minified, "[{\"cert\":\"c\",\"key\":\"k\"}]");
    try expect_text(Shape, .none, minified, "\"none\"");
    try expect_text(Shape, .{ .circle = 2.5 }, minified, "{\"circle\":2.5}");
    const rect: Shape = .{ .rect = .{ .w = 3, .h = 4 } };
    try expect_text(Shape, rect, minified, "{\"rect\":{\"w\":3,\"h\":4}}");
}

test "stringify: scalars keep their kind: integers stay integers and floats carry a point" {
    try expect_text(bool, true, minified, "true");
    try expect_text(i64, std.math.minInt(i64), minified, "-9223372036854775808");
    try expect_text(u64, std.math.maxInt(u64), minified, "18446744073709551615");
    try expect_text(u8, 255, minified, "255");
    try expect_text(f64, 1.0, minified, "1.0");
    try expect_text(f64, -0.0, minified, "-0.0");
    try expect_text(f32, 0.5, minified, "0.5");
    try expect_text(f64, 1e300, minified, "1e300");
}

test "stringify: strings are escaped by the policy of the options" {
    try expect_text([]const u8, "a\"b\\c\n\x01", minified, "\"a\\\"b\\\\c\\n\\u0001\"");
    try expect_text([]const u8, "\xC3\xA9", minified, "\"\xC3\xA9\"");
    var ascii = minified;
    ascii.escape = .ascii_only;
    try expect_text([]const u8, "\xC3\xA9", ascii, "\"\\u00e9\"");
    const Named = struct { @"k\"ey": u8 };
    try expect_text(Named, .{ .@"k\"ey" = 1 }, minified, "{\"k\\\"ey\":1}");
}

/// Stringifies then parses `value` and compares the parsed value to it.
fn round_trip(comptime T: type, value: T, options: Options) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try json.stringify(T, &tree, &aw.writer, value, options, &diag);
    try expect_untouched(&diag);
    const parse_options: json.ParseOptions = .{
        .depth_max = 128,
        .bytes_max = 1 << 20,
        .duplicate_key = .reject,
    };
    const back = try json.parse(T, &tree, aw.written(), parse_options, &diag);
    try expect_untouched(&diag);
    try testing.expectEqualDeep(value, back);
}

test "stringify: json.parse reads back what json.stringify wrote, in every layout" {
    const Mixed = struct {
        shapes: []const Shape,
        mode: Mode,
        grid: [2]u8,
        maybe: ?i32,
        big: u64,
        low: i64,
        ratio: f64,
        text: []const u8,
    };
    const mixed: Mixed = .{
        .shapes = &.{ .none, .{ .circle = 2.5 }, .{ .rect = .{ .w = 3, .h = 4 } } },
        .mode = .slow,
        .grid = .{ 7, 8 },
        .maybe = null,
        .big = std.math.maxInt(u64),
        .low = std.math.minInt(i64),
        .ratio = -0.25,
        .text = "line\nbreak \"quoted\" \xC3\xA9\xF0\x9F\x98\x80",
    };
    const config: Config = .{
        .name = "edge",
        .port = 1,
        .tags = &.{ "a", "" },
        .tls = .{ .cert = "c", .key = "k" },
    };
    const layouts = [_]Options{
        minified,         pretty(1),         pretty(8),
        sorted(minified), sorted(pretty(2)),
    };
    for (layouts) |options| {
        try round_trip(Mixed, mixed, options);
        try round_trip(Config, config, options);
    }
}

test "stringify: stringify of a Value is write_value of it, for 200 seeded values" {
    for (0..200) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const value = try writer_test.random_value(arena, prng.random(), 0);
        errdefer std.log.err("stringify model failed, seed {d}", .{seed});

        const options = if (seed % 2 == 0) minified else sorted(pretty(@intCast(1 + seed % 8)));
        var expected: std.Io.Writer.Allocating = .init(arena);
        var diag = fresh_diag();
        try json.write_value(&expected.writer, value, options, &diag);

        var tree: ValueTree = undefined;
        tree.init(testing.allocator);
        defer tree.deinit();
        var actual: std.Io.Writer.Allocating = .init(arena);
        try json.stringify(Value, &tree, &actual.writer, value, options, &diag);
        try expect_untouched(&diag);
        try testing.expectEqualStrings(expected.written(), actual.written());
    }
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

const limit_message = "exceeds nesting depth limit 128";

fn fail_invalid_utf8_reflect() !void {
    const bad = "ab\xff";
    try expect_fail([]const u8, bad, minified, error.InvalidUtf8, "invalid UTF-8 at byte 2", true);
    const Named = struct { name: []const u8 };
    const field: Named = .{ .name = "x\xC3" };
    const named_message = "name: invalid UTF-8 at byte 1";
    try expect_fail(Named, field, minified, error.InvalidUtf8, named_message, true);
    const Fleet = struct { servers: []const Named };
    const servers: Fleet = .{ .servers = &.{ .{ .name = "ok" }, .{ .name = "\xFF" } } };
    const path = "servers[1].name: invalid UTF-8 at byte 0";
    try expect_fail(Fleet, servers, minified, error.InvalidUtf8, path, true);
}

fn fail_invalid_utf8_writer() !void {
    // `reflect.stringify` copies a `Value` without judging its text; the writer does.
    var entries: [1]Map.Entry = undefined;
    var map = Map.init(&entries);
    try map.put("k", .{ .string = "\xFF" });
    const message = "k: string is not valid UTF-8";
    try expect_fail(Value, .{ .map = map }, minified, error.InvalidUtf8, message, false);
}

fn fail_input_too_large() !void {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    // The pointer is never read: the length gate runs first.
    const base: [*]const u8 = @ptrFromInt(1);
    const huge = base[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try expect_fail([]const u8, huge, minified, error.InputTooLarge, "string is longer than", true);
    const Named = struct { name: []const u8 };
    const field: Named = .{ .name = huge };
    try expect_fail(Named, field, minified, error.InputTooLarge, "name: string is longer", true);
}

fn fail_too_deep() !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Reflect's boundary: 128 containers pass, the 129th is TooDeep.
    const over = try nested_arrays(arena, 129);
    try expect_fail(Value, over, minified, error.TooDeep, limit_message, false);
    // The writer's boundary is its own `depth_max`.
    var shallow = minified;
    shallow.depth_max = 2;
    const three = try nested_arrays(arena, 3);
    try expect_fail(Value, three, shallow, error.TooDeep, "[0][0]: exceeds the depth limit", false);
}

fn fail_out_of_memory() !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = json.stringify([]const u8, &tree, &aw.writer, "abc", minified, &diag);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(diag.line != sentinel_line);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(diag.message().len > 0);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

fn fail_unrepresentable() !void {
    const unrepresentable = error.Unrepresentable;
    const bytes_message = "bytes cannot be written as JSON";
    try expect_fail(Value, .{ .bytes = "ab" }, minified, unrepresentable, bytes_message, false);
    const stamp: core.Timestamp = .{ .seconds = 0, .nanoseconds = 0, .offset_minutes = null };
    const stamp_message = "timestamp cannot be written as JSON";
    try expect_fail(core.Timestamp, stamp, minified, unrepresentable, stamp_message, false);
    const nan = std.math.nan(f64);
    try expect_fail(f64, nan, minified, unrepresentable, "NaN cannot be written as JSON", false);
    const Series = struct { items: []const f64 };
    const series: Series = .{ .items = &.{ 1.0, std.math.inf(f64) } };
    const inf_message = "items[1]: infinity cannot be written as JSON";
    try expect_fail(Series, series, pretty(2), unrepresentable, inf_message, false);
    const negative: Series = .{ .items = &.{-std.math.inf(f64)} };
    const negative_message = "items[0]: infinity cannot be written as JSON";
    try expect_fail(Series, negative, minified, unrepresentable, negative_message, false);
}

fn fail_write_failed() !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var failing: std.Io.Writer = .failing;
    var diag = fresh_diag();
    const config: Config = .{ .name = "edge" };
    const result = json.stringify(Config, &tree, &failing, config, minified, &diag);
    try testing.expectError(error.WriteFailed, result);
    try testing.expect(std.mem.endsWith(u8, diag.message(), "output writer failed"));
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
}

const Case = struct { err: json.StringifyError, run: *const fn () anyerror!void };

const cases = [_]Case{
    .{ .err = error.InvalidUtf8, .run = fail_invalid_utf8_reflect },
    .{ .err = error.InvalidUtf8, .run = fail_invalid_utf8_writer },
    .{ .err = error.InputTooLarge, .run = fail_input_too_large },
    .{ .err = error.TooDeep, .run = fail_too_deep },
    .{ .err = error.OutOfMemory, .run = fail_out_of_memory },
    .{ .err = error.Unrepresentable, .run = fail_unrepresentable },
    .{ .err = error.WriteFailed, .run = fail_write_failed },
};

test "stringify: StringifyError is reflect's 4 variants plus Unrepresentable and WriteFailed" {
    const names = @typeInfo(json.StringifyError).error_set.?;
    try testing.expectEqual(@as(usize, 6), names.len);
    inline for (.{
        "InvalidUtf8", "InputTooLarge", "TooDeep", "OutOfMemory", "Unrepresentable", "WriteFailed",
    }) |name| {
        const present = comptime for (names) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) break true;
        } else false;
        try testing.expect(present);
    }
}

test "stringify: every StringifyError variant is provoked, with a position-less message" {
    var covered = [_]bool{false} ** 8;
    for (cases) |case| {
        // proof: only the 32-bit InputTooLarge case skips itself; any other error fails here.
        case.run() catch |err| switch (err) {
            error.SkipZigTest => {},
            else => return err,
        };
        inline for (@typeInfo(json.StringifyError).error_set.?, 0..) |name, index| {
            if (case.err == @field(json.StringifyError, name.name)) covered[index] = true;
        }
    }
    inline for (@typeInfo(json.StringifyError).error_set.?, 0..) |name, index| {
        errdefer std.log.err("StringifyError.{s} is never provoked", .{name.name});
        try testing.expect(covered[index]);
    }
}

test "stringify: a reflect failure writes no output byte and a writer failure keeps the prefix" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var diag = fresh_diag();

    const Pair = struct { first: []const u8, second: []const u8 };
    const bad: Pair = .{ .first = "fine", .second = "\xFF" };
    const refused = json.stringify(Pair, &tree, &aw.writer, bad, minified, &diag);
    try testing.expectError(error.InvalidUtf8, refused);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "second: invalid UTF-8 at byte 0"));
    try testing.expectEqual(@as(usize, 0), aw.written().len);

    const Series = struct { items: []const f64 };
    const series: Series = .{ .items = &.{ 1.0, std.math.nan(f64), 3.0 } };
    diag = fresh_diag();
    const result = json.stringify(Series, &tree, &aw.writer, series, minified, &diag);
    try testing.expectError(error.Unrepresentable, result);
    try testing.expectEqualStrings("{\"items\":[1.0,", aw.written());
}

test "stringify: a fixed writer fails at every capacity below the output length" {
    const value: Config = .{ .name = "edge", .tags = &.{"a"} };
    for ([_]Options{ minified, pretty(2) }) |options| {
        var tree: ValueTree = undefined;
        tree.init(testing.allocator);
        defer tree.deinit();
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var ok_diag = fresh_diag();
        try json.stringify(Config, &tree, &aw.writer, value, options, &ok_diag);
        const output_len = aw.written().len;

        var buffer: [256]u8 = undefined;
        for (0..output_len + 1) |capacity| {
            var fixed: std.Io.Writer = .fixed(buffer[0..capacity]);
            var diag = fresh_diag();
            const result = json.stringify(Config, &tree, &fixed, value, options, &diag);
            if (capacity < output_len) {
                try testing.expectError(error.WriteFailed, result);
                try testing.expect(std.mem.endsWith(u8, diag.message(), "output writer failed"));
                try testing.expectEqual(position_none, diag.line);
            } else {
                try result;
                try expect_untouched(&diag);
                try testing.expectEqualStrings(aw.written(), fixed.buffered());
            }
        }
    }
}

test "stringify: every allocation failing in turn is OutOfMemory or the same text, leak free" {
    const tls: Tls = .{ .cert = "c", .key = "k" };
    const value: Config = .{ .name = "edge", .tags = &.{ "a", "b" }, .tls = tls };
    var expected: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    {
        var tree: ValueTree = undefined;
        tree.init(testing.allocator);
        defer tree.deinit();
        var diag = fresh_diag();
        try json.stringify(Config, &tree, &expected.writer, value, minified, &diag);
    }
    for (0..256) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();

        var diag = fresh_diag();
        const result = json.stringify(Config, &tree, &aw.writer, value, minified, &diag);
        if (result) |_| {
            try testing.expect(index > 0);
            try expect_untouched(&diag);
            try testing.expectEqualStrings(expected.written(), aw.written());
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(diag.line != sentinel_line);
            try testing.expectEqualStrings("", aw.written());
        }
    }
    return error.NeverSucceeded;
}

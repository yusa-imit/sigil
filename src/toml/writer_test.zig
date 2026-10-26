//! Tests for `toml/writer.zig` (plan 006 item 9, ADR 0005 section 8): golden output written by
//! hand from the contract (insertion order, key/value lines before the trailing run of header
//! tables, inline form elsewhere, a blank line before every header but the first), quoting of
//! keys and strings, floats, timestamps, every refusal with its key path, every declared error,
//! the depth boundary, and re-parse equality of the TOML 1.0 spec example.

const std = @import("std");
const core = @import("../core.zig");
const toml = @import("../toml.zig");
const writer = @import("writer.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing = std.testing;

const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Value = core.Value;
const ValueTree = core.ValueTree;

const options: writer.StringifyOptions = .{ .depth_max = 128 };
const parse_options: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };
const sentinel_line: u32 = 777;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

/// Parses `source` into `tree` and returns its root.
fn parse_into(tree: *ValueTree, source: []const u8) !Value {
    var diag = fresh_diag();
    return toml.parse_value(testing.allocator, tree, source, parse_options, &diag);
}

/// Parses `source`, writes the tree, and expects exactly `expected`; success leaves `diag` alone.
fn expect_written(source: []const u8, expected: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const root = try parse_into(&tree, source);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try writer.write(&aw.writer, root, options, &diag);
    try expectEqual(sentinel_line, diag.line);
    try expectEqualStrings(expected, aw.written());
}

fn map_of(entries: []Map.Entry, keys: []const []const u8, values: []const Value) !Value {
    var map = Map.init(entries);
    for (keys, values) |key, value| try map.put(key, value);
    return .{ .map = map };
}

/// Expects `err` and a diagnostic message equal to `message`, at `position_none`.
fn expect_fail(
    value: Value,
    write_options: writer.StringifyOptions,
    err: writer.WriteValueError,
    message: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try testing.expectError(err, writer.write(&aw.writer, value, write_options, &diag));
    try expectEqualStrings(message, diag.message());
    try expectEqual(core.diagnostics.position_none, diag.line);
}

test "writer: scalars keep their order and are normalized" {
    try expect_written(
        \\a = 1
        \\b = "x"
        \\c = true
        \\d = 1.5
        \\e = -0.0
        \\f = inf
        \\g = -inf
        \\h = nan
        \\i = 1e21
        \\j = 0x10
        \\k = 1_000
        \\l = 'lit'
        \\m = 5e+2
        \\
    ,
        \\a = 1
        \\b = "x"
        \\c = true
        \\d = 1.5
        \\e = -0.0
        \\f = inf
        \\g = -inf
        \\h = nan
        \\i = 1e21
        \\j = 16
        \\k = 1000
        \\l = "lit"
        \\m = 500.0
        \\
    );
    try expect_written("", "");
    try expect_written("-nan = -nan", "-nan = nan\n");
}

test "writer: tables, arrays of tables and sub-tables use header form with blank lines" {
    try expect_written(
        \\title = "T"
        \\[owner]
        \\name = "x"
        \\[owner.dob]
        \\d = 1979-05-27
        \\
    ,
        \\title = "T"
        \\
        \\[owner]
        \\name = "x"
        \\
        \\[owner.dob]
        \\d = 1979-05-27
        \\
    );
    try expect_written(
        \\[[products]]
        \\name = "a"
        \\[products.dims]
        \\w = 1
        \\[[products]]
        \\name = "b"
        \\
    ,
        \\[[products]]
        \\name = "a"
        \\
        \\[products.dims]
        \\w = 1
        \\
        \\[[products]]
        \\name = "b"
        \\
    );
    try expect_written("[a]\nz = 1\ny = 2\n[b]\nq = 1\n", "[a]\nz = 1\ny = 2\n\n[b]\nq = 1\n");
}

test "writer: a table before a scalar is inline, a trailing array of maps is header form" {
    try expect_written(
        "a = { x = 1, y = { z = 2 } }\nb = 2\n",
        "a = { x = 1, y = { z = 2 } }\nb = 2\n",
    );
    try expect_written(
        "a = [{ x = 1 }, { y = 2 }]\nb = 3\n",
        "a = [{ x = 1 }, { y = 2 }]\nb = 3\n",
    );
    try expect_written(
        "a = 1\nb = [{ x = 1 }, { y = 2 }]\n",
        "a = 1\n\n[[b]]\nx = 1\n\n[[b]]\ny = 2\n",
    );
    try expect_written("b = [{ x = 1 }, 2]\n", "b = [{ x = 1 }, 2]\n");
}

test "writer: empty and nested containers" {
    try expect_written("a = []\n", "a = []\n");
    try expect_written("a = {}\nb = 1\n", "a = {}\nb = 1\n");
    try expect_written("a = {}\n", "[a]\n");
    try expect_written("a = [{}]\n", "[[a]]\n");
    try expect_written("a = [[1, 2], [], [\"x\"]]\n", "a = [[1, 2], [], [\"x\"]]\n");
    try expect_written("a = [1, \"a\", 2.5, {}]\n", "a = [1, \"a\", 2.5, {}]\n");
    try expect_written("a = [{ b = [{ c = 1 }] }]\nd = 1\n", "a = [{ b = [{ c = 1 }] }]\nd = 1\n");
}

test "writer: keys are bare only when they match the bare-key set" {
    try expect_written(
        "\"a b\" = 1\n\"\" = 2\nx.\"y.z\" = 3\n\"\u{e9}\" = 4\nok-key_1 = 5\n",
        "\"a b\" = 1\n\"\" = 2\nx = { \"y.z\" = 3 }\n\"\u{e9}\" = 4\nok-key_1 = 5\n",
    );
    try expect_written("[a.\"b c\"]\nk = 1\n", "[a]\n\n[a.\"b c\"]\nk = 1\n");
    try expect_written("\"a\\tb\" = 1\n", "\"a\\tb\" = 1\n");
}

test "writer: strings are basic strings with controls escaped and non-ASCII raw" {
    try expect_written(
        \\s = "q\"\\\n\u007fé\t\u0001"
        \\
    , "s = \"q\\\"\\\\\\n\\u007f\u{e9}\\t\\u0001\"\n");
    try expect_written("s = '''a\nb'''\n", "s = \"a\\nb\"\n");
}

test "writer: every timestamp kind prints its canonical spelling" {
    try expect_written(
        \\a = 1979-05-27T07:32:00Z
        \\b = 1979-05-27 00:32:00-07:00
        \\c = 1979-05-27T07:32:00
        \\d = 1979-05-27
        \\e = 07:32:00.5
        \\f = 1979-05-27t07:32:00.123456789z
        \\
    ,
        \\a = 1979-05-27T07:32:00Z
        \\b = 1979-05-27T00:32:00-07:00
        \\c = 1979-05-27T07:32:00
        \\d = 1979-05-27
        \\e = 07:32:00.5
        \\f = 1979-05-27T07:32:00.123456789Z
        \\
    );
}

test "writer: an unsigned integer up to maxInt(i64) is written as an integer" {
    var entries: [2]Map.Entry = undefined;
    const value = try map_of(&entries, &.{ "a", "b" }, &.{
        .{ .uint = 5 },
        .{ .uint = std.math.maxInt(i64) },
    });
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try writer.write(&aw.writer, value, options, &diag);
    try expectEqualStrings("a = 5\nb = 9223372036854775807\n", aw.written());
}

test "writer: null, bytes, big uint and out-of-range timestamps are refused with their path" {
    const unrepresentable = error.Unrepresentable;
    var inner: [1]Map.Entry = undefined;
    const table = try map_of(&inner, &.{"b"}, &.{.null});
    var outer: [1]Map.Entry = undefined;
    const nested = try map_of(&outer, &.{"a"}, &.{table});
    try expect_fail(nested, options, unrepresentable, "a.b: null cannot be written as TOML");

    const items = [_]Value{ .{ .int = 1 }, .{ .bytes = "ab" } };
    var list: [2]Map.Entry = undefined;
    const in_array = try map_of(&list, &.{ "x", "y" }, &.{ .{ .array = &items }, .{ .int = 1 } });
    try expect_fail(in_array, options, unrepresentable, "x[1]: bytes cannot be written as TOML");

    var big: [1]Map.Entry = undefined;
    const too_big = try map_of(&big, &.{"n"}, &.{.{ .uint = std.math.maxInt(i64) + 1 }});
    const big_text = "n: integer above 9223372036854775807 cannot be written as TOML";
    try expect_fail(too_big, options, unrepresentable, big_text);

    const year_10000: core.Timestamp = .{
        .kind = .instant,
        .seconds = 253_402_300_800,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    var late: [1]Map.Entry = undefined;
    const stamped = try map_of(&late, &.{"t"}, &.{.{ .timestamp = year_10000 }});
    const stamp_text = "t: timestamp has no four-digit year, so TOML cannot hold it";
    try expect_fail(stamped, options, unrepresentable, stamp_text);

    var spaced: [1]Map.Entry = undefined;
    const quoted = try map_of(&spaced, &.{"b c"}, &.{.null});
    try expect_fail(quoted, options, unrepresentable, "[\"b c\"]: null cannot be written as TOML");
}

test "writer: a root that is not a map is RootNotTable" {
    const reason = "the root of a TOML document must be a table";
    try expect_fail(.{ .int = 1 }, options, error.RootNotTable, reason);
    try expect_fail(.null, options, error.RootNotTable, reason);
    const items = [_]Value{.null};
    try expect_fail(.{ .array = &items }, options, error.RootNotTable, reason);
}

test "writer: text that is not UTF-8 is InvalidUtf8, in a value and in a key" {
    var one: [1]Map.Entry = undefined;
    const bad_value = try map_of(&one, &.{"s"}, &.{.{ .string = "a\xffb" }});
    try expect_fail(bad_value, options, error.InvalidUtf8, "s: string is not valid UTF-8");

    var two: [1]Map.Entry = undefined;
    const bad_key = try map_of(&two, &.{"k\xff"}, &.{.{ .int = 1 }});
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try testing.expectError(error.InvalidUtf8, writer.write(&aw.writer, bad_key, options, &diag));
    try expect(std.mem.endsWith(u8, diag.message(), ": string is not valid UTF-8"));
    try expectEqualStrings("\"", aw.written());
}

test "writer: a failing output writer is WriteFailed and leaves a prefix" {
    var one: [1]Map.Entry = undefined;
    const value = try map_of(&one, &.{"a"}, &.{.{ .string = "a much longer string" }});
    var buffer: [8]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    var diag = fresh_diag();
    try testing.expectError(error.WriteFailed, writer.write(&fixed, value, options, &diag));
    try expectEqualStrings("a: output writer failed", diag.message());
    try expectEqualStrings("a = \"", fixed.buffered()[0..5]);
}

test "writer: depth_max counts containers including the root" {
    var empty: [0]Map.Entry = .{};
    const leaf = try map_of(&empty, &.{}, &.{});
    var b_entries: [1]Map.Entry = undefined;
    const b = try map_of(&b_entries, &.{"b"}, &.{leaf});
    var a_entries: [1]Map.Entry = undefined;
    const a = try map_of(&a_entries, &.{"a"}, &.{b});

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var diag = fresh_diag();
    try writer.write(&out.writer, a, .{ .depth_max = 3 }, &diag);
    try expectEqualStrings("[a]\n\n[a.b]\n", out.written());
    try expect_fail(a, .{ .depth_max = 2 }, error.TooDeep, "a.b: exceeds the depth limit");

    const items = [_]Value{leaf};
    var list: [1]Map.Entry = undefined;
    const tables = try map_of(&list, &.{"t"}, &.{.{ .array = &items }});
    try expect_fail(tables, .{ .depth_max = 2 }, error.TooDeep, "t[0]: exceeds the depth limit");
    out.clearRetainingCapacity();
    try writer.write(&out.writer, tables, .{ .depth_max = 3 }, &diag);
    try expectEqualStrings("[[t]]\n", out.written());
}

test "writer: an inline container counts against depth_max too" {
    const inner = [_]Value{.{ .int = 1 }};
    var entries: [2]Map.Entry = undefined;
    const value = try map_of(&entries, &.{ "a", "b" }, &.{ .{ .array = &inner }, .{ .int = 2 } });
    try expect_fail(value, .{ .depth_max = 1 }, error.TooDeep, "a: exceeds the depth limit");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var diag = fresh_diag();
    try writer.write(&out.writer, value, .{ .depth_max = 2 }, &diag);
    try expectEqualStrings("a = [1]\nb = 2\n", out.written());
}

/// `[a.a.a...]` with `segments` segments, as TOML text in `out`.
fn header_chain(out: *std.Io.Writer.Allocating, segments: u32) !void {
    try out.writer.writeByte('[');
    for (0..segments) |index| {
        if (index > 0) try out.writer.writeByte('.');
        try out.writer.writeByte('a');
    }
    try out.writer.writeAll("]\n");
}

test "writer: 127 header segments pass at depth_max 128 and are TooDeep at 127" {
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();

    try header_chain(&source, 127);
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const root = try parse_into(&tree, source.written());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var diag = fresh_diag();
    try writer.write(&out.writer, root, .{ .depth_max = 128 }, &diag);
    var again: ValueTree = undefined;
    again.init(testing.allocator);
    defer again.deinit();

    const reparsed = try parse_into(&again, out.written());
    try expect(try core.value.eql(root, reparsed));
    const shallow: writer.StringifyOptions = .{ .depth_max = 127 };
    try testing.expectError(error.TooDeep, writer.write(&out.writer, root, shallow, &diag));
    try expect(diag.message().len > 0);
}

const spec_example =
    \\# This is a TOML document
    \\title = "TOML Example"
    \\
    \\[owner]
    \\name = "Tom Preston-Werner"
    \\dob = 1979-05-27T07:32:00-08:00
    \\
    \\[database]
    \\enabled = true
    \\ports = [ 8000, 8001, 8002 ]
    \\data = [ ["delta", "phi"], [3.14] ]
    \\temp_targets = { cpu = 79.5, case = 72.0 }
    \\
    \\[servers]
    \\
    \\[servers.alpha]
    \\ip = "10.0.0.1"
    \\role = "frontend"
    \\
    \\[servers.beta]
    \\ip = "10.0.0.2"
    \\role = "backend"
    \\
    \\[[products]]
    \\name = "Hammer"
    \\sku = 738594937
    \\
    \\[[products]]
    \\
    \\[[products]]
    \\name = "Nail"
    \\sku = 284758393
    \\color = "gray"
    \\
    \\[fruit.physical]
    \\color = "red"
    \\shape = "round"
    \\
    \\[[fruit.variety]]
    \\name = "red delicious"
    \\
;

test "writer: the spec example re-parses eql and a second write is byte-identical" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const root = try parse_into(&tree, spec_example);
    var first: std.Io.Writer.Allocating = .init(testing.allocator);
    defer first.deinit();

    var diag = fresh_diag();
    try writer.write(&first.writer, root, options, &diag);
    var again: ValueTree = undefined;
    again.init(testing.allocator);
    defer again.deinit();

    const reparsed = try parse_into(&again, first.written());
    try expect(try core.value.eql(root, reparsed));
    var second: std.Io.Writer.Allocating = .init(testing.allocator);
    defer second.deinit();

    try writer.write(&second.writer, reparsed, options, &diag);
    try expectEqualStrings(first.written(), second.written());
    try expectEqual(sentinel_line, diag.line);
}

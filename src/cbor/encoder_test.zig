//! Tests for `cbor/encoder.zig` (plan 007 item 7): RFC 8949 Appendix A encodings byte for byte,
//! the shortest-float and NaN policy, timestamps as tags 0 and 1, deterministic key order, every
//! refusal with its key path, every declared error, a full-writer sweep and the round trip
//! through the decoder.

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

const sentinel_line: u32 = 777;
const plain: encoder.StringifyOptions = .{ .depth_max = 128, .deterministic = false };
const sorted: encoder.StringifyOptions = .{ .depth_max = 128, .deterministic = true };

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Encodes `value` and returns the bytes; the caller frees them.
fn encode(value: Value, options: encoder.StringifyOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();

    var diag = fresh_diag();
    try encoder.write(&aw.writer, value, options, &diag);
    try expectEqual(sentinel_line, diag.line);
    return aw.toOwnedSlice();
}

fn expect_hex_with(value: Value, options: encoder.StringifyOptions, hex: []const u8) !void {
    var expected: [128]u8 = undefined;
    const want = try std.fmt.hexToBytes(&expected, hex);
    const bytes = try encode(value, options);
    defer std.testing.allocator.free(bytes);

    try expectEqualSlices(u8, want, bytes);
}

fn expect_hex(value: Value, hex: []const u8) !void {
    return expect_hex_with(value, plain, hex);
}

/// Expects `err` and a diagnostic message equal to `message`, at `position_none`.
fn expect_fail(
    value: Value,
    depth_max: u16,
    err: encoder.WriteValueError,
    message: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const options: encoder.StringifyOptions = .{ .depth_max = depth_max, .deterministic = false };
    const result = encoder.write(&aw.writer, value, options, &diag);
    try std.testing.expectError(err, result);
    try expectEqualStrings(message, diag.message());
    try expectEqual(core.diagnostics.position_none, diag.line);
}

fn map_of(entries: []Map.Entry, keys: []const []const u8, values: []const Value) !Value {
    var map = Map.init(entries);
    for (keys, values) |key, value| try map.put(key, value);
    return .{ .map = map };
}

fn instant(seconds: i64, nanoseconds: u32, offset_minutes: ?i16) Value {
    return .{ .timestamp = .{
        .kind = .instant,
        .seconds = seconds,
        .nanoseconds = nanoseconds,
        .offset_minutes = offset_minutes,
    } };
}

test "encoder: scalars" {
    try expect_hex(.null, "f6");
    try expect_hex(.{ .bool = false }, "f4");
    try expect_hex(.{ .bool = true }, "f5");
}

test "encoder: integers take the shortest head, Appendix A and every boundary" {
    const cases = [_]struct { number: i64, hex: []const u8 }{
        .{ .number = 0, .hex = "00" },
        .{ .number = 10, .hex = "0a" },
        .{ .number = 23, .hex = "17" },
        .{ .number = 24, .hex = "1818" },
        .{ .number = 255, .hex = "18ff" },
        .{ .number = 256, .hex = "190100" },
        .{ .number = 65535, .hex = "19ffff" },
        .{ .number = 65536, .hex = "1a00010000" },
        .{ .number = 4294967295, .hex = "1affffffff" },
        .{ .number = 4294967296, .hex = "1b0000000100000000" },
        .{ .number = 1000000000000, .hex = "1b000000e8d4a51000" },
        .{ .number = std.math.maxInt(i64), .hex = "1b7fffffffffffffff" },
        .{ .number = -1, .hex = "20" },
        .{ .number = -10, .hex = "29" },
        .{ .number = -24, .hex = "37" },
        .{ .number = -25, .hex = "3818" },
        .{ .number = -100, .hex = "3863" },
        .{ .number = -256, .hex = "38ff" },
        .{ .number = -257, .hex = "390100" },
        .{ .number = -1000, .hex = "3903e7" },
        .{ .number = -65536, .hex = "39ffff" },
        .{ .number = -65537, .hex = "3a00010000" },
        .{ .number = -4294967296, .hex = "3affffffff" },
        .{ .number = -4294967297, .hex = "3b0000000100000000" },
        .{ .number = std.math.minInt(i64), .hex = "3b7fffffffffffffff" },
    };
    for (cases) |case| try expect_hex(.{ .int = case.number }, case.hex);
}

test "encoder: a uint is written unsigned and shortest, small ones included" {
    try expect_hex(.{ .uint = 5 }, "05");
    try expect_hex(.{ .uint = 24 }, "1818");
    try expect_hex(.{ .uint = std.math.maxInt(u64) }, "1bffffffffffffffff");
    try expect_hex(.{ .uint = @as(u64, std.math.maxInt(i64)) + 1 }, "1b8000000000000000");
}

test "encoder: floats take f16, f32 or f64, whichever keeps the value exactly" {
    const cases = [_]struct { number: f64, hex: []const u8 }{
        .{ .number = 0.0, .hex = "f90000" },
        .{ .number = -0.0, .hex = "f98000" },
        .{ .number = 1.0, .hex = "f93c00" },
        .{ .number = 1.5, .hex = "f93e00" },
        .{ .number = 65504.0, .hex = "f97bff" },
        .{ .number = 65505.0, .hex = "fa477fe100" },
        .{ .number = 100000.0, .hex = "fa47c35000" },
        .{ .number = 3.4028234663852886e38, .hex = "fa7f7fffff" },
        .{ .number = 1.1, .hex = "fb3ff199999999999a" },
        .{ .number = 1.0e300, .hex = "fb7e37e43c8800759c" },
        .{ .number = 0x1p-24, .hex = "f90001" },
        .{ .number = 0.00006103515625, .hex = "f90400" },
        .{ .number = 0x1p-25, .hex = "fa33000000" },
        .{ .number = -4.0, .hex = "f9c400" },
        .{ .number = -4.1, .hex = "fbc010666666666666" },
        .{ .number = std.math.inf(f64), .hex = "f97c00" },
        .{ .number = -std.math.inf(f64), .hex = "f9fc00" },
    };
    for (cases) |case| try expect_hex(.{ .float = case.number }, case.hex);
}

test "encoder: every NaN is the one quiet positive NaN f9 7e00" {
    const nans = [_]u64{
        0x7ff8000000000000, // The default quiet NaN.
        0xfff8000000000000, // Negative sign.
        0x7ff0000000000001, // A signalling payload.
        0x7ff8dead00000000, // A payload kept by wide NaNs.
    };
    for (nans) |bits| try expect_hex(.{ .float = @bitCast(bits) }, "f97e00");
}

test "encoder: strings and byte strings, Appendix A and the length heads" {
    try expect_hex(.{ .string = "" }, "60");
    try expect_hex(.{ .string = "a" }, "6161");
    try expect_hex(.{ .string = "IETF" }, "6449455446");
    try expect_hex(.{ .string = "\"\\" }, "62225c");
    try expect_hex(.{ .string = "\u{00fc}" }, "62c3bc");
    try expect_hex(.{ .string = "\u{6c34}" }, "63e6b0b4");
    try expect_hex(.{ .string = "\u{10151}" }, "64f0908591");
    try expect_hex(.{ .bytes = "" }, "40");
    try expect_hex(.{ .bytes = "\x01\x02\x03\x04" }, "4401020304");

    const lengths = [_]usize{ 23, 24, 255, 256, 65535, 65536 };
    const heads = [_][]const u8{
        "\x77",         "\x78\x18",     "\x78\xff",
        "\x79\x01\x00", "\x79\xff\xff", "\x7a\x00\x01\x00\x00",
    };
    const filler = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(filler);

    @memset(filler, 'x');
    for (lengths, heads) |len, head| {
        const bytes = try encode(.{ .string = filler[0..len] }, plain);
        defer std.testing.allocator.free(bytes);

        try expectEqualSlices(u8, head, bytes[0..head.len]);
        try expectEqual(head.len + len, bytes.len);
        const raw = try encode(.{ .bytes = filler[0..len] }, plain);
        defer std.testing.allocator.free(raw);

        try expectEqual(@as(u8, 0x40 | (head[0] & 0x1f)), raw[0]);
        try expectEqual(head.len + len, raw.len);
    }
}

test "encoder: arrays, Appendix A shapes and the 23/24 head boundary" {
    try expect_hex(.{ .array = &.{} }, "80");
    const one_two_three = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    try expect_hex(.{ .array = &one_two_three }, "83010203");
    const pair_a = [_]Value{ .{ .int = 2 }, .{ .int = 3 } };
    const pair_b = [_]Value{ .{ .int = 4 }, .{ .int = 5 } };
    const nested = [_]Value{ .{ .int = 1 }, .{ .array = &pair_a }, .{ .array = &pair_b } };
    try expect_hex(.{ .array = &nested }, "8301820203820405");

    var many: [25]Value = undefined;
    for (&many, 1..) |*slot, number| slot.* = .{ .int = @intCast(number) };
    try expect_hex(
        .{ .array = &many },
        "98190102030405060708090a0b0c0d0e0f101112131415161718181819",
    );
    try expect_hex(.{ .array = many[0..23] }, "970102030405060708090a0b0c0d0e0f1011121314151617");
}

test "encoder: maps, Appendix A shapes, insertion order without the option" {
    var entries: [5]Map.Entry = undefined;
    try expect_hex(try map_of(&entries, &.{}, &.{}), "a0");

    const tail = [_]Value{ .{ .int = 2 }, .{ .int = 3 } };
    const a_b = try map_of(&entries, &.{ "a", "b" }, &.{ .{ .int = 1 }, .{ .array = &tail } });
    try expect_hex(a_b, "a26161016162820203");

    var inner_entries: [1]Map.Entry = undefined;
    const inner = try map_of(&inner_entries, &.{"b"}, &.{.{ .string = "c" }});
    const mixed = [_]Value{ .{ .string = "a" }, inner };
    try expect_hex(.{ .array = &mixed }, "826161a161626163");

    const letters = [_]Value{
        .{ .string = "A" }, .{ .string = "B" }, .{ .string = "C" },
        .{ .string = "D" }, .{ .string = "E" },
    };
    const five = try map_of(&entries, &.{ "a", "b", "c", "d", "e" }, &letters);
    try expect_hex(five, "a56161614161626142616361436164614461656145");
    // Insertion order is kept when `deterministic` is off.
    const reversed = try map_of(&entries, &.{ "bb", "a" }, &.{ .{ .int = 1 }, .{ .int = 2 } });
    try expect_hex(reversed, "a2626262016161" ++ "02");
}

test "encoder: deterministic sorts keys shorter first then bytewise, any insertion order" {
    const sorted_hex = "a4" ++ "616102" ++ "616303" ++ "62616104" ++ "62626201";
    const one = [_][]const u8{ "bb", "a", "c", "aa" };
    const two = [_][]const u8{ "aa", "c", "bb", "a" };
    const values_one = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 } };
    const values_two = [_]Value{ .{ .int = 4 }, .{ .int = 3 }, .{ .int = 1 }, .{ .int = 2 } };
    var entries: [4]Map.Entry = undefined;
    const first = try map_of(&entries, &one, &values_one);
    try expect_hex_with(first, sorted, sorted_hex);
    var entries_two: [4]Map.Entry = undefined;
    const second = try map_of(&entries_two, &two, &values_two);
    try expect_hex_with(second, sorted, sorted_hex);
    // Without the option the two insertion orders differ on the wire.
    const bytes_one = try encode(first, plain);
    defer std.testing.allocator.free(bytes_one);

    const bytes_two = try encode(second, plain);
    defer std.testing.allocator.free(bytes_two);

    try expect(!std.mem.eql(u8, bytes_one, bytes_two));
}

test "encoder: deterministic sorts nested maps and keys across head widths" {
    const long_key = "k" ** 24; // Head 78 18: sorts after every key of 23 bytes or fewer.
    var inner_entries: [2]Map.Entry = undefined;
    const inner = try map_of(&inner_entries, &.{ "z", "y" }, &.{ .null, .null });
    var entries: [3]Map.Entry = undefined;
    const outer = try map_of(
        &entries,
        &.{ long_key, "m", "b" },
        &.{ .{ .int = 1 }, inner, .{ .int = 2 } },
    );
    const expected = "a3" ++ "616202" ++ "616da2" ++ "6179f6" ++ "617af6" ++
        "7818" ++ ("6b" ** 24) ++ "01";
    try expect_hex_with(outer, sorted, expected);
}

test "encoder: timestamps are tag 1 with an integer, a float, or tag 0 with text" {
    try expect_hex(instant(1363896240, 0, null), "c11a514b67b0");
    try expect_hex(instant(-1, 0, null), "c120");
    try expect_hex(instant(1363896240, 500_000_000, null), "c1fb41d452d9ec200000");
    try expect_hex(instant(-2, 500_000_000, null), "c1f9be00");
    try expect_hex(instant(1363896240, 0, 0), "c074323031332d30332d32315432303a30343a30305a");
    const plus_one = "c07819" ++ "323031332d30332d32315432313a30343a30302b30313a3030";
    try expect_hex(instant(1363896240, 0, 60), plus_one);
    // A small exact fraction is an f16 inside the tag.
    try expect_hex(instant(2, 500_000_000, null), "c1f94100");
}

test "encoder: a fraction a float cannot hold, a local kind and a far year are refused" {
    var entries: [1]Map.Entry = undefined;
    const fraction = try map_of(&entries, &.{"at"}, &.{instant(1363896240, 123, null)});
    const fraction_message = "at: timestamp fraction is not exact as a CBOR float";
    try expect_fail(fraction, 128, error.Unrepresentable, fraction_message);

    const local: Timestamp = .{
        .kind = .local_date,
        .seconds = 0,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    const items = [_]Value{ .null, .{ .timestamp = local } };
    const local_message = "[1]: local timestamp cannot be written as CBOR";
    try expect_fail(.{ .array = &items }, 128, error.Unrepresentable, local_message);

    const year_message = "timestamp year is outside 0000-9999 for CBOR tag 0";
    try expect_fail(instant(253402300800, 0, 0), 128, error.Unrepresentable, year_message);
    // The same instant without an offset is tag 1 and needs no calendar.
    try expect_hex(instant(253402300800, 0, null), "c11b0000003afff44180");
}

test "encoder: a timestamp is a nesting level, as the decoder counts a tag" {
    const items = [_]Value{instant(0, 0, null)};
    try expect_fail(.{ .array = &items }, 1, error.TooDeep, "[0]: exceeds the depth limit");
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = fresh_diag();
    const options: encoder.StringifyOptions = .{ .depth_max = 2, .deterministic = false };
    try encoder.write(&sink.writer, .{ .array = &items }, options, &diag);
    const one_level: encoder.StringifyOptions = .{ .depth_max = 1, .deterministic = false };
    try encoder.write(&sink.writer, instant(0, 0, null), one_level, &diag);
}

test "encoder: a failure deep in a sorted map names the sorted key, not the insertion index" {
    var inner_entries: [2]Map.Entry = undefined;
    const bad = Value{ .string = "\xff" };
    const inner = try map_of(&inner_entries, &.{ "zz", "a" }, &.{ .null, bad });
    const list = [_]Value{ .null, inner };
    var entries: [2]Map.Entry = undefined;
    const outer = try map_of(&entries, &.{ "list", "b" }, &.{ .{ .array = &list }, .null });
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = encoder.write(&aw.writer, outer, sorted, &diag);
    try std.testing.expectError(error.InvalidUtf8, result);
    try expectEqualStrings("list[1].a: string is not valid UTF-8", diag.message());
    // "b" sorts before "list", so it was written first; the prefix ends inside the failing map.
    try expect(std.mem.startsWith(u8, aw.written(), "\xa2\x61b\xf6\x64list"));
}

test "encoder: invalid UTF-8 in a value or a key is InvalidUtf8 and writes nothing for it" {
    var entries: [1]Map.Entry = undefined;
    const bad_value = try map_of(&entries, &.{"k"}, &.{.{ .string = "\xff" }});
    try expect_fail(bad_value, 128, error.InvalidUtf8, "k: string is not valid UTF-8");
    const bad_key = try map_of(&entries, &.{"k\xc3"}, &.{.null});
    try expect_fail(bad_key, 128, error.InvalidUtf8, "[\"k\xc3\"]: string is not valid UTF-8");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = encoder.write(&aw.writer, .{ .string = "ok\xed\xa0\x80" }, plain, &diag);
    try std.testing.expectError(error.InvalidUtf8, result);
    try expectEqual(@as(usize, 0), aw.written().len);
}

test "encoder: a string past maxInt(u32) is InputTooLarge, a byte string is not refused" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    const backing: [1]u8 = .{'a'};
    const length_max: usize = std.math.maxInt(u32);
    const oversized = @as([*]const u8, &backing)[0 .. length_max + 1];
    try expect_fail(.{ .string = oversized }, 128, error.InputTooLarge, "string is too large");
    // CBOR carries 64-bit lengths, so a byte string of any length has a head. `Discarding`
    // never reads the payload, which is why the one-byte backing array is enough.
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = fresh_diag();
    try encoder.write(&sink.writer, .{ .bytes = oversized }, plain, &diag);
    try expectEqual(@as(usize, length_max + 1 + 9), sink.fullCount());
}

test "encoder: depth_max levels pass and one more is TooDeep, at 1 and at 128" {
    const gpa = std.testing.allocator;
    var nodes = try gpa.alloc(Value, 130);
    defer gpa.free(nodes);

    nodes[0] = .null;
    for (1..nodes.len) |index| nodes[index] = .{ .array = nodes[index - 1 .. index] };
    // nodes[k] holds k array levels around a null.
    const bytes = try encode(nodes[128], plain);
    defer gpa.free(bytes);

    try expectEqual(@as(usize, 129), bytes.len);
    try expect_fail(nodes[2], 1, error.TooDeep, "[0]: exceeds the depth limit");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var diag = fresh_diag();
    try std.testing.expectError(error.TooDeep, encoder.write(&aw.writer, nodes[129], plain, &diag));
    try expect(std.mem.endsWith(u8, diag.message(), ": exceeds the depth limit"));
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const one_level: encoder.StringifyOptions = .{ .depth_max = 1, .deterministic = false };
    try encoder.write(&sink.writer, nodes[1], one_level, &diag);
}

test "encoder: a full fixed writer fails at every capacity below the output length" {
    const items = [_]Value{ .{ .int = 300 }, .{ .string = "ab" }, .null, .{ .float = 2.5 } };
    var entries: [1]Map.Entry = undefined;
    const value = try map_of(&entries, &.{"key"}, &.{.{ .array = &items }});
    const expected = try encode(value, sorted);
    defer std.testing.allocator.free(expected);

    var buffer: [64]u8 = undefined;
    for (0..expected.len + 1) |capacity| {
        var fixed: std.Io.Writer = .fixed(buffer[0..capacity]);
        var diag = fresh_diag();
        const result = encoder.write(&fixed, value, sorted, &diag);
        if (capacity < expected.len) {
            try std.testing.expectError(error.WriteFailed, result);
            try expect(std.mem.endsWith(u8, diag.message(), "output writer failed"));
        } else {
            try result;
            try expectEqualSlices(u8, expected, fixed.buffered());
        }
    }
}

test "encoder: write then parse_value round-trips, and a second encode is byte-identical" {
    const inner = [_]Value{
        .{ .int = -70000 },
        .{ .uint = std.math.maxInt(u64) },
        .{ .float = 0.1 },
    };
    var entries: [6]Map.Entry = undefined;
    const keys = [_][]const u8{ "list", "text", "blob", "when", "flag", "at" };
    const values = [_]Value{
        .{ .array = &inner },
        .{ .string = "h\xc3\xa9llo" },
        .{ .bytes = "\x00\x01\xff" },
        instant(1_700_000_000, 500_000_000, null),
        .{ .bool = true },
        instant(1_700_000_000, 7_000, 90),
    };
    const original = try map_of(&entries, &keys, &values);
    for ([_]encoder.StringifyOptions{ plain, sorted }) |options| {
        const bytes = try encode(original, options);
        defer std.testing.allocator.free(bytes);

        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();

        var diag = fresh_diag();
        const read_back = try decoder.parse_value(&tree, bytes, .{
            .depth_max = 128,
            .bytes_max = 1 << 20,
            .duplicate_key = .reject,
        }, &diag);
        // `eql` compares maps in insertion order, which the sorted form deliberately changes.
        if (!options.deterministic) try expect(try core.value.eql(original, read_back));
        const again = try encode(read_back, options);
        defer std.testing.allocator.free(again);

        try expectEqualSlices(u8, bytes, again);
    }
}

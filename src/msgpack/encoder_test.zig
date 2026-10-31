//! Tests for `msgpack/encoder.zig` (plan 007 item 4): golden bytes at every width boundary,
//! float and NaN policy, timestamps, every refusal with its key path, every declared error, a
//! full-writer sweep and the round trip through the decoder.

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

const options: encoder.StringifyOptions = .{ .depth_max = 128 };
const sentinel_line: u32 = 777;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Encodes `value` with `depth_max` and returns the bytes; the caller frees them.
fn encode(value: Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();

    var diag = fresh_diag();
    try encoder.write(&aw.writer, value, options, &diag);
    try expectEqual(sentinel_line, diag.line);
    return aw.toOwnedSlice();
}

fn expect_bytes(value: Value, expected: []const u8) !void {
    const bytes = try encode(value);
    defer std.testing.allocator.free(bytes);

    try expectEqualSlices(u8, expected, bytes);
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
    const result = encoder.write(&aw.writer, value, .{ .depth_max = depth_max }, &diag);
    try std.testing.expectError(err, result);
    try expectEqualStrings(message, diag.message());
    try expectEqual(core.diagnostics.position_none, diag.line);
}

/// Expects `TooDeep`; the message ends in the reason after a key path as long as the nesting.
fn expect_too_deep(value: Value, depth_max: u16) !void {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = encoder.write(&aw.writer, value, .{ .depth_max = depth_max }, &diag);
    try std.testing.expectError(error.TooDeep, result);
    try expect(std.mem.endsWith(u8, diag.message(), ": exceeds the depth limit"));
}

fn map_of(entries: []Map.Entry, keys: []const []const u8, values: []const Value) !Value {
    var map = Map.init(entries);
    for (keys, values) |key, value| try map.put(key, value);
    return .{ .map = map };
}

test "encoder: scalars" {
    try expect_bytes(.null, &.{0xc0});
    try expect_bytes(.{ .bool = false }, &.{0xc2});
    try expect_bytes(.{ .bool = true }, &.{0xc3});
}

test "encoder: signed integers take the shortest head at every boundary" {
    const Case = struct { number: i64, bytes: []const u8 };
    const cases = [_]Case{
        .{ .number = 0, .bytes = "\x00" },
        .{ .number = 127, .bytes = "\x7f" },
        .{ .number = 128, .bytes = "\xcc\x80" },
        .{ .number = 255, .bytes = "\xcc\xff" },
        .{ .number = 256, .bytes = "\xcd\x01\x00" },
        .{ .number = 65535, .bytes = "\xcd\xff\xff" },
        .{ .number = 65536, .bytes = "\xce\x00\x01\x00\x00" },
        .{ .number = 4294967295, .bytes = "\xce\xff\xff\xff\xff" },
        .{ .number = 4294967296, .bytes = "\xcf\x00\x00\x00\x01\x00\x00\x00\x00" },
        .{ .number = std.math.maxInt(i64), .bytes = "\xcf\x7f\xff\xff\xff\xff\xff\xff\xff" },
        .{ .number = -1, .bytes = "\xff" },
        .{ .number = -32, .bytes = "\xe0" },
        .{ .number = -33, .bytes = "\xd0\xdf" },
        .{ .number = -128, .bytes = "\xd0\x80" },
        .{ .number = -129, .bytes = "\xd1\xff\x7f" },
        .{ .number = -32768, .bytes = "\xd1\x80\x00" },
        .{ .number = -32769, .bytes = "\xd2\xff\xff\x7f\xff" },
        .{ .number = -2147483648, .bytes = "\xd2\x80\x00\x00\x00" },
        .{ .number = -2147483649, .bytes = "\xd3\xff\xff\xff\xff\x7f\xff\xff\xff" },
        .{ .number = std.math.minInt(i64), .bytes = "\xd3\x80\x00\x00\x00\x00\x00\x00\x00" },
    };
    for (cases) |case| try expect_bytes(.{ .int = case.number }, case.bytes);
}

test "encoder: a uint is written unsigned and shortest, small ones included" {
    try expect_bytes(.{ .uint = 5 }, "\x05");
    try expect_bytes(.{ .uint = 200 }, "\xcc\xc8");
    const above = @as(u64, std.math.maxInt(i64)) + 1;
    try expect_bytes(.{ .uint = above }, "\xcf\x80\x00\x00\x00\x00\x00\x00\x00");
    try expect_bytes(.{ .uint = std.math.maxInt(u64) }, "\xcf" ++ "\xff" ** 8);
}

test "encoder: floats keep the value, narrowing only when exact" {
    try expect_bytes(.{ .float = 1.5 }, "\xca\x3f\xc0\x00\x00");
    try expect_bytes(.{ .float = 1.1 }, "\xcb\x3f\xf1\x99\x99\x99\x99\x99\x9a");
    try expect_bytes(.{ .float = -0.0 }, "\xca\x80\x00\x00\x00");
    try expect_bytes(.{ .float = std.math.inf(f64) }, "\xca\x7f\x80\x00\x00");
    try expect_bytes(.{ .float = -std.math.inf(f64) }, "\xca\xff\x80\x00\x00");
    // Beyond f32 range and below f32's smallest subnormal: only f64 keeps them.
    for ([_]f64{ 1e300, 1e-50 }) |number| {
        var expected: [9]u8 = undefined;
        expected[0] = 0xcb;
        std.mem.writeInt(u64, expected[1..9], @bitCast(number), .big);
        try expect_bytes(.{ .float = number }, &expected);
    }
    // f32 max widened is exact; one ulp above it in f64 is not.
    try expect_bytes(.{ .float = std.math.floatMax(f32) }, "\xca\x7f\x7f\xff\xff");
    const above_max = std.math.nextAfter(f64, std.math.floatMax(f32), std.math.inf(f64));
    try expect_bytes(.{ .float = above_max }, "\xcb\x47\xef\xff\xff\xe0\x00\x00\x01");
}

test "encoder: every NaN is the one quiet positive NaN" {
    const payloads = [_]u64{
        0x7ff8000000000000, // quiet
        0xfff8000000000000, // negative
        0x7ff0000000000001, // signalling
        0x7ff8000000000abc, // payload
    };
    for (payloads) |bits| {
        try expect_bytes(.{ .float = @bitCast(bits) }, "\xca\x7f\xc0\x00\x00");
    }
}

test "encoder: str heads at 31/32, 255/256 and 65535/65536 bytes" {
    const lengths = [_]u32{ 0, 1, 31, 32, 255, 256, 65535, 65536 };
    const heads = [_][]const u8{
        "\xa0",     "\xa1",         "\xbf",         "\xd9\x20",
        "\xd9\xff", "\xda\x01\x00", "\xda\xff\xff", "\xdb\x00\x01\x00\x00",
    };
    const text = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(text);

    @memset(text, 'x');
    for (lengths, heads) |len, head| {
        const bytes = try encode(.{ .string = text[0..len] });
        defer std.testing.allocator.free(bytes);

        try expectEqualSlices(u8, head, bytes[0..head.len]);
        try expectEqual(@as(usize, head.len) + len, bytes.len);
    }
}

test "encoder: bin heads at 255/256 and 65535/65536 bytes, empty included" {
    const lengths = [_]u32{ 0, 255, 256, 65535, 65536 };
    const heads = [_][]const u8{
        "\xc4\x00",     "\xc4\xff",             "\xc5\x01\x00",
        "\xc5\xff\xff", "\xc6\x00\x01\x00\x00",
    };
    const data = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(data);

    @memset(data, 0xfe);
    for (lengths, heads) |len, head| {
        const bytes = try encode(.{ .bytes = data[0..len] });
        defer std.testing.allocator.free(bytes);

        try expectEqualSlices(u8, head, bytes[0..head.len]);
        try expectEqual(@as(usize, head.len) + len, bytes.len);
    }
}

test "encoder: array and map heads at 15/16 and 65535/65536 members" {
    const counts = [_]u32{ 0, 15, 16, 65535, 65536 };
    const array_heads = [_][]const u8{
        "\x90", "\x9f", "\xdc\x00\x10", "\xdc\xff\xff", "\xdd\x00\x01\x00\x00",
    };
    const items = try std.testing.allocator.alloc(Value, 65536);
    defer std.testing.allocator.free(items);

    @memset(items, .null);
    for (counts, array_heads) |count, head| {
        const bytes = try encode(.{ .array = items[0..count] });
        defer std.testing.allocator.free(bytes);

        try expectEqualSlices(u8, head, bytes[0..head.len]);
        try expectEqual(@as(usize, head.len) + count, bytes.len);
    }
}

test "encoder: map heads at 15/16 entries, keys in insertion order" {
    var keys: [16][2]u8 = undefined;
    var key_slices: [16][]const u8 = undefined;
    var entries: [16]Map.Entry = undefined;
    for (&keys, 0..) |*key, index| {
        key.* = .{ 'k', 'a' + @as(u8, @intCast(index)) };
        key_slices[index] = key;
    }
    const values: [16]Value = @splat(.{ .int = 1 });
    const fifteen = try map_of(&entries, key_slices[0..15], values[0..15]);
    const bytes15 = try encode(fifteen);
    defer std.testing.allocator.free(bytes15);

    try expectEqual(@as(u8, 0x8f), bytes15[0]);
    try expectEqualSlices(u8, "\xa2ka\x01\xa2kb\x01", bytes15[1..9]);

    var entries16: [16]Map.Entry = undefined;
    const sixteen = try map_of(&entries16, &key_slices, &values);
    const bytes16 = try encode(sixteen);
    defer std.testing.allocator.free(bytes16);

    try expectEqualSlices(u8, "\xde\x00\x10", bytes16[0..3]);
    try expectEqual(@as(usize, 3 + 16 * 4), bytes16.len);
}

test "encoder: timestamps take ext 4, 8 or 12 at the documented boundaries" {
    const Case = struct { seconds: i64, nanoseconds: u32, bytes: []const u8 };
    const ext8 = "\xd7\xff";
    const ext12 = "\xc7\x0c\xff";
    const cases = [_]Case{
        .{ .seconds = 0, .nanoseconds = 0, .bytes = "\xd6\xff\x00\x00\x00\x00" },
        .{ .seconds = 4294967295, .nanoseconds = 0, .bytes = "\xd6\xff\xff\xff\xff\xff" },
        .{
            .seconds = 4294967296,
            .nanoseconds = 0,
            .bytes = ext8 ++ "\x00\x00\x00\x01\x00\x00\x00\x00",
        },
        .{ .seconds = 1, .nanoseconds = 1, .bytes = ext8 ++ "\x00\x00\x00\x04\x00\x00\x00\x01" },
        .{
            .seconds = (1 << 34) - 1,
            .nanoseconds = 999_999_999,
            .bytes = ext8 ++ "\xee\x6b\x27\xff\xff\xff\xff\xff",
        },
        .{
            .seconds = 1 << 34,
            .nanoseconds = 0,
            .bytes = ext12 ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x04\x00\x00\x00\x00",
        },
        .{
            .seconds = -1,
            .nanoseconds = 5,
            .bytes = ext12 ++ "\x00\x00\x00\x05" ++ "\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    };
    for (cases) |case| {
        const stamp: Timestamp = .{
            .kind = .instant,
            .seconds = case.seconds,
            .nanoseconds = case.nanoseconds,
            .offset_minutes = null,
        };
        try expect_bytes(.{ .timestamp = stamp }, case.bytes);
    }
}

test "encoder: an offset or a local kind is Unrepresentable, with the key path" {
    const offset: Timestamp = .{
        .kind = .instant,
        .seconds = 0,
        .nanoseconds = 0,
        .offset_minutes = 60,
    };
    var entries: [1]Map.Entry = undefined;
    const holder = try map_of(&entries, &.{"at"}, &.{.{ .timestamp = offset }});
    const offset_message = "at: timestamp with an offset cannot be written as MessagePack";
    try expect_fail(holder, 128, error.Unrepresentable, offset_message);

    const local: Timestamp = .{
        .kind = .local_date,
        .seconds = 0,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    const items = [_]Value{ .null, .{ .timestamp = local } };
    const local_message = "[1]: local timestamp cannot be written as MessagePack";
    try expect_fail(.{ .array = &items }, 128, error.Unrepresentable, local_message);
}

test "encoder: lengths past maxInt(u32) are Unrepresentable" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    const backing: [1]u8 = .{'a'};
    const length_max: usize = std.math.maxInt(u32);
    const oversized = @as([*]const u8, &backing)[0 .. length_max + 1];
    const message = "length exceeds the MessagePack limit of 2^32-1";
    try expect_fail(.{ .string = oversized }, 128, error.Unrepresentable, message);
    try expect_fail(.{ .bytes = oversized }, 128, error.Unrepresentable, message);
    // Exactly maxInt(u32) is the largest length a head carries: it is not refused for length.
    const largest = @as([*]const u8, &backing)[0..length_max];
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = fresh_diag();
    try encoder.write(&sink.writer, .{ .bytes = largest }, options, &diag);
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
    const result = encoder.write(&aw.writer, .{ .string = "ok\xed\xa0\x80" }, options, &diag);
    try std.testing.expectError(error.InvalidUtf8, result);
    try expectEqual(@as(usize, 0), aw.written().len);
}

test "encoder: depth_max levels pass and one more is TooDeep, at 1 and at 128" {
    const arena = std.testing.allocator;
    var nodes = try arena.alloc(Value, 130);
    defer arena.free(nodes);

    nodes[0] = .null;
    for (1..nodes.len) |index| nodes[index] = .{ .array = nodes[index - 1 .. index] };
    // nodes[k] holds k array levels around a null.
    const levels_128 = nodes[128];
    const levels_129 = nodes[129];
    const bytes = try encode(levels_128);
    defer arena.free(bytes);

    try expectEqual(@as(usize, 129), bytes.len);
    try expect_too_deep(levels_129, 128);
    try expect_fail(nodes[2], 1, error.TooDeep, "[0]: exceeds the depth limit");
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = fresh_diag();
    try encoder.write(&sink.writer, nodes[1], .{ .depth_max = 1 }, &diag);
}

test "encoder: a full fixed writer fails at every capacity below the output length" {
    const items = [_]Value{ .{ .int = 300 }, .{ .string = "ab" }, .null, .{ .float = 2.5 } };
    var entries: [1]Map.Entry = undefined;
    const value = try map_of(&entries, &.{"key"}, &.{.{ .array = &items }});
    const expected = try encode(value);
    defer std.testing.allocator.free(expected);

    var buffer: [64]u8 = undefined;
    for (0..expected.len + 1) |capacity| {
        var fixed: std.Io.Writer = .fixed(buffer[0..capacity]);
        var diag = fresh_diag();
        const result = encoder.write(&fixed, value, options, &diag);
        if (capacity < expected.len) {
            try std.testing.expectError(error.WriteFailed, result);
            try expect(std.mem.endsWith(u8, diag.message(), "output writer failed"));
        } else {
            try result;
            try expectEqualSlices(u8, expected, fixed.buffered());
        }
    }
}

test "encoder: write then parse_value gives back an equal tree" {
    const stamp: Timestamp = .{
        .kind = .instant,
        .seconds = 1_700_000_000,
        .nanoseconds = 123,
        .offset_minutes = null,
    };
    const inner = [_]Value{
        .{ .int = -70000 },
        .{ .uint = std.math.maxInt(u64) },
        .{ .float = 0.1 },
    };
    var entries: [5]Map.Entry = undefined;
    const keys = [_][]const u8{ "list", "text", "blob", "when", "flag" };
    const values = [_]Value{
        .{ .array = &inner },
        .{ .string = "h\xc3\xa9llo" },
        .{ .bytes = "\x00\x01\xff" },
        .{ .timestamp = stamp },
        .{ .bool = true },
    };
    const original = try map_of(&entries, &keys, &values);
    const bytes = try encode(original);
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
    try expect(try core.value.eql(original, read_back));
    const again = try encode(read_back);
    defer std.testing.allocator.free(again);

    try expectEqualSlices(u8, bytes, again);
}

//! Tests for `msgpack/decoder.zig` Reader (plan 007 item 2).

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Reader = decoder.Reader;
const Item = decoder.Item;
const Token = decoder.Token;
const ScanError = decoder.ScanError;
const Diagnostics = core.Diagnostics;

/// Reads the first token of `input`; `diag` stays untouched on success.
fn first(input: []const u8) !Token {
    var reader: Reader = undefined;
    try reader.init(input);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try reader.next(&diag);
    try expectEqualStrings("untouched", diag.message());
    return token;
}

fn expect_int(expected: i64, input: []const u8) !void {
    const token = try first(input);
    try expectEqual(expected, token.item.int);
}

/// Reads the first token of `input` and checks the error, its `col` and message prefix.
fn expect_scan_error(err: ScanError, offset: u32, input: []const u8) !void {
    var reader: Reader = undefined;
    try reader.init(input);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    // Skip `offset` single-byte items so the failing item starts at `offset`.
    for (0..offset) |_| _ = try reader.next(&diag);
    try expectError(err, reader.next(&diag));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(offset + 1, diag.col);
    var buffer: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buffer, "byte {d}: ", .{offset});
    try expect(std.mem.startsWith(u8, diag.message(), prefix));
}

const Shape = struct { tag: std.meta.Tag(Item), consumed: u32 };

/// The MessagePack format table, written out by byte range, for a reader fed 32 zero bytes
/// after the first byte (so every length is 0 or a valid count).
fn expected_shape(byte: u8) Shape {
    return switch (byte) {
        0x00...0x7f => .{ .tag = .int, .consumed = 1 },
        0x80...0x8f => .{ .tag = .map, .consumed = 1 },
        0x90...0x9f => .{ .tag = .array, .consumed = 1 },
        0xa0...0xbf => .{ .tag = .str, .consumed = 1 + (byte & 0x1f) },
        0xc0 => .{ .tag = .nil, .consumed = 1 },
        0xc2, 0xc3 => .{ .tag = .bool, .consumed = 1 },
        0xc4 => .{ .tag = .bin, .consumed = 2 },
        0xc5 => .{ .tag = .bin, .consumed = 3 },
        0xc6 => .{ .tag = .bin, .consumed = 5 },
        0xc7 => .{ .tag = .ext, .consumed = 3 },
        0xc8 => .{ .tag = .ext, .consumed = 4 },
        0xc9 => .{ .tag = .ext, .consumed = 6 },
        0xca => .{ .tag = .float, .consumed = 5 },
        0xcb => .{ .tag = .float, .consumed = 9 },
        0xcc, 0xd0 => .{ .tag = .int, .consumed = 2 },
        0xcd, 0xd1 => .{ .tag = .int, .consumed = 3 },
        0xce, 0xd2 => .{ .tag = .int, .consumed = 5 },
        0xcf, 0xd3 => .{ .tag = .int, .consumed = 9 },
        0xd4 => .{ .tag = .ext, .consumed = 3 },
        0xd5 => .{ .tag = .ext, .consumed = 4 },
        0xd6 => .{ .tag = .ext, .consumed = 6 },
        0xd7 => .{ .tag = .ext, .consumed = 10 },
        0xd8 => .{ .tag = .ext, .consumed = 18 },
        0xd9 => .{ .tag = .str, .consumed = 2 },
        0xda => .{ .tag = .str, .consumed = 3 },
        0xdb => .{ .tag = .str, .consumed = 5 },
        0xdc => .{ .tag = .array, .consumed = 3 },
        0xdd => .{ .tag = .array, .consumed = 5 },
        0xde => .{ .tag = .map, .consumed = 3 },
        0xdf => .{ .tag = .map, .consumed = 5 },
        0xe0...0xff => .{ .tag = .int, .consumed = 1 },
        0xc1 => unreachable,
    };
}

test "reader: every first byte 0x00-0xff reads the format-table shape; 0xc1 is reserved" {
    var input = [_]u8{0} ** 33;
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        input[0] = byte;
        if (byte == 0xc1) {
            try expect_scan_error(error.ReservedByte, 0, &input);
            continue;
        }
        var reader: Reader = undefined;
        try reader.init(&input);
        var diag = Diagnostics.init(0, 0, "untouched", null);
        const token = try reader.next(&diag);
        const shape = expected_shape(byte);
        try expectEqual(shape.tag, std.meta.activeTag(token.item));
        try expectEqual(@as(u32, 0), token.offset);
        try expectEqual(shape.consumed, reader.offset);
    }
}

test "reader: integers keep their value and are normalized to int below 2^63" {
    try expect_int(0, &.{0x00});
    try expect_int(127, &.{0x7f});
    try expect_int(-1, &.{0xff});
    try expect_int(-32, &.{0xe0});
    try expect_int(255, &.{ 0xcc, 0xff });
    try expect_int(5, &.{ 0xcc, 0x05 });
    try expect_int(65535, &.{ 0xcd, 0xff, 0xff });
    try expect_int(4294967295, &.{ 0xce, 0xff, 0xff, 0xff, 0xff });
    const top = [_]u8{ 0xcf, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try expect_int(std.math.maxInt(i64), &top);
    try expect_int(-128, &.{ 0xd0, 0x80 });
    try expect_int(-32768, &.{ 0xd1, 0x80, 0x00 });
    try expect_int(-2147483648, &.{ 0xd2, 0x80, 0x00, 0x00, 0x00 });
    try expect_int(std.math.minInt(i64), &.{ 0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0 });
    try expect_int(7, &.{ 0xd3, 0, 0, 0, 0, 0, 0, 0, 7 });
    try expect_int(127, &.{ 0xd0, 0x7f });
    try expect_int(-2, &.{ 0xd0, 0xfe });
    try expect_int(32767, &.{ 0xd1, 0x7f, 0xff });
    try expect_int(-1, &.{ 0xd1, 0xff, 0xff });
    try expect_int(2147483647, &.{ 0xd2, 0x7f, 0xff, 0xff, 0xff });
    try expect_int(-1, &.{ 0xd2, 0xff, 0xff, 0xff, 0xff });
    try expect_int(-1, &.{ 0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try expect_int(256, &.{ 0xcd, 0x01, 0x00 });
    try expect_int(0x01020304, &.{ 0xce, 0x01, 0x02, 0x03, 0x04 });
}

test "reader: uint appears only above maxInt(i64)" {
    const above = try first(&.{ 0xcf, 0x80, 0, 0, 0, 0, 0, 0, 0 });
    try expectEqual(@as(u64, 1) << 63, above.item.uint);
    const top = try first(&.{ 0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try expectEqual(std.math.maxInt(u64), top.item.uint);
}

test "reader: nil, booleans and floats" {
    try expect(std.meta.activeTag((try first(&.{0xc0})).item) == .nil);
    try expectEqual(false, (try first(&.{0xc2})).item.bool);
    try expectEqual(true, (try first(&.{0xc3})).item.bool);
    try expectEqual(@as(f64, 1.5), (try first(&.{ 0xca, 0x3f, 0xc0, 0x00, 0x00 })).item.float);
    const pi = try first(&.{ 0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18 });
    try expectEqual(std.math.pi, pi.item.float);
    const negative_zero = try first(&.{ 0xca, 0x80, 0, 0, 0 });
    try expectEqual(@as(u64, 1) << 63, @as(u64, @bitCast(negative_zero.item.float)));
}

test "reader: f32 NaN payload is widened bit-exactly, f64 NaN keeps its bits" {
    // f32 0x7fc00001: quiet NaN with payload 1 -> f64 mantissa shifted left by 29.
    const widened = try first(&.{ 0xca, 0x7f, 0xc0, 0x00, 0x01 });
    try expectEqual(@as(u64, 0x7ff8_0000_2000_0000), @as(u64, @bitCast(widened.item.float)));
    const kept = try first(&.{ 0xcb, 0xff, 0xf8, 0, 0, 0, 0, 0, 0x2a });
    try expectEqual(@as(u64, 0xfff8_0000_0000_002a), @as(u64, @bitCast(kept.item.float)));
    const negative = try first(&.{ 0xca, 0xff, 0xc0, 0x00, 0x01 });
    try expectEqual(@as(u64, 0xfff8_0000_2000_0000), @as(u64, @bitCast(negative.item.float)));
    const signaling = try first(&.{ 0xca, 0x7f, 0x80, 0x00, 0x01 });
    try expectEqual(@as(u64, 0x7ff0_0000_2000_0000), @as(u64, @bitCast(signaling.item.float)));
    const infinity = try first(&.{ 0xca, 0xff, 0x80, 0, 0 });
    try expectEqual(-std.math.inf(f64), infinity.item.float);
}

test "reader: str, bin and ext borrow the input" {
    const input = [_]u8{ 0xa3, 'a', 'b', 'c' };
    const str = try first(&input);
    try expectEqualStrings("abc", str.item.str);
    try expect(str.item.str.ptr == input[1..].ptr);

    const bin = try first(&.{ 0xc4, 0x02, 0xff, 0x00 });
    try expectEqualStrings("\xff\x00", bin.item.bin);

    const ext = try first(&.{ 0xc7, 0x02, 0xfe, 0xaa, 0xbb });
    try expectEqual(@as(i8, -2), ext.item.ext.type);
    try expectEqualStrings("\xaa\xbb", ext.item.ext.data);

    const fixext = try first(&.{ 0xd4, 0x07, 0x09 });
    try expectEqual(@as(i8, 7), fixext.item.ext.type);
    try expectEqualStrings("\x09", fixext.item.ext.data);

    const empty = try first(&.{0xa0});
    try expectEqual(@as(usize, 0), empty.item.str.len);
}

test "reader: every length form returns its payload" {
    const str16 = try first(&.{ 0xda, 0x00, 0x02, 'h', 'i' });
    try expectEqualStrings("hi", str16.item.str);
    const str32 = try first(&.{ 0xdb, 0x00, 0x00, 0x00, 0x02, 'h', 'i' });
    try expectEqualStrings("hi", str32.item.str);
    const bin32 = try first(&.{ 0xc6, 0x00, 0x00, 0x00, 0x02, 0xc1, 0xff });
    try expectEqualStrings("\xc1\xff", bin32.item.bin);
    const ext16 = try first(&.{ 0xc8, 0x00, 0x01, 0x05, 0xaa });
    try expectEqual(@as(i8, 5), ext16.item.ext.type);
    try expectEqualStrings("\xaa", ext16.item.ext.data);
    const ext32 = try first(&.{ 0xc9, 0x00, 0x00, 0x00, 0x01, 0x06, 0xbb });
    try expectEqualStrings("\xbb", ext32.item.ext.data);
    const fixext2 = try first(&.{ 0xd5, 0x01, 0xa1, 0xa2 });
    try expectEqualStrings("\xa1\xa2", fixext2.item.ext.data);
    const fixext4 = try first(&.{ 0xd6, 0x01, 1, 2, 3, 4 });
    try expectEqualStrings("\x01\x02\x03\x04", fixext4.item.ext.data);
    const fixext8 = try first(&.{ 0xd7, 0x01, 1, 2, 3, 4, 5, 6, 7, 8 });
    try expectEqual(@as(usize, 8), fixext8.item.ext.data.len);
    const sixteen = [_]u8{ 0xd8, 0x01 } ++ [_]u8{0x7a} ** 16;
    const fixext16 = try first(&sixteen);
    try expectEqualStrings("zzzzzzzzzzzzzzzz", fixext16.item.ext.data);
}

test "reader: array and map headers give counts and leave the elements" {
    const array = try first(&.{ 0x92, 0x01, 0x02 });
    try expectEqual(@as(u32, 2), array.item.array);
    const map = try first(&.{ 0x81, 0xa1, 'k', 0x01 });
    try expectEqual(@as(u32, 1), map.item.map);
    const wide = try first(&.{ 0xdc, 0x00, 0x02, 0xc0, 0xc0 });
    try expectEqual(@as(u32, 2), wide.item.array);

    var reader: Reader = undefined;
    try reader.init(&.{ 0x92, 0x01, 0x02 });
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try expectEqual(@as(u32, 2), (try reader.next(&diag)).item.array);
    const second = try reader.next(&diag);
    try expectEqual(@as(u32, 1), second.offset);
    try expectEqual(@as(i64, 1), second.item.int);
    try expectEqual(@as(i64, 2), (try reader.next(&diag)).item.int);
}

test "reader: end is returned once at input.len, empty input included" {
    var reader: Reader = undefined;
    try reader.init(&.{});
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const empty = try reader.next(&diag);
    try expect(std.meta.activeTag(empty.item) == .end);
    try expectEqual(@as(u32, 0), empty.offset);

    try reader.init(&.{ 0x01, 0xc0 });
    _ = try reader.next(&diag);
    _ = try reader.next(&diag);
    const end = try reader.next(&diag);
    try expect(std.meta.activeTag(end.item) == .end);
    try expectEqual(@as(u32, 2), end.offset);
    try expectEqualStrings("untouched", diag.message());
}

test "reader: a prefix of any single item is UnexpectedEnd at the item's first byte" {
    const samples = [_][]const u8{
        &.{ 0xcc, 0x05 },
        &.{ 0xcd, 0x01, 0x00 },
        &.{ 0xcf, 1, 2, 3, 4, 5, 6, 7, 8 },
        &.{ 0xca, 0x3f, 0xc0, 0x00, 0x00 },
        &.{ 0xcb, 1, 2, 3, 4, 5, 6, 7, 8 },
        &.{ 0xa3, 'a', 'b', 'c' },
        &.{ 0xd9, 0x03, 'a', 'b', 'c' },
        &.{ 0xc5, 0x00, 0x02, 0xff, 0xfe },
        &.{ 0xc7, 0x02, 0x05, 0xaa, 0xbb },
        &.{ 0xd7, 0xff, 1, 2, 3, 4, 5, 6, 7, 8 },
        &.{ 0xdd, 0x00, 0x00, 0x00, 0x02, 0xc0, 0xc0 },
        &.{ 0xde, 0x00, 0x01, 0xa0, 0xc0 },
    };
    for (samples) |sample| {
        _ = try first(sample);
        for (1..sample.len) |length| {
            try expect_scan_error(error.UnexpectedEnd, 0, sample[0..length]);
        }
    }
}

test "reader: an error after earlier items is reported at its own offset" {
    try expect_scan_error(error.ReservedByte, 2, &.{ 0xc0, 0xc0, 0xc1 });
    try expect_scan_error(error.UnexpectedEnd, 1, &.{ 0xc0, 0xcd, 0x01 });
    try expect_scan_error(error.InvalidUtf8, 1, &.{ 0xc0, 0xa1, 0xff });
}

test "reader: declared lengths are checked against the bytes left, boundary and one past" {
    // str 8 of 3 with exactly 3 bytes passes, with 2 fails.
    _ = try first(&.{ 0xd9, 0x03, 'a', 'b', 'c' });
    try expect_scan_error(error.UnexpectedEnd, 0, &.{ 0xd9, 0x03, 'a', 'b' });
    // array 16 of 2 with exactly 2 bytes left passes, with 1 fails.
    _ = try first(&.{ 0xdc, 0x00, 0x02, 0xc0, 0xc0 });
    try expect_scan_error(error.UnexpectedEnd, 0, &.{ 0xdc, 0x00, 0x02, 0xc0 });
    // map 16 of 1 needs 2 bytes: 2 pass, 1 fails.
    _ = try first(&.{ 0xde, 0x00, 0x01, 0xa0, 0xc0 });
    try expect_scan_error(error.UnexpectedEnd, 0, &.{ 0xde, 0x00, 0x01, 0xa0 });
    // fixarray 1 with no byte left, fixmap 1 with one byte left.
    try expect_scan_error(error.UnexpectedEnd, 0, &.{0x91});
    try expect_scan_error(error.UnexpectedEnd, 0, &.{ 0x81, 0xa0 });
    // ext 8 of 2 with 1 byte of data.
    try expect_scan_error(error.UnexpectedEnd, 0, &.{ 0xc7, 0x02, 0x01, 0xaa });
}

test "reader: 0xdd ffffffff with 5 bytes left is refused at its head" {
    // The reader owns no allocator, so "no allocation" holds by construction.
    const bomb = [_]u8{ 0xdd, 0xff, 0xff, 0xff, 0xff };
    try expect_scan_error(error.UnexpectedEnd, 0, &bomb);
    const map_bomb = [_]u8{ 0xdf, 0xff, 0xff, 0xff, 0xff };
    try expect_scan_error(error.UnexpectedEnd, 0, &map_bomb);
    // 2 * 0x80000000 overflows a u32: the check must run in u64.
    const half = [_]u8{ 0xdf, 0x80, 0x00, 0x00, 0x00, 0xc0, 0xc0, 0xc0, 0xc0 };
    try expect_scan_error(error.UnexpectedEnd, 0, &half);
    const str_bomb = [_]u8{ 0xdb, 0xff, 0xff, 0xff, 0xff, 'a' };
    try expect_scan_error(error.UnexpectedEnd, 0, &str_bomb);
    const bin_bomb = [_]u8{ 0xc6, 0xff, 0xff, 0xff, 0xff, 0xaa };
    try expect_scan_error(error.UnexpectedEnd, 0, &bin_bomb);
    const str16_bomb = [_]u8{ 0xda, 0xff, 0xff, 'a' };
    try expect_scan_error(error.UnexpectedEnd, 0, &str16_bomb);
    const ext16_bomb = [_]u8{ 0xc8, 0xff, 0xff, 0x01, 'a' };
    try expect_scan_error(error.UnexpectedEnd, 0, &ext16_bomb);
    const ext_bomb = [_]u8{ 0xc9, 0xff, 0xff, 0xff, 0xff, 0x01, 'a' };
    try expect_scan_error(error.UnexpectedEnd, 0, &ext_bomb);
}

test "reader: str must be strict UTF-8, bin is not checked" {
    try expect_scan_error(error.InvalidUtf8, 0, &.{ 0xa1, 0xff });
    try expect_scan_error(error.InvalidUtf8, 0, &.{ 0xa2, 0xc0, 0x80 });
    try expect_scan_error(error.InvalidUtf8, 0, &.{ 0xa3, 0xed, 0xa0, 0x80 });
    try expect_scan_error(error.InvalidUtf8, 0, &.{ 0xd9, 0x02, 0xe2, 0x82 });
    _ = try first(&.{ 0xa3, 0xe2, 0x82, 0xac });
    _ = try first(&.{ 0xc4, 0x03, 0xed, 0xa0, 0x80 });
    try expectEqualStrings("\xc1", (try first(&.{ 0xc4, 0x01, 0xc1 })).item.bin);
}

test "reader: each error variant has its own message" {
    const end_message = "byte 0: unexpected end of input";
    const utf8_message = "byte 0: invalid UTF-8 in str";
    const Case = struct { err: ScanError, input: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .err = error.UnexpectedEnd, .input = &.{0xcd}, .message = end_message },
        .{ .err = error.ReservedByte, .input = &.{0xc1}, .message = "byte 0: reserved byte 0xc1" },
        .{ .err = error.InvalidUtf8, .input = &.{ 0xa1, 0xff }, .message = utf8_message },
    };
    for (cases) |case| {
        var reader: Reader = undefined;
        try reader.init(case.input);
        var diag = Diagnostics.init(0, 0, "untouched", null);
        try expectError(case.err, reader.next(&diag));
        try expectEqualStrings(case.message, diag.message());
    }
}

test "reader: after .end the reader is finished; after an error it is failed" {
    var reader: Reader = undefined;
    try reader.init(&.{0xc1});
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try expectError(error.ReservedByte, reader.next(&diag));
    try expect(reader.state == .failed);

    try reader.init(&.{});
    _ = try reader.next(&diag);
    try expect(reader.state == .finished);
}

test "reader: init refuses input of maxInt(u32) bytes or more" {
    // A 32-bit target cannot form the slices below.
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    const base: [*]const u8 = @ptrFromInt(8);
    var reader: Reader = undefined;
    // `init` reads only the length, so a slice that is never dereferenced probes the boundary.
    try reader.init(base[0..Reader.input_len_max]);
    try expectError(
        error.InputTooLarge,
        reader.init(base[0 .. @as(usize, Reader.input_len_max) + 1]),
    );
    try expectError(error.InputTooLarge, reader.init(base[0..std.math.maxInt(u32)]));
}

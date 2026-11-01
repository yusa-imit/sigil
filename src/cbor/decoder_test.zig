//! Tests for `cbor/decoder.zig` Reader (plan 007 item 5): RFC 8949 Appendix A items, the
//! Appendix F not-well-formed classes, limits and error positions.

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Reader = decoder.Reader;
const Item = decoder.Item;
const ScanError = decoder.ScanError;
const Diagnostics = core.Diagnostics;

const depth_default: u16 = 128;

/// Reads every token of `input` and checks them against `expected`, then the closing `.end`.
fn expect_items(input: []const u8, expected: []const Item) !void {
    var reader: Reader = undefined;
    try reader.init(input, depth_default);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    for (expected) |item| {
        const token = try reader.next(&diag);
        try expectEqualDeep(item, token.item);
    }
    const last = try reader.next(&diag);
    try expectEqual(Item.end, last.item);
    try expectEqual(@as(u32, @intCast(input.len)), last.offset);
    try expectEqualStrings("untouched", diag.message());
}

/// Reads tokens until one fails and checks the error, its column and the message prefix.
fn expect_scan_error(err: ScanError, offset: u32, input: []const u8) !void {
    try expect_scan_error_depth(err, offset, input, depth_default);
}

fn expect_scan_error_depth(err: ScanError, offset: u32, input: []const u8, depth: u16) !void {
    var reader: Reader = undefined;
    try reader.init(input, depth);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    var failed: ?ScanError = null;
    for (0..input.len + 2) |_| {
        const token = reader.next(&diag) catch |got| {
            failed = got;
            break;
        };
        if (token.item == .end) break;
    }
    try expectEqual(err, failed orelse return error.TestExpectedError);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(offset + 1, diag.col);
    var buffer: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buffer, "byte {d}: ", .{offset});
    try expect(std.mem.startsWith(u8, diag.message(), prefix));
}

/// A tag head followed by one content item.
fn expect_tagged(input: []const u8, number: u64, content: Item) !void {
    try expect_items(input, &.{ .{ .tag = number }, content });
}

fn int(value: i64) Item {
    return .{ .int = value };
}

fn bytes(value: []const u8) Item {
    return .{ .bytes = value };
}

fn text(value: []const u8) Item {
    return .{ .text = value };
}

test "appendix A: integers" {
    try expect_items("\x00", &.{int(0)});
    try expect_items("\x01", &.{int(1)});
    try expect_items("\x0a", &.{int(10)});
    try expect_items("\x17", &.{int(23)});
    try expect_items("\x18\x18", &.{int(24)});
    try expect_items("\x18\x19", &.{int(25)});
    try expect_items("\x18\x64", &.{int(100)});
    try expect_items("\x19\x03\xe8", &.{int(1000)});
    try expect_items("\x1a\x00\x0f\x42\x40", &.{int(1000000)});
    try expect_items("\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00", &.{int(1000000000000)});
    try expect_items("\x1b\xff\xff\xff\xff\xff\xff\xff\xff", &.{.{ .uint = std.math.maxInt(u64) }});
    try expect_items("\x20", &.{int(-1)});
    try expect_items("\x29", &.{int(-10)});
    try expect_items("\x38\x63", &.{int(-100)});
    try expect_items("\x39\x03\xe7", &.{int(-1000)});
}

test "integers: width is not kept, uint only above maxInt(i64), negative range ends at i64" {
    try expect_items("\x18\x05", &.{int(5)});
    try expect_items("\x1b\x00\x00\x00\x00\x00\x00\x00\x05", &.{int(5)});
    try expect_items("\x1b\x7f\xff\xff\xff\xff\xff\xff\xff", &.{int(std.math.maxInt(i64))});
    try expect_items("\x1b\x80\x00\x00\x00\x00\x00\x00\x00", &.{.{ .uint = 1 << 63 }});
    try expect_items("\x3b\x7f\xff\xff\xff\xff\xff\xff\xff", &.{int(std.math.minInt(i64))});
    try expect_items("\x3b\x00\x00\x00\x00\x00\x00\x00\x00", &.{int(-1)});
    // -2^63 - 1 and -2^64 are one past the range.
    try expect_scan_error(error.IntegerBelowMin, 0, "\x3b\x80\x00\x00\x00\x00\x00\x00\x00");
    try expect_scan_error(error.IntegerBelowMin, 0, "\x3b\xff\xff\xff\xff\xff\xff\xff\xff");
    try expect_scan_error(error.IntegerBelowMin, 1, "\x81\x3b\x80\x00\x00\x00\x00\x00\x00\x00");
}

test "appendix A: floats widen exactly" {
    const cases = [_]struct { input: []const u8, value: f64 }{
        .{ .input = "\xf9\x00\x00", .value = 0.0 },
        .{ .input = "\xf9\x80\x00", .value = -0.0 },
        .{ .input = "\xf9\x3c\x00", .value = 1.0 },
        .{ .input = "\xfb\x3f\xf1\x99\x99\x99\x99\x99\x9a", .value = 1.1 },
        .{ .input = "\xf9\x3e\x00", .value = 1.5 },
        .{ .input = "\xf9\x7b\xff", .value = 65504.0 },
        .{ .input = "\xfa\x47\xc3\x50\x00", .value = 100000.0 },
        .{ .input = "\xfa\x7f\x7f\xff\xff", .value = 3.4028234663852886e+38 },
        .{ .input = "\xfb\x7e\x37\xe4\x3c\x88\x00\x75\x9c", .value = 1.0e+300 },
        .{ .input = "\xf9\x00\x01", .value = 5.960464477539063e-8 },
        .{ .input = "\xf9\x04\x00", .value = 0.00006103515625 },
        .{ .input = "\xf9\xc4\x00", .value = -4.0 },
        .{ .input = "\xfb\xc0\x10\x66\x66\x66\x66\x66\x66", .value = -4.1 },
        .{ .input = "\xf9\x7c\x00", .value = std.math.inf(f64) },
        .{ .input = "\xf9\xfc\x00", .value = -std.math.inf(f64) },
        .{ .input = "\xfa\x7f\x80\x00\x00", .value = std.math.inf(f64) },
        .{ .input = "\xfa\xff\x80\x00\x00", .value = -std.math.inf(f64) },
        .{ .input = "\xfb\x7f\xf0\x00\x00\x00\x00\x00\x00", .value = std.math.inf(f64) },
        .{ .input = "\xfb\xff\xf0\x00\x00\x00\x00\x00\x00", .value = -std.math.inf(f64) },
    };
    for (cases) |case| {
        var reader: Reader = undefined;
        try reader.init(case.input, depth_default);
        var diag = Diagnostics.init(0, 0, "untouched", null);
        const token = try reader.next(&diag);
        try expectEqual(@as(u64, @bitCast(case.value)), @as(u64, @bitCast(token.item.float)));
    }
}

test "floats: NaN keeps its sign and payload bits through the widening" {
    const cases = [_]struct { input: []const u8, bits: u64 }{
        .{ .input = "\xf9\x7e\x00", .bits = 0x7ff8_0000_0000_0000 },
        .{ .input = "\xfa\x7f\xc0\x00\x00", .bits = 0x7ff8_0000_0000_0000 },
        .{ .input = "\xfb\x7f\xf8\x00\x00\x00\x00\x00\x00", .bits = 0x7ff8_0000_0000_0000 },
        .{ .input = "\xf9\xfe\x00", .bits = 0xfff8_0000_0000_0000 },
        .{ .input = "\xf9\x7c\x01", .bits = 0x7ff0_0400_0000_0000 },
        .{ .input = "\xfa\x7f\x80\x00\x01", .bits = 0x7ff0_0000_2000_0000 },
        .{ .input = "\xfb\x7f\xf0\x00\x00\x00\x00\x00\x01", .bits = 0x7ff0_0000_0000_0001 },
    };
    for (cases) |case| {
        var reader: Reader = undefined;
        try reader.init(case.input, depth_default);
        var diag = Diagnostics.init(0, 0, "untouched", null);
        const value = (try reader.next(&diag)).item.float;
        try expect(std.math.isNan(value));
        try expectEqual(case.bits, @as(u64, @bitCast(value)));
    }
}

test "appendix A: simple values and tags" {
    try expect_items("\xf4", &.{.{ .bool = false }});
    try expect_items("\xf5", &.{.{ .bool = true }});
    try expect_items("\xf6", &.{.null});
    try expect_items("\xf7", &.{.{ .simple = 23 }});
    try expect_items("\xf0", &.{.{ .simple = 16 }});
    try expect_items("\xf8\xff", &.{.{ .simple = 255 }});
    try expect_items("\xf8\x20", &.{.{ .simple = 32 }});
    const bignum = "\x01\x00\x00\x00\x00\x00\x00\x00\x00";
    try expect_tagged("\xc0\x74" ++ "2013-03-21T20:04:00Z", 0, text("2013-03-21T20:04:00Z"));
    try expect_tagged("\xc1\x1a\x51\x4b\x67\xb0", 1, int(1363896240));
    try expect_tagged("\xc1\xfb\x41\xd4\x52\xd9\xec\x20\x00\x00", 1, .{ .float = 1363896240.5 });
    try expect_tagged("\xd7\x44\x01\x02\x03\x04", 23, bytes("\x01\x02\x03\x04"));
    try expect_tagged("\xd8\x18\x45dIETF", 24, bytes("dIETF"));
    try expect_tagged("\xd8\x20\x76http://www.example.com", 32, text("http://www.example.com"));
    try expect_tagged("\xc2\x49" ++ bignum, 2, bytes(bignum));
    try expect_tagged("\xc3\x49" ++ bignum, 3, bytes(bignum));
}

test "appendix A: strings" {
    try expect_items("\x40", &.{bytes("")});
    try expect_items("\x44\x01\x02\x03\x04", &.{bytes("\x01\x02\x03\x04")});
    try expect_items("\x60", &.{text("")});
    try expect_items("\x61a", &.{text("a")});
    try expect_items("\x64IETF", &.{text("IETF")});
    try expect_items("\x62\"\\", &.{text("\"\\")});
    try expect_items("\x62\xc3\xbc", &.{text("\u{fc}")});
    try expect_items("\x63\xe6\xb0\xb4", &.{text("\u{6c34}")});
    try expect_items("\x64\xf0\x90\x85\x91", &.{text("\u{10151}")});
    try expect_items("\x78\x03abc", &.{text("abc")});
    try expect_items("\x59\x00\x01z", &.{bytes("z")});
}

test "appendix A: arrays and maps" {
    try expect_items("\x80", &.{.{ .array = 0 }});
    try expect_items("\x83\x01\x02\x03", &.{ .{ .array = 3 }, int(1), int(2), int(3) });
    try expect_items("\x83\x01\x82\x02\x03\x82\x04\x05", &.{
        .{ .array = 3 }, int(1), .{ .array = 2 }, int(2), int(3),
        .{ .array = 2 }, int(4), int(5),
    });
    try expect_items("\xa0", &.{.{ .map = 0 }});
    try expect_items("\xa2\x01\x02\x03\x04", &.{ .{ .map = 2 }, int(1), int(2), int(3), int(4) });
    try expect_items("\xa2\x61a\x01\x61b\x82\x02\x03", &.{
        .{ .map = 2 }, text("a"), int(1), text("b"), .{ .array = 2 }, int(2), int(3),
    });
    try expect_items("\x82\x61a\xa1\x61b\x61c", &.{
        .{ .array = 2 }, text("a"), .{ .map = 1 }, text("b"), text("c"),
    });
}

test "appendix A: an array of 25 items" {
    const full = "\x98\x19\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f" ++
        "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x18\x18\x19";
    var reader: Reader = undefined;
    try reader.init(full, depth_default);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try expectEqual(Item{ .array = 25 }, (try reader.next(&diag)).item);
    for (1..26) |expected| {
        try expectEqual(Item{ .int = @intCast(expected) }, (try reader.next(&diag)).item);
    }
    try expectEqual(Item.end, (try reader.next(&diag)).item);
}

test "appendix A: indefinite-length items" {
    try expect_items("\x5f\x42\x01\x02\x43\x03\x04\x05\xff", &.{
        .bytes_indef, bytes("\x01\x02"), bytes("\x03\x04\x05"), .stop,
    });
    try expect_items("\x7f\x65strea\x64ming\xff", &.{
        .text_indef, text("strea"), text("ming"), .stop,
    });
    try expect_items("\x9f\xff", &.{ .array_indef, .stop });
    try expect_items("\x9f\x01\x82\x02\x03\x9f\x04\x05\xff\xff", &.{
        .array_indef, int(1), .{ .array = 2 }, int(2), int(3),
        .array_indef, int(4), int(5),          .stop,  .stop,
    });
    try expect_items("\x83\x01\x82\x02\x03\x9f\x04\x05\xff", &.{
        .{ .array = 3 }, int(1), .{ .array = 2 }, int(2), int(3),
        .array_indef,    int(4), int(5),          .stop,
    });
    try expect_items("\x83\x01\x9f\x02\x03\xff\x82\x04\x05", &.{
        .{ .array = 3 }, int(1),          .array_indef, int(2), int(3),
        .stop,           .{ .array = 2 }, int(4),       int(5),
    });
    try expect_items("\xbf\x61a\x01\x61b\x9f\x02\x03\xff\xff", &.{
        .map_indef, text("a"), int(1), text("b"), .array_indef, int(2), int(3), .stop, .stop,
    });
    try expect_items("\x82\x61a\xbf\x61b\x61c\xff", &.{
        .{ .array = 2 }, text("a"), .map_indef, text("b"), text("c"), .stop,
    });
    try expect_items("\xbf\x63Fun\xf5\x63Amt\x21\xff", &.{
        .map_indef, text("Fun"), .{ .bool = true }, text("Amt"), int(-2), .stop,
    });
}

test "indefinite items: an empty string, back-to-back roots and a stop that finishes a tag" {
    try expect_items("\x5f\xff", &.{ .bytes_indef, .stop });
    try expect_items("\x7f\x60\x60\xff", &.{ .text_indef, text(""), text(""), .stop });
    try expect_items("\x01\x02", &.{ int(1), int(2) });
    try expect_items("\xc1\x9f\xff\x01", &.{ .{ .tag = 1 }, .array_indef, .stop, int(1) });
    // The definite array closes with its last item, so the next root starts a new frame set.
    try expect_items("\x81\x81\x01\x02", &.{ .{ .array = 1 }, .{ .array = 1 }, int(1), int(2) });
    // A string chunk does not complete an indefinite map's value until `stop`.
    try expect_items("\xbf\x61a\x5f\x41\x01\xff\xff", &.{
        .map_indef, text("a"), .bytes_indef, bytes("\x01"), .stop, .stop,
    });
}

test "appendix F: reserved additional info 28, 29, 30 on every major type" {
    for (0..8) |major| {
        for (28..31) |info| {
            const head: u8 = @intCast((major << 5) | info);
            try expect_scan_error(error.NotWellFormed, 0, &.{ head, 0, 0, 0, 0, 0, 0, 0, 0 });
            try expect_scan_error(error.NotWellFormed, 1, &.{ 0x81, head, 0, 0, 0 });
        }
    }
}

test "appendix F: additional info 31 on majors 0, 1 and 6" {
    try expect_scan_error(error.NotWellFormed, 0, "\x1f");
    try expect_scan_error(error.NotWellFormed, 0, "\x3f");
    try expect_scan_error(error.NotWellFormed, 0, "\xdf\x01");
}

test "appendix F: two-byte simple values below 32" {
    for (0..32) |value| {
        try expect_scan_error(error.NotWellFormed, 0, &.{ 0xf8, @intCast(value) });
    }
    try expect_scan_error(error.NotWellFormed, 1, "\x81\xf8\x1f");
}

test "appendix F: heads and payloads that run past the input" {
    try expect_scan_error(error.UnexpectedEnd, 0, "\x18");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x19\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x1a\x00\x00\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x1b\x00\x00\x00\x00\x00\x00\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xf9\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xfa\x00\x00\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xfb\x00\x00\x00\x00\x00\x00\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xf8");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x62a");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x42a");
    try expect_scan_error(error.UnexpectedEnd, 1, "\x81\x62a");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xc1");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x59\x00");
}

test "appendix F: a declared count larger than the bytes left is UnexpectedEnd at the head" {
    try expect_scan_error(error.UnexpectedEnd, 0, "\x81");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x82\x01");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xa1\x01");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xa2\x01\x02\x03");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x9b\xff\xff\xff\xff\xff\xff\xff\xff");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x9a\xff\xff\xff\xff");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xbb\x80\x00\x00\x00\x00\x00\x00\x00");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x5b\xff\xff\xff\xff\xff\xff\xff\xff");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x7a\xff\xff\xff\xff");
    // Exactly enough bytes is fine: the bomb rule is `n <= left`, `2 * n <= left`.
    try expect_items("\x81\x01", &.{ .{ .array = 1 }, int(1) });
    try expect_items("\xa1\x01\x02", &.{ .{ .map = 1 }, int(1), int(2) });
}

test "appendix F: input that ends inside an open item names the innermost open head" {
    try expect_scan_error(error.UnexpectedEnd, 0, "\x9f");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x9f\x01");
    try expect_scan_error(error.UnexpectedEnd, 1, "\x9f\x9f\x01");
    try expect_scan_error(error.UnexpectedEnd, 0, "\xbf\x61a");
    try expect_scan_error(error.UnexpectedEnd, 1, "\x81\xc1");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x5f");
    try expect_scan_error(error.UnexpectedEnd, 0, "\x7f\x61a");
    try expect_scan_error(error.UnexpectedEnd, 2, "\x82\x01\x9f");
    try expect_scan_error(error.UnexpectedEnd, 2, "\x82\x01\xc2");
}

test "appendix F: break placement" {
    try expect_scan_error(error.UnexpectedBreak, 0, "\xff");
    try expect_scan_error(error.UnexpectedBreak, 1, "\x81\xff");
    try expect_scan_error(error.UnexpectedBreak, 2, "\xa1\x01\xff");
    try expect_scan_error(error.UnexpectedBreak, 1, "\xc1\xff");
    try expect_scan_error(error.UnexpectedBreak, 2, "\x9f\xff\xff");
    try expect_scan_error(error.UnexpectedBreak, 1, "\x01\xff");
    try expect_scan_error(error.UnexpectedBreak, 2, "\x9f\x81\xff");
    try expect_scan_error(error.UnexpectedBreak, 2, "\x9f\xc1\xff");
    try expect_scan_error(error.UnexpectedBreak, 3, "\xa2\x00\x00\xff\x00");
    try expect_items("\xbf\x61a\x9f\xff\xff", &.{
        .map_indef, text("a"), .array_indef, .stop, .stop,
    });
    try expect_scan_error(error.InvalidIndefinite, 4, "\xbf\x01\xbf\x01\xff\xff");
    // A break after a map key leaves the pair incomplete.
    try expect_scan_error(error.InvalidIndefinite, 2, "\xbf\x01\xff");
    try expect_scan_error(error.InvalidIndefinite, 4, "\xbf\x01\x02\x03\xff");
}

test "appendix F: indefinite string chunks" {
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\x01\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\x5f\xff\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\x61a\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x7f\x41a\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x7f\x7f\xff\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\xc1\x41\x00\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\x9f\xff\xff");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\xf6\xff");
    try expect_scan_error(error.InvalidIndefinite, 3, "\x7f\x61a\x01\xff");
    try expect_scan_error(error.NotWellFormed, 1, "\x5f\x5c");
    try expect_scan_error(error.InvalidIndefinite, 1, "\x5f\xf8\x00");
    // A truncated chunk is reported at the chunk; complete chunks then EOF at the string head.
    try expect_scan_error(error.UnexpectedEnd, 1, "\x5f\x42\x01");
    try expect_scan_error(error.UnexpectedEnd, 2, "\x82\x01\x7f\x61a");
    try expect_scan_error(error.UnexpectedEnd, 1, "\x9f\x5f");
}

test "text is strict UTF-8, each indefinite chunk on its own" {
    try expect_scan_error(error.InvalidUtf8, 0, "\x62\xc3\x28");
    try expect_scan_error(error.InvalidUtf8, 0, "\x61\x80");
    try expect_scan_error(error.InvalidUtf8, 0, "\x63\xed\xa0\x80");
    try expect_scan_error(error.InvalidUtf8, 1, "\x81\x62\xc0\xaf");
    try expect_scan_error(error.InvalidUtf8, 1, "\x7f\x62\xc3\x28\xff");
    // A multi-byte character split over two chunks is invalid in each chunk.
    try expect_scan_error(error.InvalidUtf8, 1, "\x7f\x61\xc3\x61\xa9\xff");
    // Byte strings are not checked.
    try expect_items("\x42\xc3\x28", &.{bytes("\xc3\x28")});
}

test "depth: levels pass up to depth_max and the head that opens the next is TooDeep" {
    const two = "\x81\x81\x01";
    var reader: Reader = undefined;
    try reader.init(two, 2);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    for (0..3) |_| _ = try reader.next(&diag);
    try expect_scan_error_depth(error.TooDeep, 2, "\x81\x81\x81\x01", 2);
    try expect_scan_error_depth(error.TooDeep, 1, "\x81\x80", 1);
    try expect_scan_error_depth(error.TooDeep, 1, "\x81\x9f", 1);
    try expect_scan_error_depth(error.TooDeep, 1, "\x81\xa0", 1);
    // A tag is a level; its scalar content is not.
    try expect_scan_error_depth(error.TooDeep, 1, "\xc1\xc1\x01", 1);
    try expect_scan_error_depth(error.TooDeep, 1, "\xc1\x80", 1);
    try expect_scan_error_depth(error.TooDeep, 1, "\x81\xc1\x01", 1);
    try expect_items("\xc1\x01", &.{ .{ .tag = 1 }, int(1) });
    // An indefinite string is a leaf: it opens no level.
    var leaf: Reader = undefined;
    try leaf.init("\x81\x5f\x41\x01\xff", 1);
    for (0..5) |_| _ = try leaf.next(&diag);
}

test "depth: 128 nested arrays pass and 129 fail at the head of level 129" {
    const open = "\x81" ** 128;
    const full = open ++ "\x01";
    var reader: Reader = undefined;
    try reader.init(full, 128);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    for (0..129) |_| _ = try reader.next(&diag);
    try expectEqual(Item.end, (try reader.next(&diag)).item);
    try expect_scan_error(error.TooDeep, 128, open ++ "\x81\x01");
    const tags = "\xc1" ** 128;
    try expect_scan_error(error.TooDeep, 128, tags ++ "\xc1\x01");
    const mixed = "\xbf\x61k\x9f\xc1\x81" ** 32;
    try expect_scan_error(error.TooDeep, mixed.len, mixed ++ "\x81\x01");
}

test "reader: errors write diag once; the message names the byte" {
    var reader: Reader = undefined;
    try reader.init("\x81\x1c", depth_default);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    _ = try reader.next(&diag);
    try expectEqualStrings("untouched", diag.message());
    try expectError(error.NotWellFormed, reader.next(&diag));
    try expectEqualStrings("byte 1: not well-formed", diag.message());
}

test "reader: the empty input is .end and the offset is the input length" {
    var reader: Reader = undefined;
    try reader.init("", depth_default);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try reader.next(&diag);
    try expectEqual(Item.end, token.item);
    try expectEqual(@as(u32, 0), token.offset);
}

test "reader: init refuses input longer than input_len_max" {
    var reader: Reader = undefined;
    // `init` reads only `input.len`, so a slice over unmapped memory is safe here.
    const fake: []const u8 = @as([*]const u8, @ptrFromInt(8))[0 .. Reader.input_len_max + 1];
    try expectError(error.InputTooLarge, reader.init(fake, depth_default));
    const edge: []const u8 = @as([*]const u8, @ptrFromInt(8))[0..Reader.input_len_max];
    try reader.init(edge, depth_default);
    try expectEqual(@as(u32, 0), reader.offset);
}

test "reader: every first byte reads a head or fails with a pinned error" {
    var input = [_]u8{0} ** 33;
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        input[0] = byte;
        var reader: Reader = undefined;
        try reader.init(&input, depth_default);
        var diag = Diagnostics.init(0, 0, "untouched", null);
        const info = byte & 0x1f;
        const major = byte >> 5;
        const result = reader.next(&diag);
        if (info >= 28 and info <= 30) {
            try expectError(error.NotWellFormed, result);
        } else if (info == 31 and (major <= 1 or major == 6)) {
            try expectError(error.NotWellFormed, result);
        } else if (byte == 0xff) {
            try expectError(error.UnexpectedBreak, result);
        } else if (byte == 0xf8) {
            // The next byte is zero, a simple value below 32.
            try expectError(error.NotWellFormed, result);
        } else if (result) |token| {
            try expectEqual(@as(u32, 0), token.offset);
            try expect(reader.offset >= 1);
        } else |err| {
            // Only a head whose argument bytes run off the zero-filled tail may fail this way.
            try expectEqual(error.UnexpectedEnd, err);
        }
    }
}

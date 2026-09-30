//! core/unicode_escape — the format-agnostic escape primitives of plan 003 item 2: UTF-8
//! `encode`, `\uXXXX` `parse_hex4` and surrogate-pair `decode_utf16`, and `write_escaped` for the
//! escapes JSON, TOML basic and YAML double-quoted strings share. Per-format escape tables and
//! delimiters stay in the format modules. Every failure on hostile input is a typed error; a lone
//! surrogate is never replaced by U+FFFD. Allocation: none. Cost: O(text.len).

const std = @import("std");
const assert = std.debug.assert;
const unicode = @import("unicode.zig");
const find_invalid = unicode.find_invalid;
const Error = unicode.Error;
const Invalid = unicode.Invalid;

/// Escape-primitive errors. All are data errors (a hostile `\uD800` is input, not a bug).
pub const EscapeError = error{
    /// A `\uXXXX` digit is not in `0-9a-fA-F`.
    InvalidHex,
    /// A UTF-16 surrogate without its partner (or an unpaired low surrogate).
    LoneSurrogate,
    /// The codepoint is a surrogate or above U+10FFFF, so it has no UTF-8 form.
    InvalidCodepoint,
};

/// Errors of `write_escaped`: the text is not UTF-8 (nothing is written then), it is too long
/// for an offset, or the writer failed.
pub const WriteError = Error || error{InvalidUtf8} || std.Io.Writer.Error;

/// How much `write_escaped` escapes beyond the mandatory set (`"`, `\`, U+0000..U+001F, U+007F).
pub const EscapePolicy = enum {
    /// Non-ASCII text is written through as UTF-8.
    minimal,
    /// Every non-ASCII codepoint becomes `\uXXXX`, astral ones as a surrogate pair.
    ascii_only,
};

/// One decoded `\uXXXX` unit or pair: the codepoint and how many units (1 or 2) it consumed.
pub const Decoded = struct { codepoint: u21, units_count: u2 };

const surrogate_high_first: u16 = 0xD800;
const surrogate_high_last: u16 = 0xDBFF;
const surrogate_low_first: u16 = 0xDC00;
const surrogate_low_last: u16 = 0xDFFF;
const codepoint_max: u21 = 0x10FFFF;

/// Encodes `codepoint` as UTF-8 into `out` (bytes past the returned length are zeroed, and all
/// of `out` is zeroed on error, so the buffer is safe to hash or send whole) and returns the
/// byte count, 1..4. `error.InvalidCodepoint` for a surrogate or a value above U+10FFFF.
pub fn encode(codepoint: u21, out: *[4]u8) EscapeError!u3 {
    @memset(out, 0);
    if (codepoint > codepoint_max) return error.InvalidCodepoint;
    if (codepoint >= surrogate_high_first and codepoint <= surrogate_low_last) {
        return error.InvalidCodepoint;
    }
    const len: u3 = if (codepoint < 0x80)
        1
    else if (codepoint < 0x800)
        2
    else if (codepoint < 0x10000)
        3
    else
        4;
    switch (len) {
        1 => out[0] = @intCast(codepoint),
        2 => {
            out[0] = @intCast(0xC0 | (codepoint >> 6));
            out[1] = @intCast(0x80 | (codepoint & 0x3F));
        },
        3 => {
            out[0] = @intCast(0xE0 | (codepoint >> 12));
            out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
            out[2] = @intCast(0x80 | (codepoint & 0x3F));
        },
        4 => {
            out[0] = @intCast(0xF0 | (codepoint >> 18));
            out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
            out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
            out[3] = @intCast(0x80 | (codepoint & 0x3F));
        },
        else => unreachable, // `len` is one of the four literals above.
    }
    assert(len >= 1);
    assert(out[0] != 0 or codepoint == 0);
    return len;
}

/// Parses the four hex digits of a `\uXXXX` escape (either case) into a UTF-16 code unit.
/// `error.InvalidHex` if any digit is not hexadecimal. Sign, prefix and spaces are rejected.
pub fn parse_hex4(digits: *const [4]u8) EscapeError!u16 {
    assert(digits.len == 4);
    var unit: u16 = 0;
    for (digits) |digit| {
        const nibble: u8 = switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => return error.InvalidHex,
        };
        assert(nibble < 16);
        unit = (unit << 4) | nibble;
    }
    return unit;
}

/// Combines UTF-16 units from `\uXXXX` escapes: `first` is the unit just parsed and `second` the
/// unit of an immediately following `\uXXXX`, or null if there is none. A non-surrogate `first`
/// consumes one unit and ignores `second`; a high surrogate needs `second` to be a low surrogate
/// (consumes two); any other surrogate is `error.LoneSurrogate`, never a silent U+FFFD.
pub fn decode_utf16(first: u16, second: ?u16) EscapeError!Decoded {
    if (first < surrogate_high_first or first > surrogate_low_last) {
        return .{ .codepoint = first, .units_count = 1 };
    }
    if (first > surrogate_high_last) return error.LoneSurrogate;
    const low = second orelse return error.LoneSurrogate;
    if (low < surrogate_low_first or low > surrogate_low_last) return error.LoneSurrogate;
    const high_bits: u21 = first - surrogate_high_first;
    const low_bits: u21 = low - surrogate_low_first;
    const codepoint: u21 = 0x10000 + (high_bits << 10) + low_bits;
    assert(codepoint >= 0x10000);
    assert(codepoint <= codepoint_max);
    return .{ .codepoint = codepoint, .units_count = 2 };
}

/// Writes `text` to `w` with the escapes JSON strings, TOML basic strings and YAML double-quoted
/// scalars share: `\"`, `\\`, `\b`, `\t`, `\n`, `\f`, `\r`, other U+0000..U+001F and U+007F (TOML
/// and YAML forbid it raw) as `\u00xx`
/// (lowercase hex), and under `.ascii_only` every non-ASCII codepoint as `\uxxxx`. Delimiters
/// and format-only escapes stay in each format module. `text` is validated first: invalid UTF-8
/// is `error.InvalidUtf8` and nothing has been written. Writes unescaped runs in one call each.
pub fn write_escaped(w: *std.Io.Writer, text: []const u8, policy: EscapePolicy) WriteError!void {
    if (try find_invalid(text) != null) return error.InvalidUtf8;

    var run_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        const needs_escape = byte < 0x20 or byte == 0x7F or byte == '"' or byte == '\\' or
            (byte >= 0x80 and policy == .ascii_only);
        if (!needs_escape) {
            index += 1;
            continue;
        }
        try w.writeAll(text[run_start..index]);
        index += try write_escape_one(w, text[index..]);
        run_start = index;
    }
    assert(index == text.len);
    assert(run_start <= text.len);
    try w.writeAll(text[run_start..]);
}

/// Writes the escape for the character at the start of `rest` (validated UTF-8, first byte
/// needs escaping) and returns how many input bytes it covered.
fn write_escape_one(w: *std.Io.Writer, rest: []const u8) WriteError!usize {
    assert(rest.len > 0);
    const byte = rest[0];
    switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        0x0C => try w.writeAll("\\f"),
        '\r' => try w.writeAll("\\r"),
        0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{byte}),
        0x80...0xFF => {
            // `write_escaped` ran `find_invalid` on the whole text, so `byte` is a legal lead
            // and `rest[0..len]` a complete well-formed sequence; both calls below cannot fail.
            const len = std.unicode.utf8ByteSequenceLength(byte) catch unreachable; // proof: above
            const sequence = rest[0..len];
            const codepoint = std.unicode.utf8Decode(sequence) catch unreachable; // proof: above
            if (codepoint < 0x10000) {
                try w.print("\\u{x:0>4}", .{codepoint});
            } else {
                const offset = codepoint - 0x10000;
                try w.print("\\u{x:0>4}\\u{x:0>4}", .{
                    surrogate_high_first + (offset >> 10),
                    surrogate_low_first + (offset & 0x3FF),
                });
            }
            return len;
        },
        else => unreachable, // The caller only passes bytes its `needs_escape` test accepted.
    }
    return 1;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "encode: every codepoint matches std, is valid UTF-8, and zeroes the tail" {
    var codepoint: u32 = 0;
    while (codepoint <= 0x10FFFF) : (codepoint += 1) {
        const cp: u21 = @intCast(codepoint);
        var out: [4]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA };
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            try expectError(error.InvalidCodepoint, encode(cp, &out));
            continue;
        }
        var reference: [4]u8 = undefined;
        const len = try encode(cp, &out);
        try expectEqual(try std.unicode.utf8Encode(cp, &reference), len);
        try std.testing.expectEqualSlices(u8, reference[0..len], out[0..len]);
        try expectEqual(@as(?Invalid, null), try find_invalid(out[0..len]));
        for (out[len..]) |tail| try expectEqual(@as(u8, 0), tail);
    }
}

test "encode: above U+10FFFF and surrogate edges are InvalidCodepoint" {
    var out: [4]u8 = undefined;
    try expectError(error.InvalidCodepoint, encode(0x110000, &out));
    try expectError(error.InvalidCodepoint, encode(0x1FFFFF, &out));
    try expectError(error.InvalidCodepoint, encode(0xD800, &out));
    try expectError(error.InvalidCodepoint, encode(0xDFFF, &out));
    try expectEqual(@as(u3, 3), try encode(0xD7FF, &out));
    try expectEqual(@as(u3, 3), try encode(0xE000, &out));
    try expectEqual(@as(u3, 4), try encode(0x10FFFF, &out));
    try expectEqual(@as(u3, 1), try encode(0, &out));
}

test "parse_hex4: every u16 formatted in both cases round-trips" {
    var unit: u32 = 0;
    while (unit <= 0xFFFF) : (unit += 1) {
        var lower: [4]u8 = undefined;
        _ = try std.fmt.bufPrint(&lower, "{x:0>4}", .{unit});
        var upper: [4]u8 = undefined;
        _ = try std.fmt.bufPrint(&upper, "{X:0>4}", .{unit});
        try expectEqual(@as(u16, @intCast(unit)), try parse_hex4(&lower));
        try expectEqual(@as(u16, @intCast(unit)), try parse_hex4(&upper));
    }
}

test "parse_hex4: a non-hex byte at any position is InvalidHex" {
    const bad = [_]u8{ 'g', 'G', ' ', '+', '-', 'x', '/', ':', '@', '`', 0x00, 0x80, 0xFF };
    for (bad) |byte| {
        var position: usize = 0;
        while (position < 4) : (position += 1) {
            var digits = [4]u8{ '0', '0', '4', '1' };
            digits[position] = byte;
            try expectError(error.InvalidHex, parse_hex4(&digits));
        }
    }
}

test "decode_utf16: non-surrogates take one unit and ignore the second" {
    const cases = [_]struct { first: u16, second: ?u16 }{
        .{ .first = 0x41, .second = null },
        .{ .first = 0, .second = null },
        .{ .first = 0xD7FF, .second = 0xDC00 },
        .{ .first = 0xE000, .second = 0xDC00 },
        .{ .first = 0xFFFF, .second = null },
    };
    for (cases) |c| {
        const decoded = try decode_utf16(c.first, c.second);
        try expectEqual(Decoded{ .codepoint = c.first, .units_count = 1 }, decoded);
    }
}

test "decode_utf16: valid pairs combine at both ends of the astral range" {
    const first = try decode_utf16(0xD800, 0xDC00);
    try expectEqual(Decoded{ .codepoint = 0x10000, .units_count = 2 }, first);
    const last = try decode_utf16(0xDBFF, 0xDFFF);
    try expectEqual(Decoded{ .codepoint = 0x10FFFF, .units_count = 2 }, last);
    const emoji = try decode_utf16(0xD83D, 0xDE00);
    try expectEqual(Decoded{ .codepoint = 0x1F600, .units_count = 2 }, emoji);
}

test "decode_utf16: every lone or misplaced surrogate is LoneSurrogate" {
    try expectError(error.LoneSurrogate, decode_utf16(0xD800, null)); // high, no partner
    try expectError(error.LoneSurrogate, decode_utf16(0xDBFF, null));
    try expectError(error.LoneSurrogate, decode_utf16(0xD800, 0x41)); // partner not a surrogate
    try expectError(error.LoneSurrogate, decode_utf16(0xD800, 0xD7FF)); // one below low range
    try expectError(error.LoneSurrogate, decode_utf16(0xD800, 0xE000)); // one above low range
    try expectError(error.LoneSurrogate, decode_utf16(0xD800, 0xD800)); // high + high
    try expectError(error.LoneSurrogate, decode_utf16(0xDC00, null)); // low first
    try expectError(error.LoneSurrogate, decode_utf16(0xDFFF, 0xDC00)); // low + low
    try expectError(error.LoneSurrogate, decode_utf16(0xDC00, 0xD800)); // reversed pair
}

/// Runs `write_escaped` into a fixed buffer and returns what was written.
fn escaped_into(buf: []u8, text: []const u8, policy: EscapePolicy) WriteError![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try write_escaped(&w, text, policy);
    return w.buffered();
}

fn expect_escaped(text: []const u8, policy: EscapePolicy, expected: []const u8) !void {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try escaped_into(&buf, text, policy));
}

test "write_escaped: text needing nothing is written through under both policies" {
    try expect_escaped("", .minimal, "");
    try expect_escaped("", .ascii_only, "");
    try expect_escaped("plain text 123 ~ \x20", .minimal, "plain text 123 ~ \x20");
    try expect_escaped("plain text 123 ~ \x20", .ascii_only, "plain text 123 ~ \x20");
}

test "write_escaped: quote, backslash and the short control escapes" {
    try expect_escaped("a\"b\\c", .minimal, "a\\\"b\\\\c");
    try expect_escaped("\x08\t\n\x0C\r", .minimal, "\\b\\t\\n\\f\\r");
    try expect_escaped("x\ny", .ascii_only, "x\\ny");
}

test "write_escaped: every other control byte is a lowercase \\u00xx" {
    try expect_escaped("\x00", .minimal, "\\u0000");
    try expect_escaped("\x01\x07\x0B\x0E\x1F", .minimal, "\\u0001\\u0007\\u000b\\u000e\\u001f");
    try expect_escaped("a\x00b", .minimal, "a\\u0000b");
}

test "write_escaped: minimal passes non-ASCII through, ascii_only escapes it" {
    const text = "\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80";
    try expect_escaped(text, .minimal, text);
    try expect_escaped(text, .ascii_only, "\\u00e9\\u20ac\\ud83d\\ude00");
    try expect_escaped("\xF4\x8F\xBF\xBF", .ascii_only, "\\udbff\\udfff");
    try expect_escaped("\xEF\xBF\xBF", .ascii_only, "\\uffff");
    try expect_escaped("a\xC2\x80z", .ascii_only, "a\\u0080z");
}

test "write_escaped: invalid UTF-8 is InvalidUtf8 and nothing is written" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try expectError(error.InvalidUtf8, write_escaped(&w, "ok\"\xED\xA0\x80", .minimal));
    try expectError(error.InvalidUtf8, write_escaped(&w, "ok\xC3", .ascii_only));
    try expectEqual(@as(usize, 0), w.buffered().len);
}

test "write_escaped: a writer that fills up reports WriteFailed" {
    var buf: [3]u8 = undefined;
    try expectError(error.WriteFailed, escaped_into(&buf, "abcdef", .minimal));
    try expectError(error.WriteFailed, escaped_into(&buf, "\n\n", .minimal));
    try expectError(error.WriteFailed, escaped_into(&buf, "\xC3\xA9", .ascii_only));
}

test "write_escaped: ascii_only output decodes back to every non-ASCII codepoint" {
    var codepoint: u32 = 0x80;
    while (codepoint <= 0x10FFFF) : (codepoint += 1) {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) continue;
        var utf8: [4]u8 = undefined;
        const len = try encode(@intCast(codepoint), &utf8);
        var buf: [16]u8 = undefined;
        const out = try escaped_into(&buf, utf8[0..len], .ascii_only);

        try expect(out.len == 6 or out.len == 12);
        try expect(std.mem.startsWith(u8, out, "\\u"));
        const first = try parse_hex4(out[2..6]);
        const second: ?u16 = if (out.len == 12) try parse_hex4(out[8..12]) else null;
        const decoded = try decode_utf16(first, second);
        try expectEqual(@as(u21, @intCast(codepoint)), decoded.codepoint);
        try expectEqual(@as(usize, decoded.units_count) * 6, out.len);
    }
}

test "write_escaped: DEL is escaped, and escapes adjacent to non-ASCII flush runs correctly" {
    try expect_escaped("\x7F", .minimal, "\\u007f");
    try expect_escaped("a\x7Fb", .ascii_only, "a\\u007fb");
    try expect_escaped("\"\xC3\xA9\n", .ascii_only, "\\\"\\u00e9\\n");
    try expect_escaped("\xC3\xA9\"\xC3\xA9", .minimal, "\xC3\xA9\\\"\xC3\xA9");
}

test "write_escaped: a text longer than maxInt(u32) is InputTooLarge and writes nothing" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    const backing: [1]u8 = .{'"'};
    const oversized = @as([*]const u8, &backing)[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try expectError(error.InputTooLarge, write_escaped(&w, oversized, .minimal));
    try expectEqual(@as(usize, 0), w.buffered().len);
}

test "encode: an error leaves the whole buffer zeroed" {
    var out: [4]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA };
    try expectError(error.InvalidCodepoint, encode(0xD800, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out);
}

//! Tests for `scanner.raw_eql` (plan 004 item 8, ADR 0003 section 8): a `.key` token's `raw`
//! text is compared with a plain key by its decoded bytes, without allocating. Escapes decode
//! first (`host` is `host`), the spelling never matters, and every length boundary is
//! exact. A seeded model builds raw text from a known decoded string with random escape
//! choices and checks `raw_eql` against it and against `decode_string`.

const std = @import("std");
const scanner = @import("scanner.zig");
const assert = std.debug.assert;
const testing = std.testing;
const raw_eql = scanner.raw_eql;

test "raw_eql: without escapes it is byte equality at every length boundary" {
    try testing.expect(raw_eql("", false, ""));
    try testing.expect(!raw_eql("", false, "a"));
    try testing.expect(!raw_eql("a", false, ""));
    try testing.expect(raw_eql("abc", false, "abc"));
    try testing.expect(!raw_eql("abc", false, "ab"));
    try testing.expect(!raw_eql("ab", false, "abc"));
    try testing.expect(!raw_eql("abc", false, "abd"));
    try testing.expect(!raw_eql("abc", false, "Abc"));
    try testing.expect(raw_eql("caf\u{e9}", false, "caf\u{e9}"));
    try testing.expect(!raw_eql("caf\u{e9}", false, "cafe"));
}

const Simple = struct { raw: []const u8, decoded: []const u8 };

test "raw_eql: each short escape decodes before the comparison" {
    const table = [_]Simple{
        .{ .raw = "\\\"", .decoded = "\"" },
        .{ .raw = "\\\\", .decoded = "\\" },
        .{ .raw = "\\/", .decoded = "/" },
        .{ .raw = "\\b", .decoded = "\x08" },
        .{ .raw = "\\f", .decoded = "\x0c" },
        .{ .raw = "\\n", .decoded = "\n" },
        .{ .raw = "\\r", .decoded = "\r" },
        .{ .raw = "\\t", .decoded = "\t" },
    };
    inline for (table) |row| {
        try testing.expect(raw_eql(row.raw, true, row.decoded));
        // The spelling of the escape is not the key: the two raw bytes never match themselves.
        try testing.expect(!raw_eql(row.raw, true, row.raw));
        try testing.expect(!raw_eql(row.raw, true, ""));
        try testing.expect(!raw_eql(row.raw, true, "x"));
        try testing.expect(!raw_eql(row.raw, true, row.decoded ++ row.decoded));
    }
}

test "raw_eql: unicode escapes decode to UTF-8 of one to four bytes" {
    try testing.expect(raw_eql("\\u0041", true, "A"));
    try testing.expect(raw_eql("\\u00e9", true, "\u{e9}"));
    try testing.expect(raw_eql("\\u00E9", true, "\u{e9}"));
    try testing.expect(raw_eql("\\u20ac", true, "\u{20ac}"));
    try testing.expect(raw_eql("\\ud83d\\ude00", true, "\u{1F600}"));
    try testing.expect(raw_eql("\\uD83D\\uDE00", true, "\u{1F600}"));
    try testing.expect(raw_eql("\\u0000", true, "\x00"));

    try testing.expect(!raw_eql("\\u0041", true, "\\u0041"));
    try testing.expect(!raw_eql("\\u0041", true, "a"));
    try testing.expect(!raw_eql("\\u00e9", true, "e"));
    try testing.expect(!raw_eql("\\u00e9", true, "\xc3"));
    try testing.expect(!raw_eql("\\u0000", true, ""));
    try testing.expect(!raw_eql("\\ud83d\\ude00", true, "\u{1F600}x"));
    try testing.expect(!raw_eql("\\ud83d\\ude00", true, "\xf0\x9f\x98"));
    try testing.expect(!raw_eql("\\ud83d\\ude00", true, "\u{1F601}"));
}

test "raw_eql: an escape at the start, the end and back to back" {
    try testing.expect(raw_eql("\\nabc", true, "\nabc"));
    try testing.expect(raw_eql("abc\\n", true, "abc\n"));
    try testing.expect(raw_eql("a\\nb", true, "a\nb"));
    try testing.expect(raw_eql("\\n\\n", true, "\n\n"));
    try testing.expect(raw_eql("\\\\\\\\", true, "\\\\"));
    try testing.expect(!raw_eql("\\\\\\\\", true, "\\"));
    try testing.expect(!raw_eql("\\\\\\\\", true, "\\\\\\"));
    try testing.expect(!raw_eql("\\nabc", true, "nabc"));
    try testing.expect(!raw_eql("abc\\n", true, "abc"));
    try testing.expect(!raw_eql("a\\nb", true, "a\\nb"));
}

test "raw_eql: an escaped spelling of a plain key matches and near misses do not" {
    try testing.expect(raw_eql("h\\u006fst", true, "host"));
    try testing.expect(raw_eql("\\u0068\\u006f\\u0073\\u0074", true, "host"));
    try testing.expect(!raw_eql("h\\u006fst", true, "hosT"));
    try testing.expect(!raw_eql("h\\u006fst", true, "hos"));
    try testing.expect(!raw_eql("h\\u006fst", true, "hostt"));
    try testing.expect(!raw_eql("h\\u006fst", true, "h\\u006fst"));
    try testing.expect(raw_eql("\u{e9}\\u00e9", true, "\u{e9}\u{e9}"));
    try testing.expect(raw_eql("a\\\\b", true, "a\\b"));
    try testing.expect(!raw_eql("a\\\\b", true, "a\\\\b"));
}

/// A codepoint pool that covers every encoder branch: forced escapes, optional escapes, and
/// one- to four-byte UTF-8, including NUL and the highest codepoint.
const pool = [_]u21{
    'a',  'Z',   '0',   ' ',    '/',    '"',     '\\',    0x00,     0x08, 0x0a, 0x1f, 0x7f,
    0xe9, 0x7ff, 0x800, 0x20ac, 0xffff, 0x10000, 0x1F600, 0x10ffff,
};

/// Writes `codepoint` into `w` as a JSON string body would: `"`, `\` and controls are always
/// escaped, everything else is raw or `\uXXXX` (a surrogate pair above U+FFFF) by `rng`.
/// Postcondition: the bytes written decode back to `codepoint`.
pub fn encode_random(w: *std.Io.Writer, rng: std.Random, codepoint: u21) std.Io.Writer.Error!void {
    assert(codepoint <= 0x10ffff);
    assert(codepoint < 0xd800 or codepoint > 0xdfff);
    const forced = codepoint == '"' or codepoint == '\\' or codepoint < 0x20;
    if (!forced and rng.boolean()) {
        var utf8: [4]u8 = undefined;
        // proof: the pool holds scalar values only, which always encode.
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch unreachable;
        return w.writeAll(utf8[0..len]);
    }
    if (rng.boolean()) switch (codepoint) {
        '"' => return w.writeAll("\\\""),
        '\\' => return w.writeAll("\\\\"),
        '/' => return w.writeAll("\\/"),
        '\n' => return w.writeAll("\\n"),
        else => {},
    };
    if (codepoint < 0x10000) return w.print("\\u{x:0>4}", .{codepoint});
    const offset = codepoint - 0x10000;
    const high: u16 = 0xd800 + @as(u16, @intCast(offset >> 10));
    const low: u16 = 0xdc00 + @as(u16, @intCast(offset & 0x3ff));
    return w.print("\\u{x:0>4}\\u{x:0>4}", .{ high, low });
}

const model_seeds: u32 = 600;

/// One seeded case: a decoded string, a raw spelling of it, and whether the raw has a `\`.
const Case = struct {
    decoded_buffer: [64]u8,
    decoded_len: u32,
    raw_buffer: [512]u8,
    raw_len: u32,

    fn decoded(case: *const Case) []const u8 {
        assert(case.decoded_len <= case.decoded_buffer.len);
        return case.decoded_buffer[0..case.decoded_len];
    }

    fn raw(case: *const Case) []const u8 {
        assert(case.raw_len <= case.raw_buffer.len);
        return case.raw_buffer[0..case.raw_len];
    }

    fn has_escapes(case: *const Case) bool {
        return std.mem.findScalar(u8, case.raw(), '\\') != null;
    }
};

/// Fills `case` with 0..8 random pool codepoints and a random raw spelling of them.
fn draw_case(case: *Case, rng: std.Random) !void {
    var raw_writer: std.Io.Writer = .fixed(&case.raw_buffer);
    var decoded_writer: std.Io.Writer = .fixed(&case.decoded_buffer);
    const count = rng.uintLessThan(u32, 9);
    for (0..count) |_| {
        const codepoint = pool[rng.uintLessThan(usize, pool.len)];
        var utf8: [4]u8 = undefined;
        // proof: the pool holds scalar values only, which always encode.
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch unreachable;
        try decoded_writer.writeAll(utf8[0..len]);
        try encode_random(&raw_writer, rng, codepoint);
    }
    case.decoded_len = @intCast(decoded_writer.end);
    case.raw_len = @intCast(raw_writer.end);
    assert(case.raw_len >= case.decoded_len or case.has_escapes());
}

test "raw_eql: model: a random spelling matches its decoded string and no neighbour" {
    var prng = std.Random.DefaultPrng.init(0x7261_775f_6571_6c);
    const rng = prng.random();
    var case: Case = undefined;
    var mutated: [80]u8 = undefined;
    for (0..model_seeds) |seed| {
        errdefer std.log.err("raw_eql model failed at case {d}", .{seed});
        try draw_case(&case, rng);
        const raw = case.raw();
        const key = case.decoded();
        try testing.expect(raw_eql(raw, case.has_escapes(), key));

        // The oracle for the model: `decode_string` agrees with how the case was built.
        var out: [512]u8 = undefined;
        try testing.expectEqualSlices(u8, key, scanner.decode_string(raw, &out));

        // Neighbours: one byte appended, dropped, or flipped is never equal.
        @memcpy(mutated[0..key.len], key);
        mutated[key.len] = 'x';
        try testing.expect(!raw_eql(raw, case.has_escapes(), mutated[0 .. key.len + 1]));
        if (key.len > 0) {
            try testing.expect(!raw_eql(raw, case.has_escapes(), key[0 .. key.len - 1]));
            mutated[0] = key[0] ^ 0x01;
            @memcpy(mutated[1..key.len], key[1..]);
            try testing.expect(!raw_eql(raw, case.has_escapes(), mutated[0..key.len]));
        }

        // A second, unrelated key: `raw_eql` agrees with comparing the decoded bytes.
        var other: Case = undefined;
        try draw_case(&other, rng);
        const expected = std.mem.eql(u8, key, other.decoded());
        try testing.expectEqual(expected, raw_eql(raw, case.has_escapes(), other.decoded()));
    }
}

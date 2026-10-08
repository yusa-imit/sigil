//! Tests for `json/scanner.zig` strings and `decode_string` (plan 004 item 3).

const std = @import("std");
const core = @import("../core.zig");
const scanner = @import("scanner.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Scanner = scanner.Scanner;
const Token = scanner.Token;
const ScanError = scanner.ScanError;
const Diagnostics = core.Diagnostics;

/// Scans a root-scalar string and returns its token, or the scan error.
fn scan_string_token(input: []const u8, diag: *Diagnostics) !Token {
    var sc: Scanner = undefined;
    try sc.init(input, .{ .depth_max = 8 });
    const token = try sc.next(diag);
    try expect(token.kind == .string);
    return token;
}

/// Scans `input` to its end or its first error.
fn scan_all(input: []const u8, diag: *Diagnostics) !void {
    var sc: Scanner = undefined;
    try sc.init(input, .{ .depth_max = 8 });
    for (0..input.len + 2) |_| {
        const token = try sc.next(diag);
        if (token.kind == .end) return;
    }
    return error.TestUnexpectedResult;
}

fn expect_decoded(input: []const u8, expected: []const u8) !void {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try scan_string_token(input, &diag);
    var out: [128]u8 = undefined;
    const decoded = scanner.decode_string(token.raw, out[0..token.raw.len]);
    try expectEqualStrings(expected, decoded);
    try expect(decoded.len <= token.raw.len);
    try expectEqualStrings("untouched", diag.message());
}

fn expect_string_failure(input: []const u8, err: ScanError, line: u32, col: u32) !void {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try std.testing.expectError(err, scan_all(input, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(!std.mem.eql(u8, diag.message(), "untouched"));
    try expect(diag.snippet_text() != null);
}

test "string: plain content, empty string, and the raw slice excludes the quotes" {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try scan_string_token("  \"abc\"", &diag);
    try expectEqualStrings("abc", token.raw);
    try expectEqual(@as(u32, 2), token.offset);
    try expect(!token.has_escapes);
    const empty = try scan_string_token("\"\"", &diag);
    try expectEqual(@as(usize, 0), empty.raw.len);
    try expect(!empty.has_escapes);
}

test "string: every simple escape decodes" {
    try expect_decoded("\"\\\"\"", "\"");
    try expect_decoded("\"\\\\\"", "\\");
    try expect_decoded("\"\\/\"", "/");
    try expect_decoded("\"\\b\"", "\x08");
    try expect_decoded("\"\\f\"", "\x0c");
    try expect_decoded("\"\\n\"", "\n");
    try expect_decoded("\"\\r\"", "\r");
    try expect_decoded("\"\\t\"", "\t");
    try expect_decoded("\"a\\\"b\\\\c\"", "a\"b\\c");
}

test "string: an escaped quote does not end the string and sets has_escapes" {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try scan_string_token("\"a\\\"b\"", &diag);
    try expectEqualStrings("a\\\"b", token.raw);
    try expect(token.has_escapes);
}

test "string: unicode escapes, both hex cases, NUL, and surrogate pairs" {
    try expect_decoded("\"\\u0041\"", "A");
    try expect_decoded("\"\\u00e9\"", "\xc3\xa9");
    try expect_decoded("\"\\u00E9\"", "\xc3\xa9");
    try expect_decoded("\"\\u20ac\"", "\xe2\x82\xac");
    try expect_decoded("\"\\u0000\"", "\x00");
    try expect_decoded("\"\\ud83d\\ude00\"", "\xf0\x9f\x98\x80");
    try expect_decoded("\"\\uD83D\\uDE00x\"", "\xf0\x9f\x98\x80x");
    try expect_decoded("\"\\ud800\\udc00\"", "\xf0\x90\x80\x80");
    try expect_decoded("\"\\udbff\\udfff\"", "\xf4\x8f\xbf\xbf");
    try expect_decoded("\"\\ud7ff\\ue000\"", "\xed\x9f\xbf\xee\x80\x80");
}

test "string: raw multibyte UTF-8 and DEL and noncharacters pass through" {
    const text = "\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80";
    try expect_decoded("\"" ++ text ++ "\"", text);
    try expect_decoded("\"\x7f\"", "\x7f");
    try expect_decoded("\"\xef\xbf\xbf\"", "\xef\xbf\xbf");
    try expect_decoded("\"\x20\"", " ");
}

test "string: decode_string never grows and fits an out exactly raw.len long" {
    // Worst ratios: `\u0041` 6 -> 1, a pair 12 -> 4, `\n` 2 -> 1; out.len == raw.len suffices.
    var out: [12]u8 = undefined;
    const pair = scanner.decode_string("\\ud83d\\ude00", out[0..12]);
    try expectEqual(@as(usize, 4), pair.len);
    const mixed = scanner.decode_string("a\\u0042\\nz", out[0..10]);
    try expectEqualStrings("aB\nz", mixed);
    const none = scanner.decode_string("", out[0..0]);
    try expectEqual(@as(usize, 0), none.len);
}

test "string: control characters below 0x20 are rejected at their column" {
    try expect_string_failure("\"a\nb\"", error.ControlCharacter, 1, 3);
    try expect_string_failure("\"a\x00\"", error.ControlCharacter, 1, 3);
    try expect_string_failure("\"\x1f\"", error.ControlCharacter, 1, 2);
    try expect_string_failure("\"\t\"", error.ControlCharacter, 1, 2);
    try expect_string_failure("\"ab\r\"", error.ControlCharacter, 1, 4);
}

test "string: invalid escapes are reported at the backslash" {
    try expect_string_failure("\"a\\x\"", error.InvalidEscape, 1, 3);
    try expect_string_failure("\"\\'\"", error.InvalidEscape, 1, 2);
    try expect_string_failure("\"\\u12G4\"", error.InvalidEscape, 1, 2);
    try expect_string_failure("\"\\u12\"", error.InvalidEscape, 1, 2);
    try expect_string_failure("\"\\u+123\"", error.InvalidEscape, 1, 2);
    try expect_string_failure("\"\\\xc3\xa9\"", error.InvalidEscape, 1, 2);
    try expect_string_failure("\"\\U0041\"", error.InvalidEscape, 1, 2);
}

test "string: lone and mispaired surrogates are LoneSurrogate, never U+FFFD" {
    try expect_string_failure("\"\\ud800\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\udc00\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"x\\ud83dx\"", error.LoneSurrogate, 1, 3);
    try expect_string_failure("\"\\ud800\\u0041\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud800\\ud800\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud800\\n\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\udbff\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\udfff\\ud800\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud83d\\uZZZZ\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud83d\\u12\"", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud83d\\ude0", error.LoneSurrogate, 1, 2);
    try expect_string_failure("\"\\ud83d", error.LoneSurrogate, 1, 2);
}

test "string: invalid UTF-8 is reported at the first byte of the bad sequence" {
    try expect_string_failure("\"ab\xc3(\"", error.InvalidUtf8, 1, 4);
    try expect_string_failure("\"\xff\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\x80\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\xc0\x80\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\xed\xa0\x80\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\xf4\x90\x80\x80\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"x\xe2\x82\"", error.InvalidUtf8, 1, 3);
    try expect_string_failure("\"\n\xed\xa0\x80\"", error.ControlCharacter, 1, 2);
}

test "string: the earlier of two faults wins" {
    try expect_string_failure("\"\xff\n\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\n\xff\"", error.ControlCharacter, 1, 2);
    try expect_string_failure("\"\xff\\x\"", error.InvalidUtf8, 1, 2);
    try expect_string_failure("\"\\x\xff\"", error.InvalidEscape, 1, 2);
}

test "string: unterminated strings and escapes end at the input end" {
    try expect_string_failure("\"abc", error.UnexpectedEnd, 1, 5);
    try expect_string_failure("\"", error.UnexpectedEnd, 1, 2);
    try expect_string_failure("\"abc\\", error.UnexpectedEnd, 1, 6);
    try expect_string_failure("\"\\u00", error.UnexpectedEnd, 1, 6);
    // Input ending inside a string whose last bytes are a truncated sequence: UTF-8 wins.
    try expect_string_failure("\"\xe2\x82", error.InvalidUtf8, 1, 2);
}

test "string: a fault on a later line reports that line and byte column" {
    try expect_string_failure("[\n  \"ab\xc3(\"]", error.InvalidUtf8, 2, 6);
    try expect_string_failure("{\n\"k\":\n \"a\\q\"}", error.InvalidEscape, 3, 4);
}

test "string: keys follow the same rules as values" {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    var sc: Scanner = undefined;
    try sc.init("{\"k\\u00e9\":1}", .{ .depth_max = 8 });
    _ = try sc.next(&diag);
    const key = try sc.next(&diag);
    try expect(key.kind == .key);
    try expect(key.has_escapes);
    try expectEqualStrings("k\\u00e9", key.raw);
    var out: [16]u8 = undefined;
    try expectEqualStrings("k\xc3\xa9", scanner.decode_string(key.raw, out[0..key.raw.len]));

    try sc.init("{\"k\xff\":1}", .{ .depth_max = 8 });
    _ = try sc.next(&diag);
    try std.testing.expectError(error.InvalidUtf8, sc.next(&diag));
    try expectEqual(@as(u32, 4), diag.col);
}

test "string: a string inside containers keeps the structure intact" {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    var sc: Scanner = undefined;
    try sc.init("[\"a\\n\",\"\\u00e9\"]", .{ .depth_max = 8 });
    const kinds = [_]scanner.Kind{ .array_begin, .string, .string, .array_end, .end };
    for (kinds) |kind| {
        const token = try sc.next(&diag);
        try expect(token.kind == kind);
    }
}

/// Appends the JSON spelling of `codepoint` to `json` and its UTF-8 to `plain`.
fn append_codepoint(
    random: std.Random,
    codepoint: u21,
    json: *std.ArrayList(u8),
    plain: *std.ArrayList(u8),
) !void {
    var utf8: [4]u8 = undefined;
    const len = try core.unicode_escape.encode(codepoint, &utf8);
    try plain.appendSlice(std.testing.allocator, utf8[0..len]);
    const must_escape = codepoint < 0x20 or codepoint == '"' or codepoint == '\\';
    if (!must_escape and random.boolean()) {
        try json.appendSlice(std.testing.allocator, utf8[0..len]);
        return;
    }
    var buf: [12]u8 = undefined;
    if (codepoint >= 0x10000) {
        const offset = codepoint - 0x10000;
        const high: u16 = 0xD800 + @as(u16, @intCast(offset >> 10));
        const low: u16 = 0xDC00 + @as(u16, @intCast(offset & 0x3FF));
        const text = try std.fmt.bufPrint(&buf, "\\u{x:0>4}\\u{x:0>4}", .{ high, low });
        try json.appendSlice(std.testing.allocator, text);
        return;
    }
    const text = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{codepoint});
    try json.appendSlice(std.testing.allocator, text);
}

fn random_codepoint(random: std.Random) u21 {
    const class = random.uintLessThan(u8, 5);
    const value: u21 = switch (class) {
        0 => random.uintLessThan(u21, 0x80),
        1 => random.intRangeAtMost(u21, 0x80, 0x7FF),
        2 => random.intRangeAtMost(u21, 0x800, 0xFFFF),
        3 => random.intRangeAtMost(u21, 0x10000, 0x10FFFF),
        else => random.uintLessThan(u21, 0x20),
    };
    if (value >= 0xD800 and value <= 0xDFFF) return 0xE000;
    return value;
}

test "string: seeded model test, JSON spelling decodes to the generating UTF-8" {
    const gpa = std.testing.allocator;
    for (0..500) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(gpa);

        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(gpa);

        try json.append(gpa, '"');
        for (0..random.uintLessThan(u32, 24)) |_| {
            try append_codepoint(random, random_codepoint(random), &json, &plain);
        }
        try json.append(gpa, '"');

        var diag = Diagnostics.init(0, 0, "untouched", null);
        const token = scan_string_token(json.items, &diag) catch |err| {
            std.log.err("seed {d}: {s} on {any}", .{ seed, @errorName(err), json.items });
            return err;
        };
        const out = try gpa.alloc(u8, token.raw.len);
        defer gpa.free(out);

        const decoded = scanner.decode_string(token.raw, out);
        try std.testing.expectEqualSlices(u8, plain.items, decoded);
        try expectEqual(token.raw.len, json.items.len - 2);
    }
}

fn differential_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [48]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, fuzz_byte_weights);
    const input = try std.testing.allocator.dupe(u8, buf[0..len]);
    defer std.testing.allocator.free(input);

    const oracle = try std.json.validate(std.testing.allocator, input);
    const ours = accepts(input);
    if (oracle != ours) {
        std.log.err("oracle {} ours {} on {any}", .{ oracle, ours, input });
        return error.TestUnexpectedResult;
    }
}

/// Whether the scanner takes all of `input` to `.end`.
fn accepts(input: []const u8) bool {
    var sc: Scanner = undefined;
    sc.init(input, .{ .depth_max = 128 }) catch return false;
    var diag = Diagnostics.init(0, 0, "", null);
    for (0..input.len + 2) |_| {
        const token = sc.next(&diag) catch return false;
        if (token.kind == .end) return true;
    }
    unreachable; // proof: every token consumes a byte, so `.end` comes within len + 2 calls.
}

/// Bytes that build strings and escapes more often than uniform noise would.
const fuzz_byte_weights = blk: {
    const Weight = std.testing.Smith.Weight;
    break :blk std.testing.Smith.baselineWeights(u8) ++ [_]Weight{
        Weight.value(u8, '"', 12),
        Weight.value(u8, '\\', 12),
        Weight.value(u8, 'u', 6),
        Weight.value(u8, 'd', 4),
        Weight.rangeAtMost(u8, '0', '9', 4),
        Weight.rangeAtMost(u8, 'a', 'f', 3),
        Weight.rangeAtMost(u8, 0x00, 0x1F, 2),
        Weight.rangeAtMost(u8, 0x80, 0xBF, 3),
        Weight.rangeAtMost(u8, 0xC2, 0xF4, 3),
    };
};

/// One corpus entry in Smith's `slice` wire format: u32 little-endian length, then the bytes.
fn entry(comptime bytes: []const u8) [4 + bytes.len]u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes[0..bytes.len].*;
}

const differential_corpus = [_][]const u8{
    &entry("\"\""),
    &entry("\"a\""),
    &entry("\"\\n\""),
    &entry("\"\\u0041\""),
    &entry("\"\\ud83d\\ude00\""),
    &entry("\"\\ud83d\""),
    &entry("\"\\ude00\""),
    &entry("\"\\ud83d\\u0041\""),
    &entry("\"\\x\""),
    &entry("\"\\u12\""),
    &entry("\"\n\""),
    &entry("\"\x7f\""),
    &entry("\"\xc3\xa9\""),
    &entry("\"\xc3\""),
    &entry("\"\xed\xa0\x80\""),
    &entry("\"\xf4\x90\x80\x80\""),
    &entry("\"abc"),
    &entry("\"abc\\"),
    &entry("{\"k\":\"v\"}"),
    &entry("[\"a\",\"b\\t\"]"),
    &entry("{\"k\\u00e9\":\"\\/\"}"),
    &entry("{\"k\": \"\xff\"}"),
};

// The seed corpus holds one entry per string-related `ScanError`; only `zig build test --fuzz`
// mutates beyond it.
test "string: fuzz differential against std.json.validate" {
    try std.testing.fuzz({}, differential_one, .{ .corpus = &differential_corpus });
}

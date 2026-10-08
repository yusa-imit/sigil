//! Tests for `json/scanner.zig` structure, literals and numbers (plan 004 item 2).

const std = @import("std");
const core = @import("../core.zig");
const scanner = @import("scanner.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Scanner = scanner.Scanner;
const Kind = scanner.Kind;
const Token = scanner.Token;
const ScanError = scanner.ScanError;
const Diagnostics = core.Diagnostics;

const kinds_max = 512;

/// Scans `input` to `.end` and returns the token kinds, or the first scan error.
fn scan_kinds(
    input: []const u8,
    depth_max: u16,
    out: *[kinds_max]Kind,
    diag: *Diagnostics,
) ScanError!u32 {
    var sc: Scanner = undefined;
    sc.init(input, .{ .depth_max = depth_max }) catch unreachable; // proof: tests are tiny.
    var count: u32 = 0;
    for (0..kinds_max) |_| {
        const token = try sc.next(diag);
        out[count] = token.kind;
        count += 1;
        if (token.kind == .end) return count;
    }
    unreachable; // proof: no test input has more than kinds_max tokens.
}

fn expect_kinds(input: []const u8, expected: []const Kind) !void {
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const count = try scan_kinds(input, 128, &out, &diag);
    try std.testing.expectEqualSlices(Kind, expected, out[0..count]);
    // Success never writes diag.
    try expectEqualStrings("untouched", diag.message());
}

fn expect_failure(input: []const u8, err: ScanError, line: u32, col: u32) !void {
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try std.testing.expectError(err, scan_kinds(input, 128, &out, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(diag.message().len > 0);
    try expect(!std.mem.eql(u8, diag.message(), "untouched"));
    try expect(diag.snippet_text() != null);
}

test "scanner: scalar roots are one token then end" {
    try expect_kinds("true", &.{ .literal_true, .end });
    try expect_kinds("false", &.{ .literal_false, .end });
    try expect_kinds("null", &.{ .literal_null, .end });
    try expect_kinds("0", &.{ .number, .end });
    try expect_kinds("\"s\"", &.{ .string, .end });
    try expect_kinds(" \t\r\n null \n", &.{ .literal_null, .end });
}

test "scanner: empty containers" {
    try expect_kinds("{}", &.{ .object_begin, .object_end, .end });
    try expect_kinds("[]", &.{ .array_begin, .array_end, .end });
    try expect_kinds("[ ]", &.{ .array_begin, .array_end, .end });
    try expect_kinds("{ \n}", &.{ .object_begin, .object_end, .end });
}

test "scanner: object members yield key then value" {
    try expect_kinds(
        "{\"a\":1,\"b\":[true,null],\"c\":{}}",
        &.{
            .object_begin, .key,          .number,    .key, .array_begin,
            .literal_true, .literal_null, .array_end, .key, .object_begin,
            .object_end,   .object_end,   .end,
        },
    );
    try expect_kinds(" { \"a\" : 1 , \"b\" : 2 } ", &.{
        .object_begin, .key, .number, .key, .number, .object_end, .end,
    });
}

test "scanner: arrays of mixed values" {
    try expect_kinds("[1, \"x\", false, [], {}]", &.{
        .array_begin, .number,       .string,     .literal_false, .array_begin,
        .array_end,   .object_begin, .object_end, .array_end,     .end,
    });
}

test "scanner: tokens carry offset and raw slices of the input" {
    const input = "  [12, true, \"ab\", {\"k\": null}]";
    var sc: Scanner = undefined;
    try sc.init(input, .{ .depth_max = 8 });
    var diag = Diagnostics.init(0, 0, "", null);

    const open = try sc.next(&diag);
    try expectEqual(Kind.array_begin, open.kind);
    try expectEqual(@as(u32, 2), open.offset);
    try expectEqualStrings("[", open.raw);

    const number = try sc.next(&diag);
    try expectEqual(@as(u32, 3), number.offset);
    try expectEqualStrings("12", number.raw);
    try expect(!number.has_escapes);

    const lit = try sc.next(&diag);
    try expectEqual(@as(u32, 7), lit.offset);
    try expectEqualStrings("true", lit.raw);

    const str = try sc.next(&diag);
    try expectEqual(Kind.string, str.kind);
    // The offset is the opening quote; raw is between the quotes.
    try expectEqual(@as(u32, 13), str.offset);
    try expectEqualStrings("ab", str.raw);
    try expect(str.raw.ptr == input.ptr + 14);

    _ = try sc.next(&diag); // {
    const key = try sc.next(&diag);
    try expectEqual(Kind.key, key.kind);
    try expectEqualStrings("k", key.raw);
    _ = try sc.next(&diag); // null
    _ = try sc.next(&diag); // }
    _ = try sc.next(&diag); // ]
    const end = try sc.next(&diag);
    try expectEqual(Kind.end, end.kind);
    try expectEqual(@as(u32, input.len), end.offset);
    try expectEqual(@as(usize, 0), end.raw.len);
}

test "scanner: valid numbers keep their exact text" {
    const valid = [_][]const u8{
        "0",    "-0",   "1",      "-1",       "10",  "123456789012345678901234567890",
        "0.5",  "-0.5", "0.0",    "1.25",     "1e5", "1E5",
        "1e+5", "1e-5", "1.5e10", "-1.5E-10", "0e0", "0.0e+0",
    };
    for (valid) |text| {
        var sc: Scanner = undefined;
        try sc.init(text, .{ .depth_max = 4 });
        var diag = Diagnostics.init(0, 0, "", null);
        const token = try sc.next(&diag);
        try expectEqual(Kind.number, token.kind);
        try expectEqualStrings(text, token.raw);
        try expectEqual(Kind.end, (try sc.next(&diag)).kind);
    }
}

test "scanner: a number is judged whole, never a valid prefix plus trailing data" {
    const invalid = [_][]const u8{
        "01",  "-01", "+1",    ".5",    "1.", "-",   "1e",  "1e+", "1e-",       "1.e5",
        "--1", "1-",  "1e5e5", "1.5.5", "00", "-.5", "1+1", "1E",  "-Infinity",
    };
    for (invalid) |text| {
        try expect_failure(text, error.InvalidNumber, 1, 1);
    }
    // Inside a container, the offset is the number's own first byte.
    try expect_failure("[1,\n 01]", error.InvalidNumber, 2, 2);
}

test "scanner: depth_max containers pass, one more is TooDeep at its bracket" {
    const depth: u16 = 128;
    const open = "[" ** (depth + 1);
    const close = "]" ** depth;
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "", null);

    // 128 nested arrays: accepted.
    const count = try scan_kinds(open[0..depth] ++ close, depth, &out, &diag);
    try expectEqual(@as(u32, 2 * depth + 1), count);

    // 129: the 129th `[` is the failing byte.
    try std.testing.expectError(error.TooDeep, scan_kinds(open, depth, &out, &diag));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 129), diag.col);
}

test "scanner: depth_max of 1 allows one container and objects count too" {
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    _ = try scan_kinds("[1]", 1, &out, &diag);
    try std.testing.expectError(error.TooDeep, scan_kinds("[[]]", 1, &out, &diag));
    try expectEqual(@as(u32, 2), diag.col);
    try std.testing.expectError(error.TooDeep, scan_kinds("{\"a\":{}}", 1, &out, &diag));
    try expectEqual(@as(u32, 6), diag.col);
    // Siblings are not nesting.
    _ = try scan_kinds("[[],[]]", 2, &out, &diag);
}

test "scanner: empty and whitespace-only input are UnexpectedEnd at input.len" {
    try expect_failure("", error.UnexpectedEnd, 1, 1);
    try expect_failure("  \n\n  ", error.UnexpectedEnd, 3, 3);
}

test "scanner: truncation is UnexpectedEnd on multi-line input" {
    try expect_failure("[1,\n 2,\n", error.UnexpectedEnd, 3, 1);
    try expect_failure("{\"a\":\n", error.UnexpectedEnd, 2, 1);
    try expect_failure("{\"a\"", error.UnexpectedEnd, 1, 5);
    try expect_failure("{", error.UnexpectedEnd, 1, 2);
    try expect_failure("[1", error.UnexpectedEnd, 1, 3);
    try expect_failure("tru", error.UnexpectedEnd, 1, 4);
    try expect_failure("\"abc", error.UnexpectedEnd, 1, 5);
    try expect_failure("[\"a\\", error.UnexpectedEnd, 1, 5);
}

test "scanner: trailing data after the root value" {
    try expect_failure("1 2", error.TrailingData, 1, 3);
    try expect_failure("{}\n\n  x", error.TrailingData, 3, 3);
    try expect_failure("[]]", error.TrailingData, 1, 3);
    try expect_failure("null,", error.TrailingData, 1, 5);
    try expect_failure("\"a\"\"b\"", error.TrailingData, 1, 4);
}

test "scanner: bytes the grammar forbids are UnexpectedToken at that byte" {
    try expect_failure("[1,]", error.UnexpectedToken, 1, 4);
    try expect_failure("[,1]", error.UnexpectedToken, 1, 2);
    try expect_failure("[1 2]", error.UnexpectedToken, 1, 4);
    try expect_failure("{,}", error.UnexpectedToken, 1, 2);
    try expect_failure("{\"a\":1,}", error.UnexpectedToken, 1, 8);
    try expect_failure("{\"a\" 1}", error.UnexpectedToken, 1, 6);
    try expect_failure("{\"a\":}", error.UnexpectedToken, 1, 6);
    try expect_failure("{1:2}", error.UnexpectedToken, 1, 2);
    try expect_failure("{\"a\":1 \"b\":2}", error.UnexpectedToken, 1, 8);
    try expect_failure("[1}", error.UnexpectedToken, 1, 3);
    try expect_failure("{\"a\":1]", error.UnexpectedToken, 1, 7);
    try expect_failure("]", error.UnexpectedToken, 1, 1);
    try expect_failure("[}", error.UnexpectedToken, 1, 2);
    try expect_failure(":", error.UnexpectedToken, 1, 1);
}

test "scanner: no extensions to RFC 8259" {
    try expect_failure("// c\n1", error.UnexpectedToken, 1, 1);
    try expect_failure("/* c */ 1", error.UnexpectedToken, 1, 1);
    try expect_failure("'a'", error.UnexpectedToken, 1, 1);
    try expect_failure("{a:1}", error.UnexpectedToken, 1, 2);
    try expect_failure("NaN", error.UnexpectedToken, 1, 1);
    try expect_failure("Infinity", error.UnexpectedToken, 1, 1);
    try expect_failure("\x0b1", error.UnexpectedToken, 1, 1);
    try expect_failure("\xc2\xa01", error.UnexpectedToken, 1, 1);
    try expect_failure("\xef\xbb\xbf{}", error.UnexpectedToken, 1, 1);
}

test "scanner: a BOM names itself in the message" {
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    const input = "\xef\xbb\xbf{}";
    try std.testing.expectError(error.UnexpectedToken, scan_kinds(input, 128, &out, &diag));
    try expect(std.mem.find(u8, diag.message(), "byte order mark") != null);
}

test "scanner: literals must be spelt exactly" {
    try expect_failure("True", error.UnexpectedToken, 1, 1);
    try expect_failure("nul", error.UnexpectedEnd, 1, 4);
    try expect_failure("nulL", error.UnexpectedToken, 1, 1);
    try expect_failure("[falsy]", error.UnexpectedToken, 1, 2);
    try expect_failure("truee", error.TrailingData, 1, 5);
    try expect_failure("[truee]", error.UnexpectedToken, 1, 6);
}

test "scanner: the diagnostic carries the failing line as snippet" {
    var out: [kinds_max]Kind = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    const input = "{\n  \"a\": 1,\n  ]\n}";
    try std.testing.expectError(error.UnexpectedToken, scan_kinds(input, 128, &out, &diag));
    try expectEqual(@as(u32, 3), diag.line);
    try expectEqual(@as(u32, 3), diag.col);
    try expectEqualStrings("  ]", diag.snippet_text().?);
}

test "scanner: string tokens report escapes and end at the first unescaped quote" {
    const input = "[\"plain\", \"a\\\"b\", \"\\\\\", \"\"]";
    var sc: Scanner = undefined;
    try sc.init(input, .{ .depth_max = 4 });
    var diag = Diagnostics.init(0, 0, "", null);
    _ = try sc.next(&diag);

    const plain = try sc.next(&diag);
    try expectEqualStrings("plain", plain.raw);
    try expect(!plain.has_escapes);

    const quote = try sc.next(&diag);
    try expectEqualStrings("a\\\"b", quote.raw);
    try expect(quote.has_escapes);

    // An escaped backslash right before the closing quote does not escape the quote.
    const backslash = try sc.next(&diag);
    try expectEqualStrings("\\\\", backslash.raw);
    try expect(backslash.has_escapes);

    const empty = try sc.next(&diag);
    try expectEqual(Kind.string, empty.kind);
    try expectEqual(@as(usize, 0), empty.raw.len);
    try expect(!empty.has_escapes);
    try expectEqual(Kind.array_end, (try sc.next(&diag)).kind);

    var key_sc: Scanner = undefined;
    try key_sc.init("{\"k\\n\":0}", .{ .depth_max = 4 });
    _ = try key_sc.next(&diag);
    const key = try key_sc.next(&diag);
    try expectEqual(Kind.key, key.kind);
    try expect(key.has_escapes);
}

test "scanner: init returns InputTooLarge above maxInt(u32)" {
    // A slice header with a length past maxInt(u32); the bytes are never read.
    const len = @as(usize, std.math.maxInt(u32)) + 1;
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(4096))[0..len];
    var sc: Scanner = undefined;
    try std.testing.expectError(error.InputTooLarge, sc.init(huge, .{ .depth_max = 1 }));
}

test "scanner: a Scanner is a plain value, a copy is a snapshot" {
    var sc: Scanner = undefined;
    try sc.init("[1,2]", .{ .depth_max = 4 });
    var diag = Diagnostics.init(0, 0, "", null);
    _ = try sc.next(&diag);
    var snapshot = sc;
    const first = try sc.next(&diag);
    const replay = try snapshot.next(&diag);
    try expectEqual(first.offset, replay.offset);
    try expectEqualStrings(first.raw, replay.raw);
    comptime std.debug.assert(@sizeOf(Scanner) <= 64);
}

const Generated = struct { len: usize, tokens: u32 };

fn put(buffer: []u8, len: *usize, text: []const u8) void {
    @memcpy(buffer[len.*..][0..text.len], text);
    len.* += text.len;
}

/// A random valid document, nested at most 6 deep, with the number of tokens it must yield.
fn generate(random: std.Random, buffer: []u8) Generated {
    const nesting_test_max = 6;
    var is_object: [nesting_test_max]bool = undefined;
    var depth: u32 = 0;
    var len: usize = 0;
    var tokens: u32 = 0;
    var just_opened = false;
    var root_done = false;
    for (0..48) |_| {
        if (root_done and depth == 0) break;
        if (depth > 0 and random.uintLessThan(u8, 3) == 0) {
            depth -= 1;
            put(buffer, &len, if (is_object[depth]) "}" else "]");
            tokens += 1;
            just_opened = false;
            continue;
        }
        if (depth > 0 and !just_opened) put(buffer, &len, ", ");
        if (depth > 0 and is_object[depth - 1]) {
            put(buffer, &len, "\"k\" : ");
            tokens += 1;
        }
        root_done = true;
        just_opened = false;
        tokens += 1;
        if (depth < nesting_test_max and random.boolean()) {
            is_object[depth] = random.boolean();
            put(buffer, &len, if (is_object[depth]) "{" else "[");
            depth += 1;
            just_opened = true;
        } else {
            const scalars = [_][]const u8{ "-12.5e3", "null", "true", "false", "\"s\\\"x\"" };
            put(buffer, &len, scalars[random.uintLessThan(usize, scalars.len)]);
        }
    }
    while (depth > 0) {
        depth -= 1;
        put(buffer, &len, if (is_object[depth]) "}" else "]");
        tokens += 1;
    }
    return .{ .len = len, .tokens = tokens };
}

test "scanner: a model over random documents agrees on token count" {
    var prng = std.Random.DefaultPrng.init(0x5163);
    for (0..500) |seed_index| {
        var buffer: [1024]u8 = undefined;
        const generated = generate(prng.random(), &buffer);
        const input = buffer[0..generated.len];
        var out: [kinds_max]Kind = undefined;
        var diag = Diagnostics.init(0, 0, "", null);
        const count = scan_kinds(input, 128, &out, &diag) catch |err| {
            const name = @errorName(err);
            std.log.err("seed_index={d} err={s} input={s}", .{ seed_index, name, input });
            return err;
        };
        // One extra token: `.end`.
        try expectEqual(generated.tokens + 1, count);

        // Negative space: a proper prefix of a container document is never accepted.
        if (input[0] == '[' or input[0] == '{') {
            for (0..input.len) |prefix_len| {
                const result = scan_kinds(input[0..prefix_len], 128, &out, &diag);
                if (result) |_| {
                    const prefix = input[0..prefix_len];
                    std.log.err("seed_index={d} prefix accepted: {s}", .{ seed_index, prefix });
                    return error.TestUnexpectedResult;
                } else |_| {}
            }
        }
    }
}

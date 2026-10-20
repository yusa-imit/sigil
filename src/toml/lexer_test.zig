//! Tests for `toml/lexer.zig` structure and strings (plan 006 item 3).

const std = @import("std");
const core = @import("../core.zig");
const lexer_module = @import("lexer.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Lexer = lexer_module.Lexer;
const Kind = lexer_module.Kind;
const Mode = lexer_module.Mode;
const ScanError = lexer_module.ScanError;
const Diagnostics = core.Diagnostics;

const tokens_max = 64;

const Step = struct { mode: Mode, kind: Kind, raw: []const u8 };

fn step(mode: Mode, kind: Kind, raw: []const u8) Step {
    return .{ .mode = mode, .kind = kind, .raw = raw };
}

/// Lexes `input` with the scripted modes and checks kind and raw of every token.
fn expect_steps(input: []const u8, steps: []const Step) !void {
    var lexer: Lexer = undefined;
    try lexer.init(input);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    for (steps) |expected| {
        const token = try lexer.next(&diag, expected.mode);
        try expectEqual(expected.kind, token.kind);
        try expectEqualStrings(expected.raw, token.raw);
    }
    try expectEqualStrings("untouched", diag.message());
}

/// Lexes `input` in one fixed `mode` until `.end` or the first error.
fn lex_all(input: []const u8, mode: Mode, diag: *Diagnostics) ScanError!u32 {
    var lexer: Lexer = undefined;
    lexer.init(input) catch unreachable; // proof: tests are tiny.
    for (0..tokens_max) |count| {
        const token = try lexer.next(diag, mode);
        if (token.kind == .end) return @intCast(count);
    }
    unreachable; // proof: no test input has more than tokens_max tokens.
}

fn expect_failure(input: []const u8, mode: Mode, err: ScanError, line: u32, col: u32) !void {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    try std.testing.expectError(err, lex_all(input, mode, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(diag.message().len > 0);
    try expect(!std.mem.eql(u8, diag.message(), "untouched"));
}

/// Lexes one string token and returns its decoded text in `out`.
fn decode_one(input: []const u8, kind: Kind, out: []u8) ![]u8 {
    var lexer: Lexer = undefined;
    try lexer.init(input);
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const token = try lexer.next(&diag, .value);
    try expectEqual(kind, token.kind);
    try expectEqual(@as(u32, 0), token.offset);
    const end = try lexer.next(&diag, .value);
    try expectEqual(Kind.end, end.kind);
    return lexer_module.decode_string(kind, token.raw, out);
}

fn expect_decoded(input: []const u8, kind: Kind, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const decoded = try decode_one(input, kind, &out);
    try expectEqualStrings(expected, decoded);
}

test "lexer: a table-array header, a key/value line and a comment" {
    const input = "[[a.b]]\nk = \"v\" # note\r\n";
    try expect_steps(input, &.{
        step(.key, .table_array_open, "[["),
        step(.key, .bare_key, "a"),
        step(.key, .dot, "."),
        step(.key, .bare_key, "b"),
        step(.key, .table_array_close, "]]"),
        step(.key, .newline, "\n"),
        step(.key, .bare_key, "k"),
        step(.key, .equals, "="),
        step(.value, .string_basic, "v"),
        step(.key, .newline, "\r\n"),
        step(.key, .end, ""),
    });
}

test "lexer: brackets are single unless adjacent in key mode" {
    try expect_steps("[[", &.{ step(.key, .table_array_open, "[["), step(.key, .end, "") });
    try expect_steps("[ [", &.{
        step(.key, .bracket_open, "["),
        step(.key, .bracket_open, "["),
        step(.key, .end, ""),
    });
    try expect_steps("[[", &.{
        step(.value, .bracket_open, "["),
        step(.value, .bracket_open, "["),
        step(.value, .end, ""),
    });
    try expect_steps("]]", &.{ step(.key, .table_array_close, "]]"), step(.key, .end, "") });
    try expect_steps("] ]", &.{
        step(.key, .bracket_close, "]"),
        step(.key, .bracket_close, "]"),
        step(.key, .end, ""),
    });
    try expect_steps("]]", &.{
        step(.value, .bracket_close, "]"),
        step(.value, .bracket_close, "]"),
        step(.value, .end, ""),
    });
}

test "lexer: inline table and array punctuation" {
    try expect_steps("{ a = 1, b = [2] }", &.{
        step(.key, .brace_open, "{"),
        step(.key, .bare_key, "a"),
        step(.key, .equals, "="),
        step(.value, .scalar, "1"),
        step(.value, .comma, ","),
        step(.key, .bare_key, "b"),
        step(.key, .equals, "="),
        step(.value, .bracket_open, "["),
        step(.value, .scalar, "2"),
        step(.value, .bracket_close, "]"),
        step(.value, .brace_close, "}"),
        step(.key, .end, ""),
    });
}

test "lexer: key mode splits at dots, value mode keeps them in one run" {
    try expect_steps("a.b-c_1", &.{
        step(.key, .bare_key, "a"),
        step(.key, .dot, "."),
        step(.key, .bare_key, "b-c_1"),
        step(.key, .end, ""),
    });
    try expect_steps("1.5e3 .5 +inf 1979-05-27 07:32:00Z", &.{
        step(.value, .scalar, "1.5e3"),
        step(.value, .scalar, ".5"),
        step(.value, .scalar, "+inf"),
        step(.value, .scalar, "1979-05-27"),
        step(.value, .scalar, "07:32:00Z"),
        step(.value, .end, ""),
    });
    try expect_steps("\"a b\".'c'", &.{
        step(.key, .string_basic, "a b"),
        step(.key, .dot, "."),
        step(.key, .string_literal, "c"),
        step(.key, .end, ""),
    });
}

test "lexer: a scalar run stops at a delimiter and a comment" {
    try expect_steps("x#c\ny,z]w}", &.{
        step(.value, .scalar, "x"),
        step(.value, .newline, "\n"),
        step(.value, .scalar, "y"),
        step(.value, .comma, ","),
        step(.value, .scalar, "z"),
        step(.value, .bracket_close, "]"),
        step(.value, .scalar, "w"),
        step(.value, .brace_close, "}"),
        step(.value, .end, ""),
    });
}

test "lexer: empty input and blank-only input are just .end" {
    try expect_steps("", &.{step(.key, .end, "")});
    try expect_steps("  \t # only a comment", &.{step(.value, .end, "")});
}

test "lexer: the string examples of the TOML 1.0.0 specification" {
    try expect_decoded(
        "\"I'm a string. \\\"You can quote me\\\". Name\\tJos\\u00E9\\nLocation\\tSF.\"",
        .string_basic,
        "I'm a string. \"You can quote me\". Name\tJos\u{e9}\nLocation\tSF.",
    );
    try expect_decoded(
        "\"\"\"\nRoses are red\nViolets are blue\"\"\"",
        .string_basic_multiline,
        "Roses are red\nViolets are blue",
    );
    try expect_decoded(
        "\"\"\"\\\n  The quick brown \\\n\n\n  fox jumps over \\\n    the lazy dog.\\\n  \"\"\"",
        .string_basic_multiline,
        "The quick brown fox jumps over the lazy dog.",
    );
    try expect_decoded(
        "\"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"",
        .string_basic_multiline,
        "Here are two quotation marks: \"\". Simple enough.",
    );
    try expect_decoded(
        "\"\"\"Here are three quotation marks: \"\"\\\".\"\"\"",
        .string_basic_multiline,
        "Here are three quotation marks: \"\"\".",
    );
    try expect_decoded(
        "\"\"\"\"This,\" she said, \"is just a pointless statement.\"\"\"\"",
        .string_basic_multiline,
        "\"This,\" she said, \"is just a pointless statement.\"",
    );
    try expect_decoded(
        "'C:\\Users\\nodejs\\templates'",
        .string_literal,
        "C:\\Users\\nodejs\\templates",
    );
    try expect_decoded(
        "'''\nThe first newline is\ntrimmed in raw strings.\n   All other whitespace\n" ++
            "   is preserved.\n'''",
        .string_literal_multiline,
        "The first newline is\ntrimmed in raw strings.\n   All other whitespace\n" ++
            "   is preserved.\n",
    );
    try expect_decoded(
        "'''Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"'''",
        .string_literal_multiline,
        "Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
    );
    try expect_decoded(
        "''''That,' she said, 'is still pointless.''''",
        .string_literal_multiline,
        "'That,' she said, 'is still pointless.'",
    );
}

test "lexer: empty strings, escapes of every width and CRLF bodies" {
    try expect_decoded("\"\"", .string_basic, "");
    try expect_decoded("''", .string_literal, "");
    try expect_decoded("\"\"\"\"\"\"", .string_basic_multiline, "");
    try expect_decoded("''''''", .string_literal_multiline, "");
    try expect_decoded("\"\\u00e9\\u20AC\\U0001F600\"", .string_basic, "\u{e9}\u{20ac}\u{1f600}");
    try expect_decoded("\"\\b\\t\\n\\f\\r\\\"\\\\\"", .string_basic, "\x08\t\n\x0c\r\"\\");
    try expect_decoded("\"a\tb\"", .string_basic, "a\tb");
    try expect_decoded("\"\"\"\r\na\r\nb\"\"\"", .string_basic_multiline, "a\r\nb");
    try expect_decoded("\"\"\"a \\\r\n   b\"\"\"", .string_basic_multiline, "a b");
    try expect_decoded("\"\"\"a \\   \n b\"\"\"", .string_basic_multiline, "a b");
    try expect_decoded("'a\\n'", .string_literal, "a\\n");
    try expect_decoded("\"\\U0010FFFF\\u0000\"", .string_basic, "\u{10ffff}\x00");
}

test "lexer: has_escapes marks a backslash in a basic string only" {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const cases = [_]struct { input: []const u8, flag: bool }{
        .{ .input = "\"abc\"", .flag = false },
        .{ .input = "\"a\\nc\"", .flag = true },
        .{ .input = "'a\\nc'", .flag = false },
        .{ .input = "\"\"\"a\\\nb\"\"\"", .flag = true },
        .{ .input = "'''a\\\nb'''", .flag = false },
    };
    for (cases) |case| {
        var lexer: Lexer = undefined;
        try lexer.init(case.input);
        const token = try lexer.next(&diag, .value);
        try expectEqual(case.flag, token.has_escapes);
    }
}

test "lexer: a multi-line closing run takes up to two quotes into the body" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "\"\"\"a\"\"\"", .expected = "a" },
        .{ .input = "\"\"\"a\"\"\"\"", .expected = "a\"" },
        .{ .input = "\"\"\"a\"\"\"\"\"", .expected = "a\"\"" },
        .{ .input = "'''a''''", .expected = "a'" },
        .{ .input = "'''a'''''", .expected = "a''" },
    };
    for (cases) |case| {
        var out: [16]u8 = undefined;
        const kind: Kind = if (case.input[0] == '"')
            .string_basic_multiline
        else
            .string_literal_multiline;
        const decoded = try decode_one(case.input, kind, &out);
        try expectEqualStrings(case.expected, decoded);
    }
    try expect_failure("\"\"\"a\"\"\"\"\"\"", .value, error.UnexpectedToken, 1, 10);
    try expect_failure("'''a''''''", .value, error.UnexpectedToken, 1, 10);
}

test "lexer: every scan error is provoked with its line and column" {
    // UnexpectedEnd
    try expect_failure("\"abc", .value, error.UnexpectedEnd, 1, 5);
    try expect_failure("'''abc\n", .value, error.UnexpectedEnd, 2, 1);
    try expect_failure("\"\"\"a\\", .value, error.UnexpectedEnd, 1, 6);
    // UnexpectedToken
    try expect_failure("a\rb", .key, error.UnexpectedToken, 1, 2);
    try expect_failure("\xEF\xBB\xBFa = 1", .key, error.UnexpectedToken, 1, 1);
    try expect_failure("$", .key, error.UnexpectedToken, 1, 1);
    try expect_failure("a\n\xC3\xA9", .key, error.UnexpectedToken, 2, 1);
    try expect_failure("ab\xC3\xA9", .value, error.UnexpectedToken, 1, 3);
    try expect_failure("\"\"\"a\\  \t", .value, error.UnexpectedEnd, 1, 9);
    // InvalidEscape
    try expect_failure("\"a\\xb\"", .value, error.InvalidEscape, 1, 3);
    try expect_failure("\"\\e\"", .value, error.InvalidEscape, 1, 2);
    try expect_failure("\"\\u12\"", .value, error.InvalidEscape, 1, 2);
    try expect_failure("\"\\u12G4\"", .value, error.InvalidEscape, 1, 2);
    try expect_failure("\"\\U0011FFFF\"", .value, error.InvalidEscape, 1, 2);
    try expect_failure("\"\"\"a\\ b\"\"\"", .value, error.InvalidEscape, 1, 5);
    try expect_failure("\"a\\ b\"", .value, error.InvalidEscape, 1, 3);
    // LoneSurrogate
    try expect_failure("\"\\uD800\"", .value, error.LoneSurrogate, 1, 2);
    try expect_failure("\"x\\uDFFF\"", .value, error.LoneSurrogate, 1, 3);
    try expect_failure("\"\\U0000D800\"", .value, error.LoneSurrogate, 1, 2);
    try expect_failure("\"\\uD83D\\uDE00\"", .value, error.LoneSurrogate, 1, 2);
    // ControlCharacter
    try expect_failure("\"a\nb\"", .value, error.ControlCharacter, 1, 3);
    try expect_failure("\"a\x7f\"", .value, error.ControlCharacter, 1, 3);
    try expect_failure("'a\x00'", .value, error.ControlCharacter, 1, 3);
    try expect_failure("\"\"\"a\rb\"\"\"", .value, error.ControlCharacter, 1, 5);
    try expect_failure("# a\x01", .value, error.ControlCharacter, 1, 4);
    try expect_failure("a=1\n# bad\x00", .value, error.ControlCharacter, 2, 6);
    try expect_failure("# a\rb\n", .value, error.ControlCharacter, 1, 4);
    // InvalidUtf8
    try expect_failure("\"a\xffb\"", .value, error.InvalidUtf8, 1, 3);
    try expect_failure("\"a\xe2\x82", .value, error.InvalidUtf8, 1, 3);
    try expect_failure("'''\xC0\x80'''", .value, error.InvalidUtf8, 1, 4);
    try expect_failure("# \xff", .value, error.InvalidUtf8, 1, 3);
}

test "lexer: the earliest fault of a string wins" {
    try expect_failure("\"\xff\\q\"", .value, error.InvalidUtf8, 1, 2);
    try expect_failure("\"\\q\xff\"", .value, error.InvalidEscape, 1, 2);
    try expect_failure("\"\xff\n\"", .value, error.InvalidUtf8, 1, 2);
    try expect_failure("\"\n\xff\"", .value, error.ControlCharacter, 1, 2);
    try expect_failure("# \xff\x01", .value, error.InvalidUtf8, 1, 3);
}

test "lexer: a tab is data in strings and comments, a literal backslash is not an escape" {
    try expect_steps("\"a\tb\" # c\td\n'\\'", &.{
        step(.value, .string_basic, "a\tb"),
        step(.value, .newline, "\n"),
        step(.value, .string_literal, "\\"),
        step(.value, .end, ""),
    });
}

test "lexer: init refuses input longer than maxInt(u32)" {
    const base: [*]const u8 = @ptrFromInt(8);
    var lexer: Lexer = undefined;
    // `init` reads only the length, so a slice that is never dereferenced probes the boundary.
    try lexer.init(base[0..Lexer.input_len_max]);
    try std.testing.expectError(
        error.InputTooLarge,
        lexer.init(base[0 .. @as(usize, Lexer.input_len_max) + 1]),
    );
    const huge = base[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectError(error.InputTooLarge, lexer.init(huge));
}

test "lexer: ScanError has the six variants of ADR 0005 section 6" {
    const names = @typeInfo(ScanError).error_set.?;
    try expectEqual(@as(usize, 6), names.len);
    inline for (.{
        "UnexpectedEnd", "UnexpectedToken",  "InvalidEscape",
        "LoneSurrogate", "ControlCharacter", "InvalidUtf8",
    }) |name| {
        var found = false;
        for (names) |entry| found = found or std.mem.eql(u8, entry.name, name);
        try expect(found);
    }
}

const model_seeds = 500;
const codepoints_max = 24;

/// Appends `codepoint` to `body` as raw UTF-8 or as an escape, and to `expected` as UTF-8.
fn model_append(
    random: std.Random,
    codepoint: u21,
    body: *std.ArrayList(u8),
    expected: *std.ArrayList(u8),
    escaped: *bool,
) !void {
    var encoded = [_]u8{0} ** 4;
    const len = try core.unicode_escape.encode(codepoint, &encoded);
    try expected.appendSlice(std.testing.allocator, encoded[0..len]);
    const needs_escape = codepoint == '"' or codepoint == '\\' or codepoint < 0x20 or
        codepoint == 0x7f;
    if (!needs_escape and random.boolean()) {
        try body.appendSlice(std.testing.allocator, encoded[0..len]);
        return;
    }
    escaped.* = true;
    const text = if (codepoint <= 0xFFFF)
        try std.fmt.allocPrint(std.testing.allocator, "\\u{X:0>4}", .{codepoint})
    else
        try std.fmt.allocPrint(std.testing.allocator, "\\U{X:0>8}", .{codepoint});
    defer std.testing.allocator.free(text);

    try body.appendSlice(std.testing.allocator, text);
}

fn model_codepoint(random: std.Random) u21 {
    return switch (random.uintLessThan(u8, 5)) {
        0 => random.intRangeAtMost(u21, 0x20, 0x7e),
        1 => random.intRangeAtMost(u21, 0x00, 0x1f),
        2 => random.intRangeAtMost(u21, 0x80, 0x7ff),
        3 => random.intRangeAtMost(u21, 0xe000, 0xfffd),
        else => random.intRangeAtMost(u21, 0x10000, 0x10ffff),
    };
}

test "lexer: model — random escaped strings decode to the generated text, 500 seeds" {
    const gpa = std.testing.allocator;
    var escaped_seen: u32 = 0;
    for (0..model_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);

        var escaped = false;
        const count = random.uintLessThan(u32, codepoints_max + 1);
        for (0..count) |_| {
            try model_append(random, model_codepoint(random), &body, &expected, &escaped);
        }
        if (escaped) escaped_seen += 1;

        const single = try std.fmt.allocPrint(gpa, "\"{s}\"", .{body.items});
        defer gpa.free(single);

        const multi = try std.fmt.allocPrint(gpa, "\"\"\"\n{s}\"\"\"", .{body.items});
        defer gpa.free(multi);

        var out: [codepoints_max * 10 + 8]u8 = undefined;
        const from_single = try decode_one(single, .string_basic, &out);
        try expectEqualStrings(expected.items, from_single);
        const from_multi = try decode_one(multi, .string_basic_multiline, &out);
        try expectEqualStrings(expected.items, from_multi);
    }
    // The generator reaches escapes in most seeds; a regression to raw-only output would pass
    // every comparison above without testing the decoder.
    try expect(escaped_seen > model_seeds / 2);
}

// Every prefix of these documents must lex to a typed error or to success, in both modes.
test "lexer: every prefix of a valid document fails with a typed error or succeeds" {
    const corpus = [_][]const u8{
        "a = \"x\\u00e9\\U0001F600\\n\" # c\r\n[[t.u]]\n",
        "k = '''l1\nl2''' # c\n",
        "k = \"\"\"a \\  \r\n  b\"\"\"\n",
        "{ a = 'x', b = [ \"y\" ] }\r\n",
    };
    var diag = Diagnostics.init(0, 0, "untouched", null);
    for (corpus) |document| {
        for (0..document.len + 1) |len| {
            inline for (.{ Mode.key, Mode.value }) |mode| {
                // proof: `ScanError` holds no I/O error, so `error.Canceled` cannot occur.
                if (lex_all(document[0..len], mode, &diag)) |_| {} else |err| switch (err) {
                    error.UnexpectedEnd,
                    error.UnexpectedToken,
                    error.InvalidEscape,
                    error.LoneSurrogate,
                    error.ControlCharacter,
                    error.InvalidUtf8,
                    => {},
                }
            }
        }
    }
    // The whole documents lex cleanly in value mode.
    var clean = Diagnostics.init(0, 0, "untouched", null);
    for (corpus) |document| try expect(try lex_all(document, .value, &clean) > 0);
    try expectEqualStrings("untouched", clean.message());
}

test "lexer: decode_string works when the output is exactly as long as the raw body" {
    var out: [6]u8 = undefined;
    const decoded = try decode_one("\"\\u00e9\"", .string_basic, &out);
    try expectEqualStrings("\u{e9}", decoded);
    var tight: [8]u8 = undefined;
    const mixed = try decode_one("\"\\u0041\\n\"", .string_basic, &tight);
    try expectEqualStrings("A\n", mixed);
}

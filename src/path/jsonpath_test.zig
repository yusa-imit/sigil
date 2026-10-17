//! Tests for `path/jsonpath.zig` parse (plan 005 item 5): the RFC 9535 section 2 grammar as a
//! table of queries and their canonical rendering, every `QueryError` variant with the column it
//! reports, the boundary at each `_max`, string escapes, and a seeded model that generates a
//! query and its expected rendering together. Rendering is `$` then each segment as `..`? and a
//! bracket list: names `'x'` (decoded bytes), indices, `*`, slices `start:end:step` with absent
//! start/end left empty and the step always written.

const std = @import("std");
const core = @import("../core.zig");
const jsonpath = @import("jsonpath.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Diagnostics = core.Diagnostics;
const Program = jsonpath.Program;
const QueryError = jsonpath.QueryError;

fn blank_diag() Diagnostics {
    return Diagnostics.init(0, 0, "", null);
}

fn render(program: *const Program, w: *std.Io.Writer) !void {
    try w.writeByte('$');
    for (program.segment_list()) |segment| {
        if (segment.descendant) try w.writeAll("..");
        try w.writeByte('[');
        for (program.selector_list(segment), 0..) |selector, index| {
            if (index > 0) try w.writeByte(',');
            switch (selector) {
                .name => |name| try w.print("'{s}'", .{program.name_text(name)}),
                .index => |value| try w.print("{d}", .{value}),
                .wildcard => try w.writeByte('*'),
                .filter => |id| try w.print("?{d}", .{id}),
                .slice => |slice| {
                    if (slice.start) |start| try w.print("{d}", .{start});
                    try w.writeByte(':');
                    if (slice.end) |end| try w.print("{d}", .{end});
                    try w.print(":{d}", .{slice.step});
                },
            }
        }
        try w.writeByte(']');
    }
}

/// Compiles `query` from a heap copy that is freed before rendering, proving the program
/// borrows nothing from the text, and compares the rendering with `expected`.
fn expect_compiles(query: []const u8, expected: []const u8) !void {
    const copy = try std.testing.allocator.dupe(u8, query);
    var program: Program = undefined;
    var diag = blank_diag();
    jsonpath.compile(&program, copy, &diag) catch |err| {
        std.testing.allocator.free(copy);
        std.log.err("query '{s}' failed with {s}: {f}", .{ query, @errorName(err), &diag });
        return err;
    };
    std.testing.allocator.free(copy);
    program.check_invariants();
    try expectEqual(@as(u32, 0), diag.line);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&program, &out.writer);
    try expectEqualStrings(expected, out.written());
}

/// Compiles `query`, expects `want`, and checks the diagnostic: line 1, byte column `col`.
fn expect_fails(query: []const u8, want: QueryError, col: u32) !void {
    var program: Program = undefined;
    var diag = blank_diag();
    const result = jsonpath.compile(&program, query, &diag);
    try std.testing.expectError(want, result);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(col, diag.col);
    try expect(diag.message().len > 0);
    try expect(diag.snippet_text() != null);
}

test "jsonpath compile: the empty query is just the root" {
    try expect_compiles("$", "$");
}

test "jsonpath compile: child and descendant segments" {
    const cases = [_][2][]const u8{
        .{ "$.a", "$['a']" },
        .{ "$.*", "$[*]" },
        .{ "$..a", "$..['a']" },
        .{ "$..*", "$..[*]" },
        .{ "$..[0]", "$..[0]" },
        .{ "$..['a','b']", "$..['a','b']" },
        .{ "$.a.b[0]..c", "$['a']['b'][0]..['c']" },
        .{ "$._a1", "$['_a1']" },
        .{ "$.\xc3\xa9", "$['\xc3\xa9']" },
        .{ "$.store.book[*].author", "$['store']['book'][*]['author']" },
        .{ "$..book[2]", "$..['book'][2]" },
    };
    for (cases) |case| try expect_compiles(case[0], case[1]);
}

test "jsonpath compile: bracket selectors, lists and blanks" {
    const cases = [_][2][]const u8{
        .{ "$['a']", "$['a']" },
        .{ "$[\"a\"]", "$['a']" },
        .{ "$['a','b']", "$['a','b']" },
        .{ "$[ 'a' , 'b' ]", "$['a','b']" },
        .{ "$[\t\n\r 'a']", "$['a']" },
        .{ "$ .a", "$['a']" },
        .{ "$ ['a'] .b  ..c", "$['a']['b']..['c']" },
        .{ "$[0]", "$[0]" },
        .{ "$[-1]", "$[-1]" },
        .{ "$[0,-1,*]", "$[0,-1,*]" },
        .{ "$['']", "$['']" },
        .{ "$['\xc3\xa9']", "$['\xc3\xa9']" },
    };
    for (cases) |case| try expect_compiles(case[0], case[1]);
}

test "jsonpath compile: slices" {
    const cases = [_][2][]const u8{
        .{ "$[1:3]", "$[1:3:1]" },
        .{ "$[:]", "$[::1]" },
        .{ "$[::]", "$[::1]" },
        .{ "$[1:]", "$[1::1]" },
        .{ "$[:3]", "$[:3:1]" },
        .{ "$[::2]", "$[::2]" },
        .{ "$[::-1]", "$[::-1]" },
        .{ "$[::0]", "$[::0]" },
        .{ "$[-3:-1]", "$[-3:-1:1]" },
        .{ "$[ 1 : 3 : 2 ]", "$[1:3:2]" },
        .{ "$[1:3,5]", "$[1:3:1,5]" },
    };
    for (cases) |case| try expect_compiles(case[0], case[1]);
}

test "jsonpath compile: string escapes decode into the program" {
    const cases = [_][2][]const u8{
        .{ "$['a\\nb']", "$['a\nb']" },
        .{ "$['\\b\\f\\r\\t']", "$['\x08\x0c\r\t']" },
        .{ "$['\\/']", "$['/']" },
        .{ "$['\\\\']", "$['\\']" },
        .{ "$['\\'']", "$[''']" },
        .{ "$[\"\\\"\"]", "$['\"']" },
        .{ "$['\\u00e9']", "$['\xc3\xa9']" },
        .{ "$['\\u00E9']", "$['\xc3\xa9']" },
        .{ "$['\\ud83d\\ude00']", "$['\xf0\x9f\x98\x80']" },
        .{ "$['\\u0000']", "$['\x00']" },
        .{ "$['\\u0041\\u0042']", "$['AB']" },
        .{ "$['\\ud83d\\ude00x']", "$['\xf0\x9f\x98\x80x']" },
        .{ "$[\"'\"]", "$[''']" },
        .{ "$['\"']", "$['\"']" },
    };
    for (cases) |case| try expect_compiles(case[0], case[1]);
}

test "jsonpath compile: integers at the I-JSON boundary" {
    try expect_compiles("$[9007199254740991]", "$[9007199254740991]");
    try expect_compiles("$[-9007199254740991]", "$[-9007199254740991]");
    const slice = "$[0:9007199254740991:9007199254740991]";
    try expect_compiles(slice, slice);
}

test "jsonpath compile: InvalidSyntax reports the column of the offending byte" {
    const cases = [_]struct { []const u8, u32 }{
        .{ "", 1 },
        .{ "a", 1 },
        .{ " $", 1 },
        .{ "$a", 2 },
        .{ "$.", 3 },
        .{ "$.1", 3 },
        .{ "$.-", 3 },
        .{ "$.a-b", 4 },
        .{ "$..", 4 },
        .{ "$...a", 4 },
        .{ "$.[a]", 3 },
        .{ "$. a", 3 },
        .{ "$[]", 3 },
        .{ "$[ ]", 4 },
        .{ "$[a]", 3 },
        .{ "$['a'", 6 },
        .{ "$['a", 5 },
        .{ "$['a',]", 7 },
        .{ "$[,'a']", 3 },
        .{ "$['a' 'b']", 7 },
        .{ "$[01]", 3 },
        .{ "$[-0]", 3 },
        .{ "$[-01]", 3 },
        .{ "$[1:-0]", 5 },
        .{ "$[::00]", 5 },
        .{ "$.. a", 4 },
        .{ "$\x0b.a", 2 },
        .{ "$[\x0c'a']", 3 },
        .{ "$[-]", 4 },
        .{ "$[+1]", 3 },
        .{ "$[1.5]", 4 },
        .{ "$[1:2:3:4]", 8 },
        .{ "$[1::2:]", 7 },
        .{ "$.a ", 4 },
        .{ "$ ", 2 },
    };
    for (cases) |case| try expect_fails(case[0], error.InvalidSyntax, case[1]);
}

test "jsonpath compile: bad string escapes and bytes are InvalidSyntax at the backslash" {
    const cases = [_]struct { []const u8, u32 }{
        .{ "$['\\x']", 4 },
        .{ "$['\\\"']", 4 },
        .{ "$[\"\\'\"]", 4 },
        .{ "$['\\ud800']", 4 },
        .{ "$['\\ud800x']", 4 },
        .{ "$['\\ud800\\u0041']", 4 },
        .{ "$['\\ud800\\uZZZZ']", 4 },
        .{ "$['\\ud800\\ud800']", 4 },
        .{ "$['\\udc00\\ud800']", 4 },
        .{ "$['\\udc00']", 4 },
        .{ "$['\\u12G4']", 4 },
        .{ "$['\\u12']", 4 },
        .{ "$['\\", 4 },
        .{ "$['a\x01b']", 5 },
        .{ "$['\xff']", 4 },
        .{ "$.a\xff", 4 },
        .{ "$['\xed\xa0\x80']", 4 },
    };
    for (cases) |case| try expect_fails(case[0], error.InvalidSyntax, case[1]);
}

test "jsonpath compile: IntegerOutOfRange outside plus or minus 2^53 - 1" {
    try expect_fails("$[9007199254740992]", error.IntegerOutOfRange, 3);
    try expect_fails("$[-9007199254740992]", error.IntegerOutOfRange, 3);
    try expect_fails("$[1:9007199254740992]", error.IntegerOutOfRange, 5);
    try expect_fails("$[::9007199254740992]", error.IntegerOutOfRange, 5);
    try expect_fails("$[99999999999999999999]", error.IntegerOutOfRange, 3);
}

test "jsonpath compile: query length boundary" {
    const fits = "$['" ++ ("a" ** 1019) ++ "']";
    comptime std.debug.assert(fits.len == jsonpath.query_len_max);
    try expect_compiles(fits, "$['" ++ ("a" ** 1019) ++ "']");

    const over = "$['" ++ ("a" ** 1020) ++ "']";
    comptime std.debug.assert(over.len == jsonpath.query_len_max + 1);
    try expect_fails(over, error.QueryTooLong, jsonpath.query_len_max + 1);
}

test "jsonpath compile: segment count boundary" {
    const fits = "$" ++ (".a" ** jsonpath.segments_max);
    try expect_compiles(fits, "$" ++ ("['a']" ** jsonpath.segments_max));

    const over = "$" ++ (".a" ** (jsonpath.segments_max + 1));
    try expect_fails(over, error.TooManySegments, 1 + 2 * jsonpath.segments_max + 1);
    const descendant = "$" ++ ("..a" ** (jsonpath.segments_max + 1));
    try expect_fails(descendant, error.TooManySegments, 1 + 3 * jsonpath.segments_max + 1);
}

test "jsonpath compile: selector count boundary spans the whole query" {
    const list = "[" ++ ("*," ** (jsonpath.selectors_max - 1)) ++ "*]";
    try expect_compiles("$" ++ list, "$" ++ list);
    const over_list = "[" ++ ("*," ** jsonpath.selectors_max) ++ "*]";
    try expect_fails("$" ++ over_list, error.TooManySelectors, 3 + 2 * jsonpath.selectors_max);

    const prefix = "$" ++ ("[*,*,*]" ** 21) ++ ".a";
    try expect_compiles(prefix, "$" ++ ("[*,*,*]" ** 21) ++ "['a']");
    try expect_fails(prefix ++ ".b", error.TooManySelectors, prefix.len + 2);
}

test "jsonpath compile: diag is untouched on success and set on error" {
    var program: Program = undefined;
    var diag = Diagnostics.init(7, 7, "kept", "kept");
    try jsonpath.compile(&program, "$.a", &diag);
    try expectEqual(@as(u32, 7), diag.line);
    try expectEqualStrings("kept", diag.message());

    try std.testing.expectError(error.InvalidSyntax, jsonpath.compile(&program, "$.", &diag));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 3), diag.col);
    try expectEqualStrings("$.", diag.snippet_text().?);
}

const Generated = struct {
    query: [jsonpath.query_len_max]u8 = undefined,
    query_len: usize = 0,
    expected: [jsonpath.query_len_max * 2]u8 = undefined,
    expected_len: usize = 0,
    segments: u32 = 0,

    fn put_query(gen: *Generated, text: []const u8) void {
        @memcpy(gen.query[gen.query_len..][0..text.len], text);
        gen.query_len += text.len;
    }

    fn put_expected(gen: *Generated, text: []const u8) void {
        @memcpy(gen.expected[gen.expected_len..][0..text.len], text);
        gen.expected_len += text.len;
    }
};

fn blanks(random: std.Random) []const u8 {
    const options = [_][]const u8{ "", "", " ", "\t", " \n ", "\r" };
    return options[random.uintLessThan(usize, options.len)];
}

fn generate_selector(gen: *Generated, random: std.Random) void {
    const names = [_][]const u8{ "a", "bc", "x1", "_", "k" };
    switch (random.uintLessThan(u8, 5)) {
        0 => {
            const name = names[random.uintLessThan(usize, names.len)];
            const quote: []const u8 = if (random.boolean()) "'" else "\"";
            gen.put_query(quote);
            gen.put_query(name);
            gen.put_query(quote);
            gen.put_expected("'");
            gen.put_expected(name);
            gen.put_expected("'");
        },
        1 => {
            var buffer: [24]u8 = undefined;
            const value = random.intRangeAtMost(i64, -50, 50);
            // proof: 24 bytes hold any i64 in -50..50.
            const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
            gen.put_query(text);
            gen.put_expected(text);
        },
        2 => {
            gen.put_query("*");
            gen.put_expected("*");
        },
        3 => generate_slice(gen, random),
        else => {
            gen.put_query("'\\u0061'");
            gen.put_expected("'a'");
        },
    }
}

fn small_int(buffer: *[24]u8, random: std.Random) []const u8 {
    const value = random.intRangeAtMost(i64, -9, 9);
    // proof: 24 bytes hold any i64 in -9..9.
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch unreachable;
}

fn generate_slice(gen: *Generated, random: std.Random) void {
    var buffer: [24]u8 = undefined;
    if (random.boolean()) {
        const text = small_int(&buffer, random);
        gen.put_query(text);
        gen.put_expected(text);
    }
    gen.put_query(":");
    gen.put_expected(":");
    if (random.boolean()) {
        const text = small_int(&buffer, random);
        gen.put_query(text);
        gen.put_expected(text);
    }
    if (random.boolean()) {
        const text = small_int(&buffer, random);
        gen.put_query(":");
        gen.put_query(text);
        gen.put_expected(":");
        gen.put_expected(text);
    } else {
        gen.put_expected(":1");
    }
}

fn generate_segment(gen: *Generated, random: std.Random) void {
    gen.put_query(blanks(random));
    const descendant = random.boolean();
    if (descendant) {
        gen.put_query("..");
        gen.put_expected("..");
    }
    gen.put_expected("[");
    gen.put_query("[");
    const selectors = random.intRangeAtMost(u8, 1, 3);
    for (0..selectors) |index| {
        if (index > 0) {
            gen.put_query(blanks(random));
            gen.put_query(",");
            gen.put_expected(",");
        }
        gen.put_query(blanks(random));
        generate_selector(gen, random);
    }
    gen.put_query(blanks(random));
    gen.put_query("]");
    gen.put_expected("]");
    gen.segments += 1;
}

test "jsonpath compile: seeded model agrees on generated queries" {
    for (0..500) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var gen: Generated = .{};
        gen.put_query("$");
        gen.put_expected("$");
        const segments = random.intRangeAtMost(u8, 0, 8);
        for (0..segments) |_| generate_segment(&gen, random);

        var program: Program = undefined;
        var diag = blank_diag();
        jsonpath.compile(&program, gen.query[0..gen.query_len], &diag) catch |err| {
            const query = gen.query[0..gen.query_len];
            std.log.err("seed {d}: '{s}' failed {s}", .{ seed, query, @errorName(err) });
            return err;
        };
        program.check_invariants();
        try expectEqual(gen.segments, program.segments_count);

        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try render(&program, &out.writer);
        try expectEqualStrings(gen.expected[0..gen.expected_len], out.written());
    }
}

test "jsonpath compile: hostile bytes are an error with a diagnostic, never a crash" {
    const alphabet = "$.*[]'\"\\,:-0123456789abu?@ \t\xc3\xff";
    for (0..2000) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var text: [40]u8 = undefined;
        const len = random.uintAtMost(usize, text.len);
        for (text[0..len]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        if (len > 0 and random.boolean()) text[0] = '$';

        var program: Program = undefined;
        var diag = blank_diag();
        if (jsonpath.compile(&program, text[0..len], &diag)) |_| {
            program.check_invariants();
            try expectEqual(@as(u32, 0), diag.line);
        } else |_| {
            try expectEqual(@as(u32, 1), diag.line);
            try expect(diag.col >= 1);
            try expect(diag.col <= len + 1);
        }
    }
}

//! Tests for `toml/parser.zig` keys and tables (plan 006 item 5): the TOML 1.0.0 spec examples
//! for keys, tables and arrays of tables, every redefinition error with its line:col, depth.

const std = @import("std");
const core = @import("../core.zig");
const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ParseOptions = parser.ParseOptions;
const ParseValueError = parser.ParseValueError;
const Value = core.Value;
const ValueTree = core.ValueTree;

const options_default: ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };

fn parse_with(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    const value = try parser.parse_value(std.testing.allocator, tree, input, options, diag);
    check_maps(value);
    return value;
}

/// Parses `input` with the default options; the caller owns `tree`.
fn parse_ok(tree: *ValueTree, input: []const u8) !Value {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const value = try parse_with(tree, input, options_default, &diag);
    try expectEqualStrings("untouched", diag.message());
    return value;
}

fn expect_failure_with(
    input: []const u8,
    options: ParseOptions,
    err: ParseValueError,
    line: u32,
    col: u32,
) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    try expectError(err, parse_with(&tree, input, options, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(!std.mem.eql(u8, diag.message(), "untouched"));
}

fn expect_failure(input: []const u8, err: ParseValueError, line: u32, col: u32) !void {
    try expect_failure_with(input, options_default, err, line, col);
}

/// `check_invariants` on every map reachable from `root`, iteratively (no recursion).
fn check_maps(root: Value) void {
    var stack: [512]Value = undefined;
    var depth: usize = 1;
    stack[0] = root;
    for (0..4096) |_| {
        if (depth == 0) return;
        depth -= 1;
        switch (stack[depth]) {
            .map => |map| {
                map.check_invariants();
                for (map.items()) |entry| {
                    stack[depth] = entry.value;
                    depth += 1;
                }
            },
            .array => |items| {
                for (items) |item| {
                    stack[depth] = item;
                    depth += 1;
                }
            },
            else => {},
        }
    }
    unreachable; // proof: the test documents are far smaller than the step bound.
}

fn field(value: Value, name: []const u8) !Value {
    try expect(value == .map);
    const found = value.map.get(name) orelse return error.TestMissingKey;
    return found.*;
}

fn expect_keys(value: Value, names: []const []const u8) !void {
    try expect(value == .map);
    try expectEqual(names.len, value.map.count);
    for (names, value.map.items()) |name, entry| try expectEqualStrings(name, entry.key);
}

test "parser: empty input, comments and blank lines give an empty table" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(u32, 0), (try parse_ok(&tree, "")).map.count);
    try expectEqual(@as(u32, 0), (try parse_ok(&tree, "# only\r\n\r\n  \n\t# more")).map.count);
}

test "parser: bare, quoted and dotted keys (spec Keys)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\key = "value"
        \\bare_key = "value"
        \\bare-key = "value"
        \\1234 = "value"
        \\"127.0.0.1" = "value"
        \\"character encoding" = "value"
        \\'quoted "value"' = "value"
        \\"" = "blank"
        \\
    );
    try expect_keys(root, &.{
        "key",       "bare_key",           "bare-key",         "1234",
        "127.0.0.1", "character encoding", "quoted \"value\"", "",
    });
    try expectEqualStrings("blank", (try field(root, "")).string);

    const dotted = try parse_ok(&tree,
        \\name = "Orange"
        \\physical.color = "orange"
        \\physical.shape = "round"
        \\site."google.com" = true
        \\
    );
    try expect_keys(dotted, &.{ "name", "physical", "site" });
    try expectEqualStrings("round", (try field(try field(dotted, "physical"), "shape")).string);
    try expect((try field(try field(dotted, "site"), "google.com")).bool);
}

test "parser: whitespace around dots is ignored, and fruit.name is nested (spec)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree, "fruit.name = \"banana\"\nfruit. color = \"yellow\"\n" ++
        "fruit . flavor = \"banana\"\n");
    try expect_keys(root, &.{"fruit"});
    try expect_keys(try field(root, "fruit"), &.{ "name", "color", "flavor" });
}

test "parser: an escaped quoted key is decoded and collides with the bare spelling" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree, "\"a\\tb\" = 1\n\"\\u0063\" = 2\n");
    try expect_keys(root, &.{ "a\tb", "c" });
    try expect_failure("a = 1\n\"a\" = 2\n", error.DuplicateKey, 2, 1);
    try expect_failure("c = 1\n\"\\u0063\" = 2\n", error.DuplicateKey, 2, 1);
    try expect_failure("[a]\n[\"\\u0061\"]\n", error.TableRedefined, 2, 2);
}

test "parser: scalar and string values reach the tree with their types" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\a = true
        \\b = -17
        \\c = 6.626e-34
        \\d = 1979-05-27 07:32:00
        \\e = "x\ny"
        \\f = 'C:\path'
        \\g = """
        \\two
        \\lines"""
        \\h = '''
        \\raw'''
        \\
    );
    try expect((try field(root, "a")).bool);
    try expectEqual(@as(i64, -17), (try field(root, "b")).int);
    try expect((try field(root, "c")).float > 6.6e-34);
    try expectEqual(core.Timestamp.Kind.local_datetime, (try field(root, "d")).timestamp.kind);
    try expectEqualStrings("x\ny", (try field(root, "e")).string);
    try expectEqualStrings("C:\\path", (try field(root, "f")).string);
    try expectEqualStrings("two\nlines", (try field(root, "g")).string);
    try expectEqualStrings("raw", (try field(root, "h")).string);
}

test "parser: tables (spec Table)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\[table-1]
        \\key1 = "some string"
        \\key2 = 123
        \\
        \\[table-2]
        \\key1 = "another string"
        \\key2 = 456
        \\
    );
    try expect_keys(root, &.{ "table-1", "table-2" });
    try expectEqual(@as(i64, 456), (try field(try field(root, "table-2"), "key2")).int);

    const nested = try parse_ok(&tree,
        \\[dog."tater.man"]
        \\type.name = "pug"
        \\[a.b.c]
        \\[ d.e.f ]
        \\[ g .  h  . i ]
        \\[ j . "ʞ" . 'l' ]
        \\[x] # defining a super-table afterward is ok
        \\[x.y.z.w]
        \\
    );
    try expect_keys(nested, &.{ "dog", "a", "d", "g", "j", "x" });
    const tater = try field(try field(nested, "dog"), "tater.man");
    try expectEqualStrings("pug", (try field(try field(tater, "type"), "name")).string);
    const w = try field(try field(try field(try field(nested, "x"), "y"), "z"), "w");
    try expectEqual(@as(u32, 0), w.map.count);
    _ = try field(try field(try field(nested, "j"), "ʞ"), "l");
}

test "parser: super-table defined after a sub-table, and out-of-order sections (spec)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\[fruit.apple]
        \\[animal]
        \\[fruit.orange]
        \\[fruit]
        \\flavor = 1
        \\
    );
    try expect_keys(root, &.{ "fruit", "animal" });
    try expect_keys(try field(root, "fruit"), &.{ "apple", "orange", "flavor" });
}

test "parser: dotted keys and a header can both extend one table (spec)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\fruit.apple.color = "red"
        \\fruit.apple.taste.sweet = true
        \\[fruit.apple.texture]
        \\smooth = true
        \\
    );
    const apple = try field(try field(root, "fruit"), "apple");
    try expect_keys(apple, &.{ "color", "taste", "texture" });
    try expect((try field(try field(apple, "texture"), "smooth")).bool);

    const sections = try parse_ok(&tree, "[a]\nb.c = 1\nb.d = 2\n[a.b.e]\nf = 3\n[g]\nb.c = 4\n");
    try expect_keys(try field(try field(sections, "a"), "b"), &.{ "c", "d", "e" });
    try expectEqual(@as(i64, 4), (try field(try field(try field(sections, "g"), "b"), "c")).int);
}

test "parser: arrays of tables (spec Array of Tables)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]  # empty table within the array
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
        \\color = "gray"
        \\
    );
    const products = (try field(root, "products")).array;
    try expectEqual(@as(usize, 3), products.len);
    try expect_keys(products[0], &.{ "name", "sku" });
    try expectEqual(@as(u32, 0), products[1].map.count);
    try expect_keys(products[2], &.{ "name", "sku", "color" });
}

test "parser: sub-tables and nested arrays of tables attach to the newest element (spec)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]  # subtable
        \\color = "red"
        \\
        \\[[fruits.varieties]]  # nested array of tables
        \\name = "red delicious"
        \\
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\
        \\[[fruits.varieties]]
        \\name = "plantain"
        \\
    );
    const fruits = (try field(root, "fruits")).array;
    try expectEqual(@as(usize, 2), fruits.len);
    try expect_keys(fruits[0], &.{ "name", "physical", "varieties" });
    try expectEqual(@as(usize, 2), (try field(fruits[0], "varieties")).array.len);
    try expect_keys(fruits[1], &.{ "name", "varieties" });
    const plantain = (try field(fruits[1], "varieties")).array[0];
    try expectEqualStrings("plantain", (try field(plantain, "name")).string);
}

test "parser: redefinition errors point at the offending key segment" {
    try expect_failure("[a]\n[a]\n", error.TableRedefined, 2, 2);
    try expect_failure("[a.b]\nx = 1\n[a.b]\n", error.TableRedefined, 3, 4);
    const fruit = "[fruit]\napple.color = \"red\"\n[fruit.apple]\n";
    try expect_failure(fruit, error.TableRedefined, 3, 8);
    try expect_failure("[a]\nb.c = 1\n[a.b]\n", error.TableRedefined, 3, 4);
    try expect_failure("[a.b]\n[a]\nb.c = 1\n", error.TableRedefined, 3, 1);
    try expect_failure("[a.b.c]\n[a]\nb.d = 1\n", error.TableRedefined, 3, 1);
    try expect_failure("a.b = 1\n[a]\n", error.TableRedefined, 2, 2);
    try expect_failure("a = 1\na = 2\n", error.DuplicateKey, 2, 1);
    try expect_failure("[t]\nx.y = 1\nx.y = 2\n", error.DuplicateKey, 3, 3);
    try expect_failure("a.b = 1\na = 2\n", error.DuplicateKey, 2, 1);
}

test "parser: kind conflicts" {
    try expect_failure("a = 1\n[a]\n", error.TypeConflict, 2, 2);
    try expect_failure("a = 1\na.b = 2\n", error.TypeConflict, 2, 1);
    try expect_failure("a = 1\n[a.b]\n", error.TypeConflict, 2, 2);
    try expect_failure("a = 1\n[[a]]\n", error.TypeConflict, 2, 3);
    try expect_failure("[[a]]\n[a]\n", error.TypeConflict, 2, 2);
    try expect_failure("[a]\n[[a]]\n", error.TypeConflict, 2, 3);
    try expect_failure("[a.b]\n[[a]]\n", error.TypeConflict, 2, 3);
    try expect_failure("[a]\nb = 1\n[a.b.c]\n", error.TypeConflict, 3, 4);
}

test "parser: the message names the key and the line of the earlier definition" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    const input = "x = 1\n\nname = 1\nname = 2\n";
    try expectError(error.DuplicateKey, parse_with(&tree, input, options_default, &diag));
    try expect(std.mem.find(u8, diag.message(), "`name`") != null);
    try expect(std.mem.find(u8, diag.message(), "line 3") != null);
    try expectEqualStrings("name = 2", diag.snippet_text().?[0..8]);
}

test "parser: a long multi-byte key is cut on a character boundary in the message" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const key = "\"" ++ "é" ** 30 ++ "\"";
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const input = key ++ " = 1\n" ++ key ++ " = 2\n";
    try expectError(error.DuplicateKey, parse_with(&tree, input, options_default, &diag));
    try expect(std.unicode.utf8ValidateSlice(diag.message()));
    try expect(std.mem.find(u8, diag.message(), "éé") != null);
}

test "parser: grammar errors" {
    try expect_failure("= 1\n", error.UnexpectedToken, 1, 1);
    try expect_failure("a = \n", error.UnexpectedToken, 1, 5);
    try expect_failure("a =", error.UnexpectedEnd, 1, 4);
    try expect_failure("a", error.UnexpectedEnd, 1, 2);
    try expect_failure("a b = 1\n", error.UnexpectedToken, 1, 3);
    try expect_failure("a = 1 b = 2\n", error.UnexpectedToken, 1, 7);
    try expect_failure("a = 1,\n", error.UnexpectedToken, 1, 6);
    try expect_failure("a. = 1\n", error.UnexpectedToken, 1, 4);
    try expect_failure("[a\n", error.UnexpectedToken, 1, 3);
    try expect_failure("[a", error.UnexpectedEnd, 1, 3);
    try expect_failure("[]\n", error.UnexpectedToken, 1, 2);
    try expect_failure("[a.]\n", error.UnexpectedToken, 1, 4);
    try expect_failure("[[a]\n", error.UnexpectedToken, 1, 4);
    try expect_failure("[a]]\n", error.UnexpectedToken, 1, 3);
    try expect_failure("[a] b\n", error.UnexpectedToken, 1, 5);
    try expect_failure("[ [a]]\n", error.UnexpectedToken, 1, 3);
    try expect_failure("\"\"\"a\"\"\" = 1\n", error.UnexpectedToken, 1, 1);
    try expect_failure("a = 1\r\nb = 2\rc = 3\n", error.UnexpectedToken, 2, 6);
}

test "parser: scalar and lexer faults carry their position" {
    try expect_failure("a = 01\n", error.InvalidNumber, 1, 5);
    try expect_failure("a = 9223372036854775808\n", error.IntegerAboveMax, 1, 5);
    try expect_failure("a = -9223372036854775809\n", error.IntegerBelowMin, 1, 5);
    try expect_failure("a = 1979-02-30\n", error.InvalidDatetime, 1, 5);
    try expect_failure("a = nope\n", error.UnexpectedToken, 1, 5);
    try expect_failure("a = \"unterminated\n", error.ControlCharacter, 1, 18);
    try expect_failure("b = 1\na = \"\\q\"\n", error.InvalidEscape, 2, 6);
}

test "parser: value starts that item 6 will accept are still refused" {
    try expect_failure("a = [1]\n", error.UnexpectedToken, 1, 5);
    try expect_failure("a = { b = 1 }\n", error.UnexpectedToken, 1, 5);
}

fn header_of(buffer: []u8, segments: usize, array: bool) []const u8 {
    var len: usize = 0;
    const open: []const u8 = if (array) "[[" else "[";
    @memcpy(buffer[len..][0..open.len], open);
    len += open.len;
    for (0..segments) |index| {
        if (index > 0) {
            buffer[len] = '.';
            len += 1;
        }
        buffer[len] = 'a';
        len += 1;
    }
    const close: []const u8 = if (array) "]]\n" else "]\n";
    @memcpy(buffer[len..][0..close.len], close);
    return buffer[0 .. len + close.len];
}

test "parser: a header 127 segments deep passes and 128 is TooDeep" {
    var buffer: [512]u8 = undefined;
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const deepest = try parse_ok(&tree, header_of(&buffer, 127, false));
    try expect(deepest == .map);
    // Segment k starts at byte 1 + 2k; the 128th is k = 127, byte 255, column 256.
    try expect_failure(header_of(&buffer, 128, false), error.TooDeep, 1, 256);
}

test "parser: [[a.b]] adds two levels, so 126 segments pass and 127 are TooDeep" {
    var buffer: [512]u8 = undefined;
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try parse_ok(&tree, header_of(&buffer, 126, true));
    // The last segment starts at byte 2 + 2 * 126 = 254, column 255.
    try expect_failure(header_of(&buffer, 127, true), error.TooDeep, 1, 255);
}

test "parser: depth_max narrows the limit for headers and dotted keys" {
    const narrow: ParseOptions = .{ .depth_max = 2, .bytes_max = 1024 };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    _ = try parse_with(&tree, "[a]\nx = 1\n", narrow, &diag);
    try expect_failure_with("[a.b]\n", narrow, error.TooDeep, 1, 4);
    try expect_failure_with("a.b.c = 1\n", narrow, error.TooDeep, 1, 3);
    try expect_failure_with("[[a]]\n", narrow, error.TooDeep, 1, 3);
    const one: ParseOptions = .{ .depth_max = 1, .bytes_max = 1024 };
    _ = try parse_with(&tree, "a = 1\n", one, &diag);
    try expect_failure_with("[a]\n", one, error.TooDeep, 1, 2);
}

test "parser: bytes_max is inclusive and InputTooLarge is reported at 1:1" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    const edge: ParseOptions = .{ .depth_max = 4, .bytes_max = 5 };
    _ = try parse_with(&tree, "a = 1", edge, &diag);
    try expect_failure_with("a = 12", edge, error.InputTooLarge, 1, 1);
    const none: ParseOptions = .{ .depth_max = 4, .bytes_max = 0 };
    _ = try parse_with(&tree, "", none, &diag);
    try expect_failure_with("a", none, error.InputTooLarge, 1, 1);
}

test "parser: the error set is the 17 variants of ADR 0005 section 6" {
    const names = [_][]const u8{
        "InputTooLarge",   "UnexpectedEnd", "UnexpectedToken", "InvalidNumber",
        "InvalidDatetime", "InvalidEscape", "LoneSurrogate",   "ControlCharacter",
        "InvalidUtf8",     "TooDeep",       "IntegerAboveMax", "IntegerBelowMin",
        "FloatOutOfRange", "DuplicateKey",  "TableRedefined",  "TypeConflict",
        "OutOfMemory",
    };
    const variants = @typeInfo(ParseValueError).error_set.?;
    try expectEqual(names.len, variants.len);
    inline for (names) |name| {
        var found = false;
        inline for (variants) |variant| {
            if (std.mem.eql(u8, variant.name, name)) found = true;
        }
        try expect(found);
    }
}

test "parser: every allocation failing gives OutOfMemory or the right tree, never a leak" {
    const input = "a.b = 1\n\"e\\tf\" = 2\n[c]\nd = \"x\\ny\"\n[[g]]\n[[g]]\nh = 3\n";
    var reached_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();

        var diag = Diagnostics.init(0, 0, "untouched", null);
        const result = parser.parse_value(
            failing.allocator(),
            &tree,
            input,
            options_default,
            &diag,
        );
        if (result) |value| {
            check_maps(value);
            try expect_keys(value, &.{ "a", "e\tf", "c", "g" });
            try expectEqual(@as(usize, 2), (try field(value, "g")).array.len);
            try expectEqualStrings("untouched", diag.message());
            reached_success = true;
        } else |err| {
            try expectEqualStrings("OutOfMemory", @errorName(err));
            try expect(diag.line >= 1);
        }
    }
    try expect(reached_success);
}

test "parser: LF and CRLF documents parse to equal trees" {
    var lf: ValueTree = undefined;
    lf.init(std.testing.allocator);
    defer lf.deinit();

    var crlf: ValueTree = undefined;
    crlf.init(std.testing.allocator);
    defer crlf.deinit();

    const text = "a = 1\n[t]\nb.c = \"x\"\n[[u]]\nd = true\n";
    const converted = "a = 1\r\n[t]\r\nb.c = \"x\"\r\n[[u]]\r\nd = true\r\n";
    const left = try parse_ok(&lf, text);
    const right = try parse_ok(&crlf, converted);
    try expect(try core.value.eql(left, right));
}

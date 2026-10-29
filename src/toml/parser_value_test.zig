//! Tests for `toml/parser.zig` array and inline-table values (plan 006 item 6): the TOML 1.0.0
//! spec examples, freezing, grammar errors with line:col, nesting depth and the node bound.

const std = @import("std");
const core = @import("../core.zig");
const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ParseOptions = parser.ParseOptions;
const ValueTree = core.ValueTree;
const fixtures = @import("parser_fixtures.zig");
const check_maps = fixtures.check_maps;
const expect_failure = fixtures.expect_failure;
const expect_failure_with = fixtures.expect_failure_with;
const expect_keys = fixtures.expect_keys;
const field = fixtures.field;
const options_default = fixtures.options_default;
const parse_ok = fixtures.parse_ok;
const parse_with = fixtures.parse_with;

test "parser: arrays (spec Array)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\integers = [ 1, 2, 3 ]
        \\colors = [ "red", "yellow", "green" ]
        \\nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
        \\nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
        \\string_array = [ "all", 'strings', """are the same""", '''type''' ]
        \\numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
        \\integers2 = [
        \\  1, 2, 3
        \\]
        \\integers3 = [
        \\  1,
        \\  2, # this is ok
        \\]
        \\empty = []
        \\
    );
    try expect_keys(root, &.{
        "integers",     "colors",  "nested_arrays_of_ints", "nested_mixed_array",
        "string_array", "numbers", "integers2",             "integers3",
        "empty",
    });
    const integers = (try field(root, "integers")).array;
    try expectEqual(@as(usize, 3), integers.len);
    try expectEqual(@as(i64, 3), integers[2].int);
    const nested = (try field(root, "nested_mixed_array")).array;
    try expectEqual(@as(usize, 2), nested.len);
    try expectEqual(@as(i64, 2), nested[0].array[1].int);
    try expectEqualStrings("c", nested[1].array[2].string);
    const strings = (try field(root, "string_array")).array;
    try expectEqualStrings("are the same", strings[2].string);
    try expectEqualStrings("type", strings[3].string);
    try expectEqual(@as(usize, 6), (try field(root, "numbers")).array.len);
    try expectEqual(@as(i64, 2), (try field(root, "integers3")).array[1].int);
    try expectEqual(@as(usize, 0), (try field(root, "empty")).array.len);
}

test "parser: a mixed-type array is legal in TOML 1.0" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(
        &tree,
        "a = [1, \"two\", 3.0, true, [4], { five = 5 }, 1979-05-27]\n",
    );
    const items = (try field(root, "a")).array;
    try expectEqual(@as(usize, 7), items.len);
    try expectEqual(@as(i64, 1), items[0].int);
    try expectEqualStrings("two", items[1].string);
    try expect(items[2].float == 3.0);
    try expect(items[3].bool);
    try expectEqual(@as(i64, 4), items[4].array[0].int);
    try expectEqual(@as(i64, 5), (try field(items[5], "five")).int);
    try expectEqual(core.Timestamp.Kind.local_date, items[6].timestamp.kind);
}

test "parser: inline tables (spec Inline Table)" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = { x = 1, y = 2 }
        \\animal = { type.name = "pug" }
        \\empty = {}
        \\contributors = [
        \\  "Foo Bar <foo@example.com>",
        \\  { name = "Baz Qux", email = "bazqux@example.com" }
        \\]
        \\
    );
    try expect_keys(root, &.{ "name", "point", "animal", "empty", "contributors" });
    try expectEqualStrings("Tom", (try field(try field(root, "name"), "first")).string);
    try expectEqual(@as(i64, 2), (try field(try field(root, "point"), "y")).int);
    const animal = try field(try field(root, "animal"), "type");
    try expectEqualStrings("pug", (try field(animal, "name")).string);
    try expectEqual(@as(usize, 0), (try field(root, "empty")).map.count);
    const people = (try field(root, "contributors")).array;
    try expectEqualStrings("Foo Bar <foo@example.com>", people[0].string);
    try expectEqualStrings("Baz Qux", (try field(people[1], "name")).string);
}

test "parser: arrays and inline tables inside tables, headers and each other" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree,
        \\[a]
        \\b = { c = [1, { d = [] }], e.f = [[]] }
        \\[[g]]
        \\h = [ { i = 1 }, { i = 2 } ]
        \\
    );
    const b = try field(try field(root, "a"), "b");
    const c = (try field(b, "c")).array;
    try expectEqual(@as(usize, 0), (try field(c[1], "d")).array.len);
    const f = (try field(try field(b, "e"), "f")).array;
    try expectEqual(@as(usize, 1), f.len);
    try expectEqual(@as(usize, 0), f[0].array.len);
    const h = (try field((try field(root, "g")).array[0], "h")).array;
    try expectEqual(@as(i64, 2), (try field(h[1], "i")).int);
}

test "parser: arrays and inline tables are frozen once closed" {
    // Spec: an inline table cannot be extended, and static arrays cannot be appended to.
    try expect_failure("a = { b = 1 }\n[a.c]\n", error.TableRedefined, 2, 2);
    try expect_failure("a = { b = 1 }\n[a]\n", error.TableRedefined, 2, 2);
    try expect_failure("a = { b = 1 }\na.c = 2\n", error.TableRedefined, 2, 1);
    try expect_failure("a = { b.c = 1 }\n[a.b]\n", error.TableRedefined, 2, 2);
    try expect_failure("a = [1]\n[[a]]\n", error.TypeConflict, 2, 3);
    try expect_failure("a = [1]\n[a.b]\n", error.TypeConflict, 2, 2);
    try expect_failure("a = [{ b = 1 }]\n[a.b]\n", error.TypeConflict, 2, 2);
    try expect_failure("[[a]]\n[a]\n", error.TypeConflict, 2, 2);
    try expect_failure("[[a]]\nb = [1]\n[a.b]\n", error.TypeConflict, 3, 4);
}

test "parser: inline table key errors" {
    try expect_failure("a = { b = 1, b = 2 }\n", error.DuplicateKey, 1, 14);
    try expect_failure("a = { b = 1, b.c = 2 }\n", error.TypeConflict, 1, 14);
    try expect_failure("a = { b.c = 1, b.c = 2 }\n", error.DuplicateKey, 1, 18);
    try expect_failure("a = { b = { c = 1, c = 2 } }\n", error.DuplicateKey, 1, 20);
}

test "parser: array and inline table grammar errors" {
    try expect_failure("a = { b = 1, }\n", error.UnexpectedToken, 1, 14);
    try expect_failure("a = { , }\n", error.UnexpectedToken, 1, 7);
    try expect_failure("a = {\n b = 1 }\n", error.UnexpectedToken, 1, 6);
    try expect_failure("a = { b = 1,\n c = 2 }\n", error.UnexpectedToken, 1, 13);
    try expect_failure("a = { b = 1 c = 2 }\n", error.UnexpectedToken, 1, 13);
    try expect_failure("a = { b = }\n", error.UnexpectedToken, 1, 11);
    try expect_failure("a = { b }\n", error.UnexpectedToken, 1, 9);
    try expect_failure("a = { b = 1\n", error.UnexpectedToken, 1, 12);
    try expect_failure("a = { b = 1", error.UnexpectedEnd, 1, 12);
    try expect_failure("a = [1 2]\n", error.UnexpectedToken, 1, 8);
    try expect_failure("a = [,]\n", error.UnexpectedToken, 1, 6);
    try expect_failure("a = [1,,2]\n", error.UnexpectedToken, 1, 8);
    try expect_failure("a = [1\n", error.UnexpectedEnd, 2, 1);
    try expect_failure("a = [\n", error.UnexpectedEnd, 2, 1);
    try expect_failure("a = [1]]\n", error.UnexpectedToken, 1, 8);
    try expect_failure("a = [1] 2\n", error.UnexpectedToken, 1, 9);
    try expect_failure("a = [nope]\n", error.UnexpectedToken, 1, 6);
    try expect_failure("a = [1,\n  2,\n  3x]\n", error.InvalidNumber, 3, 3);
    try expect_failure("a = ]\n", error.UnexpectedToken, 1, 5);
    try expect_failure("a = }\n", error.UnexpectedToken, 1, 5);
}

fn nested_input(buffer: []u8, levels: usize, open: u8, close: u8, closed: bool) []const u8 {
    @memcpy(buffer[0..4], "a = ");
    var len: usize = 4;
    for (0..levels) |_| {
        buffer[len] = open;
        len += 1;
        if (open == '{') {
            @memcpy(buffer[len..][0..4], "a = ");
            len += 4;
        }
    }
    @memcpy(buffer[len..][0..1], "1");
    len += 1;
    if (!closed) return buffer[0..len];
    for (0..levels) |_| {
        buffer[len] = close;
        len += 1;
    }
    buffer[len] = '\n';
    return buffer[0 .. len + 1];
}

test "parser: arrays nest to depth 127 and 128 is TooDeep" {
    var buffer: [1024]u8 = undefined;
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    // The root counts one level, so 127 arrays fill depth_max = 128.
    _ = try parse_ok(&tree, nested_input(&buffer, 127, '[', ']', true));
    // The 128th `[` is at byte 4 + 127, column 132.
    try expect_failure(nested_input(&buffer, 128, '[', ']', true), error.TooDeep, 1, 132);
}

test "parser: unclosed nesting is UnexpectedEnd, never an arena or node overflow" {
    var buffer: [1024]u8 = undefined;
    // The node bound must hold for one-byte nodes that have not met their closer.
    try expect_failure(nested_input(&buffer, 127, '[', ']', false), error.UnexpectedEnd, 1, 133);
    try expect_failure(nested_input(&buffer, 127, '{', '}', false), error.UnexpectedEnd, 1, 641);
}

test "parser: inline tables nest to depth 127 and 128 is TooDeep" {
    var buffer: [2048]u8 = undefined;
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try parse_ok(&tree, nested_input(&buffer, 127, '{', '}', true));
    // Each level is `a = {`; the 128th `{` is refused at its key, the 128th `a`, column 636.
    const too_deep = nested_input(&buffer, 128, '{', '}', true);
    try expect_failure(too_deep, error.TooDeep, 1, 5 * 127 + 1);
}

test "parser: depth_max applies to arrays and inline tables" {
    const narrow: ParseOptions = .{ .depth_max = 2, .bytes_max = 1024 };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    _ = try parse_with(&tree, "a = [1, 2]\nb = { c = 1 }\n", narrow, &diag);
    try expect_failure_with("a = [[1]]\n", narrow, error.TooDeep, 1, 6);
    try expect_failure_with("a = { b = {} }\n", narrow, error.TooDeep, 1, 7);
    try expect_failure_with("a = { b.c = 1 }\n", narrow, error.TooDeep, 1, 7);
    try expect_failure_with("a = [{}]\n", narrow, error.TooDeep, 1, 6);
}

test "parser: a long flat array of empty arrays stays inside the node bound" {
    // `[],` is three bytes per node, well inside the bound.
    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    @memcpy(buffer[0..5], "a = [");
    len = 5;
    for (0..200) |_| {
        @memcpy(buffer[len..][0..3], "[],");
        len += 3;
    }
    @memcpy(buffer[len..][0..2], "]\n");
    len += 2;
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree, buffer[0..len]);
    try expectEqual(@as(usize, 200), (try field(root, "a")).array.len);
}

test "parser: arrays and inline tables under every allocation failure never leak" {
    const input = "a = [1, { b = \"x\\ty\", c.d = [[], [2]] }]\ne = { f = [\"g\"] }\n";
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
            const items = (try field(value, "a")).array;
            try expectEqualStrings("x\ty", (try field(items[1], "b")).string);
            const d = (try field(try field(items[1], "c"), "d")).array;
            try expectEqual(@as(i64, 2), d[1].array[0].int);
            reached_success = true;
        } else |err| {
            try expectEqualStrings("OutOfMemory", @errorName(err));
        }
    }
    try expect(reached_success);
}

test "parser: dotted keys inside one inline table share their sub-table" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(&tree, "a = { b.c = 1, b.d = 2, e = 3 }\n");
    const b = try field(try field(root, "a"), "b");
    try expect_keys(b, &.{ "c", "d" });
    try expectEqual(@as(i64, 2), (try field(b, "d")).int);
    try expectEqual(@as(i64, 3), (try field(try field(root, "a"), "e")).int);
}

test "parser: comments and line endings between array elements" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_ok(
        &tree,
        "a = [ # one\r\n  1, # two\r\n  2 # three\r\n]\r\nb = [\r\n3,\r\n]\r\n",
    );
    const a = (try field(root, "a")).array;
    try expectEqual(@as(usize, 2), a.len);
    try expectEqual(@as(i64, 2), a[1].int);
    try expectEqual(@as(usize, 1), (try field(root, "b")).array.len);
}

test "parser: a comment inside an inline table is rejected" {
    // A comment runs to the end of the line, so the newline that ends it, which an inline
    // table may not contain, is the offending token.
    try expect_failure("a = { # c\n}\n", error.UnexpectedToken, 1, 10);
    try expect_failure("a = { b = 1 # c\n}\n", error.UnexpectedToken, 1, 16);
    try expect_failure("a = { b = 1, # c\n c = 2 }\n", error.UnexpectedToken, 1, 17);
}

test "parser: every prefix of a nested document ends in a parse error, never OutOfMemory" {
    const input =
        "a = [1, { b = \"x\", c.d = [[], [2]] }]\n[e]\nf = { g = [[[]]] }\n[[h]]\ni = 0x1f\n";
    var tree: ValueTree = undefined;
    for (0..input.len + 1) |len| {
        tree.init(std.testing.allocator);
        defer tree.deinit();

        var diag = Diagnostics.init(0, 0, "untouched", null);
        if (parse_with(&tree, input[0..len], options_default, &diag)) |_| {
            // A prefix ending at a statement boundary is itself a valid document.
        } else |err| {
            try expect(!std.mem.eql(u8, @errorName(err), "OutOfMemory"));
            try expect(diag.line >= 1);
        }
    }
}

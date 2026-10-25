//! Tests for `toml.parse(T, ...)` (plan 006 item 7, ADR 0005 sections 6 and 7): TOML text into a
//! Zig type through the parser and `reflect.parse`, with a zr-shaped config (tables, arrays of
//! tables, optionals, `core.Timestamp`), and the upgrade of reflect's path-only diagnostics to
//! the source `line:col` while the message is kept. Expected positions are counted by hand
//! from the test text. Parse-time variants are in `parser_test.zig`.

const std = @import("std");
const core = @import("../core.zig");
const reflect = @import("../reflect.zig");
const toml = @import("../toml.zig");
const assert = std.debug.assert;
const testing = std.testing;

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

const sentinel_line: u32 = 777;
const options: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };

const Server = struct { host: []const u8, port: u16 = 8080 };
const Task = struct {
    name: []const u8,
    cmd: []const u8,
    deps: []const []const u8 = &.{},
    timeout: ?u32 = null,
};
const Project = struct {
    title: []const u8,
    created: core.Timestamp,
    server: Server,
    tasks: []const Task,
};

const project_text =
    \\title = "zr"
    \\created = 2026-10-26T12:00:00Z
    \\
    \\[server]
    \\host = "localhost"
    \\
    \\[[tasks]]
    \\name = "build"
    \\cmd = "zig build"
    \\deps = ["fmt", "lint"]
    \\
    \\[[tasks]]
    \\name = "test"
    \\cmd = "zig build test"
    \\timeout = 30
    \\
;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

/// Parses `text` as `T` and asserts it fails with `err` at `line:col` and with a message that
/// contains `message_part`.
fn expect_fail(
    comptime T: type,
    text: []const u8,
    err: toml.ParseError,
    line: u32,
    col: u32,
    message_part: []const u8,
) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    try testing.expectError(err, toml.parse(T, testing.allocator, &tree, text, options, &diag));
    try testing.expectEqual(line, diag.line);
    try testing.expectEqual(col, diag.col);
    try testing.expect(std.mem.find(u8, diag.message(), message_part) != null);
}

test "parse: a zr-shaped config fills tables, arrays of tables, optionals and a timestamp" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const got = try toml.parse(Project, testing.allocator, &tree, project_text, options, &diag);
    try testing.expectEqual(sentinel_line, diag.line);
    try testing.expectEqualStrings("untouched", diag.message());

    try testing.expectEqualStrings("zr", got.title);
    try testing.expectEqual(core.Timestamp.Kind.instant, got.created.kind);
    try testing.expectEqual(@as(i64, 1_793_016_000), got.created.seconds);
    try testing.expectEqualStrings("localhost", got.server.host);
    try testing.expectEqual(@as(u16, 8080), got.server.port);
    try testing.expectEqual(@as(usize, 2), got.tasks.len);
    try testing.expectEqualStrings("build", got.tasks[0].name);
    try testing.expectEqual(@as(usize, 2), got.tasks[0].deps.len);
    try testing.expectEqualStrings("lint", got.tasks[0].deps[1]);
    try testing.expectEqual(@as(?u32, null), got.tasks[0].timeout);
    try testing.expectEqualStrings("zig build test", got.tasks[1].cmd);
    try testing.expectEqual(@as(usize, 0), got.tasks[1].deps.len);
    try testing.expectEqual(@as(?u32, 30), got.tasks[1].timeout);
}

test "parse: the result does not borrow from the input" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const text = try testing.allocator.dupe(u8, "host = \"abc\"\nport = 9\n");
    var diag = fresh_diag();
    const got = try toml.parse(Server, testing.allocator, &tree, text, options, &diag);
    @memset(text, 'x');
    testing.allocator.free(text);
    try testing.expectEqualStrings("abc", got.host);
    try testing.expectEqual(@as(u16, 9), got.port);
}

test "parse: a reflect type mismatch lands on the key of the value" {
    const text = "[[tasks]]\nname = 5\ncmd = \"c\"\n";
    const Doc = struct { tasks: []const Task };
    try expect_fail(Doc, text, error.TypeMismatch, 2, 1, "tasks[0].name");
}

test "parse: an element of an array lands on the element itself" {
    const text = "[[tasks]]\nname = \"a\"\ncmd = \"c\"\ndeps = [\"x\",\n  2]\n";
    const Doc = struct { tasks: []const Task };
    try expect_fail(Doc, text, error.TypeMismatch, 5, 3, "tasks[0].deps[1]");
}

test "parse: IntegerOutOfRange lands on the key, in a table, after CRLF lines" {
    const text = "[server]\r\nhost = \"h\"\r\nport = 70000\r\n";
    const Doc = struct { server: Server };
    try expect_fail(Doc, text, error.IntegerOutOfRange, 3, 1, "server.port");
}

test "parse: UnknownField and MissingField land on the table header key" {
    const unknown = "[server]\nhost = \"h\"\ncolour = 1\n";
    const Doc = struct { server: Server };
    try expect_fail(Doc, unknown, error.UnknownField, 1, 2, "unknown field");

    const missing = "\n  [server]\nport = 1\n";
    try expect_fail(Doc, missing, error.MissingField, 2, 4, "missing field");
}

test "parse: a root-level MissingField lands on the first byte" {
    try expect_fail(Server, "port = 1\n", error.MissingField, 1, 1, "missing field");
}

test "parse: a dotted-key table and an inline table are located at their key" {
    const Doc = struct { server: Server };
    try expect_fail(Doc, "server.host = 1\n", error.TypeMismatch, 1, 8, "server.host");
    try expect_fail(Doc, "server = { host = 1 }\n", error.TypeMismatch, 1, 12, "server.host");
}

test "parse: a syntax error keeps the parser's position and its own message" {
    try expect_fail(Server, "host = \"a\"\nport = \n", error.UnexpectedToken, 2, 8, "");
    try expect_fail(Server, "host = \"a\"\nhost = \"b\"\n", error.DuplicateKey, 2, 1, "");
}

test "parse: bytes_max and depth_max bound the input" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const small: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 4 };
    const result = toml.parse(Server, testing.allocator, &tree, "host = 'a'", small, &diag);
    try testing.expectError(error.InputTooLarge, result);
    try testing.expectEqual(@as(u32, 1), diag.line);

    const shallow: toml.ParseOptions = .{ .depth_max = 1, .bytes_max = 1 << 20 };
    const deep = toml.parse_value(testing.allocator, &tree, "[a]\nb = 1\n", shallow, &diag);
    try testing.expectError(error.TooDeep, deep);
}

test "parse_value: returns the root table and leaves tree.root alone" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const root = try toml.parse_value(testing.allocator, &tree, "a = 1\nb = 2\n", options, &diag);
    try testing.expect(root == .map);
    try testing.expectEqual(@as(u32, 2), root.map.count);
    try testing.expect(tree.root == .null);
    try testing.expectEqualStrings("untouched", diag.message());
}

test "parse: every allocation failing in turn leaks nothing and never succeeds wrongly" {
    var fail_index: usize = 0;
    var succeeded: u32 = 0;
    for (0..64) |_| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const gpa = failing.allocator();
        var tree: ValueTree = undefined;
        tree.init(gpa);
        defer tree.deinit();

        var diag = fresh_diag();
        const result = toml.parse(Project, gpa, &tree, project_text, options, &diag);
        if (result) |got| {
            try testing.expectEqualStrings("zr", got.title);
            succeeded += 1;
            if (!failing.has_induced_failure) break;
        } else |err| {
            // proof: only the failing allocator can fail this fixed, valid document.
            switch (err) {
                error.OutOfMemory => try testing.expect(failing.has_induced_failure),
                else => return err,
            }
        }
        fail_index += 1;
    }
    try testing.expect(succeeded >= 1);
    try testing.expect(fail_index >= 3);
}

fn has_name(comptime Set: type, comptime name: []const u8) bool {
    inline for (@typeInfo(Set).error_set.?) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "parse: ParseError holds every parser and reflect name and no stub name" {
    inline for (@typeInfo(reflect.ParseError).error_set.?) |entry| {
        try testing.expect(has_name(toml.ParseError, entry.name));
    }
    inline for (@typeInfo(toml.ParseValueError).error_set.?) |entry| {
        try testing.expect(has_name(toml.ParseError, entry.name));
    }
    try testing.expect(!has_name(toml.ParseError, "NotImplemented"));
    try testing.expect(!has_name(toml.Error, "NotImplemented"));
    try testing.expectEqual(@as(usize, 17), @typeInfo(toml.ParseValueError).error_set.?.len);
    try testing.expectEqual(@as(usize, 25), @typeInfo(toml.ParseError).error_set.?.len);
}

test "parse: a fuzz target never panics and a failure always has a position" {
    try testing.fuzz({}, fuzz_one, .{});
}

fn fuzz_one(_: void, smith: *testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const len = smith.slice(&buffer);
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const result = toml.parse(Project, testing.allocator, &tree, buffer[0..len], options, &diag);
    if (result) |_| {
        try testing.expectEqual(sentinel_line, diag.line);
    } else |_| {
        try testing.expect(diag.line >= 1);
        try testing.expect(diag.line != sentinel_line);
    }
}

fn locate_at(text: []const u8, segments: []const reflect.Segment) u32 {
    var path: reflect.Path = undefined;
    path.init();
    for (segments) |segment| path.push(segment);
    return toml.parser.locate(testing.allocator, text, options, &path);
}

test "locate: a path names keys, array elements, and stops at the deepest existing node" {
    const text = "a = 1\n[[t]]\nx = [10, 20]\n[[t]]\ny = {z = 1}\n";
    const t: reflect.Segment = .{ .key = "t" };
    const none: reflect.Segment = .none;
    const first: reflect.Segment = .{ .index = 0 };
    const second: reflect.Segment = .{ .index = 1 };

    try testing.expectEqual(@as(u32, 0), locate_at(text, &.{}));
    try testing.expectEqual(@as(u32, 0), locate_at(text, &.{none}));
    try testing.expectEqual(@as(u32, 0), locate_at(text, &.{.{ .key = "a" }}));
    try testing.expectEqual(@as(u32, 8), locate_at(text, &.{t}));
    try testing.expectEqual(@as(u32, 8), locate_at(text, &.{ t, first }));
    try testing.expectEqual(@as(u32, 12), locate_at(text, &.{ t, first, .{ .key = "x" } }));
    try testing.expectEqual(@as(u32, 27), locate_at(text, &.{ t, second }));
    try testing.expectEqual(@as(u32, 31), locate_at(text, &.{ t, second, .{ .key = "y" } }));
    try testing.expectEqual(@as(u32, 21), locate_at(text, &.{
        t, first, .{ .key = "x" }, .{ .index = 1 },
    }));
    // Past the end of the array, under a scalar, or under a missing key: the deepest node.
    try testing.expectEqual(@as(u32, 8), locate_at(text, &.{ t, .{ .index = 2 } }));
    try testing.expectEqual(@as(u32, 12), locate_at(text, &.{
        t, first, .{ .key = "x" }, .{ .index = 2 },
    }));
    try testing.expectEqual(@as(u32, 31), locate_at(text, &.{
        t, second, .{ .key = "y" }, .{ .key = "q" },
    }));
    // The inline table's own member is placed at its key.
    try testing.expectEqual(@as(u32, 36), locate_at(text, &.{
        t, second, .{ .key = "y" }, .{ .key = "z" },
    }));
}

test "locate: text that does not parse, or is over bytes_max, gives offset 0" {
    try testing.expectEqual(@as(u32, 0), locate_at("a = \n", &.{.{ .key = "a" }}));
    var path: reflect.Path = undefined;
    path.init();
    const small: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 2 };
    const got = toml.parser.locate(testing.allocator, "a = 1", small, &path);
    try testing.expectEqual(@as(u32, 0), got);
}

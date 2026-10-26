//! Tests for `toml.stringify(T, ...)` (plan 006 item 9, ADR 0005 section 7): a Zig value to TOML
//! text through `reflect.stringify` and the writer. Golden text is written by hand from the
//! contract (struct fields in declaration order, tables after the key/value lines), the output
//! parses back into the same Zig value, and each failure leaves the writer empty or names its
//! key path. Parse-side behaviour is in `parse_test.zig`.

const std = @import("std");
const core = @import("../core.zig");
const toml = @import("../toml.zig");
const testing = std.testing;

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

const sentinel_line: u32 = 777;
const write_options: toml.StringifyOptions = .{ .depth_max = 128 };
const parse_options: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };

const Server = struct { host: []const u8, port: u16 };
const Task = struct {
    name: []const u8,
    cmd: []const u8,
    deps: []const []const u8,
    timeout: ?u32,
};
const Project = struct {
    title: []const u8,
    created: core.Timestamp,
    server: Server,
    tasks: []const Task,
};

const tasks = [_]Task{
    .{ .name = "build", .cmd = "zig build", .deps = &.{ "fmt", "lint" }, .timeout = 5 },
    .{ .name = "test", .cmd = "zig build test", .deps = &.{}, .timeout = 30 },
};

const project: Project = .{
    .title = "zr",
    .created = .{
        .kind = .instant,
        .seconds = 1_793_016_000,
        .nanoseconds = 0,
        .offset_minutes = 0,
    },
    .server = .{ .host = "localhost", .port = 8080 },
    .tasks = &tasks,
};

const project_text =
    \\title = "zr"
    \\created = 2026-10-26T12:00:00Z
    \\
    \\[server]
    \\host = "localhost"
    \\port = 8080
    \\
    \\[[tasks]]
    \\name = "build"
    \\cmd = "zig build"
    \\deps = ["fmt", "lint"]
    \\timeout = 5
    \\
    \\[[tasks]]
    \\name = "test"
    \\cmd = "zig build test"
    \\deps = []
    \\timeout = 30
    \\
;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

test "stringify: a struct becomes key/value lines, then tables and arrays of tables" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try toml.stringify(Project, &tree, &aw.writer, project, write_options, &diag);
    try testing.expectEqualStrings(project_text, aw.written());
    try testing.expectEqual(sentinel_line, diag.line);
}

test "stringify: the text parses back into the same Zig value" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    try toml.stringify(Project, &tree, &aw.writer, project, write_options, &diag);
    var back_tree: ValueTree = undefined;
    back_tree.init(testing.allocator);
    defer back_tree.deinit();

    const got = try toml.parse(
        Project,
        testing.allocator,
        &back_tree,
        aw.written(),
        parse_options,
        &diag,
    );
    try testing.expectEqualStrings("zr", got.title);
    try testing.expectEqual(project.created, got.created);
    try testing.expectEqual(@as(u16, 8080), got.server.port);
    try testing.expectEqual(@as(usize, 2), got.tasks.len);
    try testing.expectEqualStrings("lint", got.tasks[0].deps[1]);
    try testing.expectEqual(@as(?u32, 30), got.tasks[1].timeout);
}

test "stringify: a null optional is Unrepresentable and names its key path" {
    const loose = [_]Task{.{ .name = "a", .cmd = "b", .deps = &.{}, .timeout = null }};
    const value: Project = .{
        .title = "t",
        .created = project.created,
        .server = project.server,
        .tasks = &loose,
    };
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = toml.stringify(Project, &tree, &aw.writer, value, write_options, &diag);
    try testing.expectError(error.Unrepresentable, result);
    try testing.expectEqualStrings(
        "tasks[0].timeout: null cannot be written as TOML",
        diag.message(),
    );
    try testing.expectEqual(core.diagnostics.position_none, diag.line);
}

test "stringify: a type that is not a table is RootNotTable" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const result = toml.stringify(u32, &tree, &aw.writer, 7, write_options, &diag);
    try testing.expectError(error.RootNotTable, result);
    try testing.expectEqualStrings("", aw.written());
}

test "stringify: reflect's InvalidUtf8 writes nothing" {
    const Doc = struct { text: []const u8 };
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const doc: Doc = .{ .text = "a\xffb" };
    const result = toml.stringify(Doc, &tree, &aw.writer, doc, write_options, &diag);
    try testing.expectError(error.InvalidUtf8, result);
    try testing.expectEqualStrings("", aw.written());
    try testing.expect(std.mem.startsWith(u8, diag.message(), "text: invalid UTF-8 at byte 1"));
}

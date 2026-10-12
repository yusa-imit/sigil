//! Tests for `json.parseFile`/`json.stringifyFile` (plan 004 item 9, ADR 0003 section 9) on a
//! real directory from `std.testing.tmpDir`, driven by `std.testing.io`. Golden file text is
//! written by hand from the contract. Every `ParseFileError`/`StringifyFileError` name that the
//! file layer adds is provoked: the ones a temp directory can cause (`FileNotFound`,
//! `InputTooLarge`) through the file system, and the ones it cannot (`AccessDenied`,
//! `ReadFailed`, `NoSpaceLeft`, `WriteFailed`, `Canceled`) through the pure std-error mapping
//! tables. `diag` is written exactly once per error and never on success.

const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json.zig");
const file = @import("file.zig");
const testing = std.testing;
const Io = std.Io;

const Diagnostics = core.Diagnostics;
const position_none = core.diagnostics.position_none;
const sentinel_line: u32 = 777;

const Config = struct { port: u16, name: []const u8 };
const Ratio = struct { ratio: f64 };

const parse_options: json.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};

const minified: json.StringifyOptions = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = 128,
};

fn sentinel_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, sentinel_line, "untouched", null);
}

fn parse_in(
    dir: Io.Dir,
    arena: std.mem.Allocator,
    sub_path: []const u8,
    options: json.ParseOptions,
    diag: *Diagnostics,
) json.ParseFileError!Config {
    return json.parseFile(Config, testing.io, arena, dir, sub_path, options, diag);
}

fn stringify_in(
    dir: Io.Dir,
    arena: std.mem.Allocator,
    sub_path: []const u8,
    value: anytype,
    diag: *Diagnostics,
) json.StringifyFileError!void {
    return json.stringifyFile(testing.io, arena, dir, sub_path, value, minified, diag);
}

fn write_text(dir: Io.Dir, sub_path: []const u8, text: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = text });
}

fn read_text(dir: Io.Dir, sub_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(testing.io, sub_path, gpa, .limited(1 << 16));
}

test "json file: stringifyFile writes golden text plus one newline and parseFile reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag = sentinel_diag();

    const value: Config = .{ .port = 8080, .name = "sigil" };
    try stringify_in(tmp.dir, arena, "app.json", value, &diag);

    const text = try read_text(tmp.dir, "app.json", testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"port\":8080,\"name\":\"sigil\"}\n", text);

    const parsed = try parse_in(tmp.dir, arena, "app.json", parse_options, &diag);
    try testing.expectEqual(@as(u16, 8080), parsed.port);
    try testing.expectEqualStrings("sigil", parsed.name);
    try testing.expectEqual(sentinel_line, diag.line);
}

test "json file: stringifyFile truncates an existing longer file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();
    try write_text(tmp.dir, "app.json", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");

    const value: Config = .{ .port = 1, .name = "a" };
    try stringify_in(tmp.dir, arena_state.allocator(), "app.json", value, &diag);

    const text = try read_text(tmp.dir, "app.json", testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"port\":1,\"name\":\"a\"}\n", text);
}

test "json file: parseFile of a missing file is FileNotFound and writes diag once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();

    const result = parse_in(tmp.dir, arena_state.allocator(), "nope.json", parse_options, &diag);
    try testing.expectError(error.FileNotFound, result);
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
    try testing.expect(diag.message().len > 0);
}

test "json file: bytes_max is inclusive and one byte more is InputTooLarge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"port\":7,\"name\":\"n\"}";
    try write_text(tmp.dir, "edge.json", text);
    var options = parse_options;
    var diag = sentinel_diag();

    options.bytes_max = text.len;
    const edge = try parse_in(tmp.dir, arena, "edge.json", options, &diag);
    try testing.expectEqual(@as(u16, 7), edge.port);
    try testing.expectEqual(sentinel_line, diag.line);

    options.bytes_max = text.len - 1;
    const over = parse_in(tmp.dir, arena, "edge.json", options, &diag);
    try testing.expectError(error.InputTooLarge, over);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(diag.message().len > 0);
}

test "json file: a malformed file reports line and column" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();
    try write_text(tmp.dir, "bad.json", "{\n  \"port\": tru,\n  \"name\": \"x\"\n}");

    const result = parse_in(tmp.dir, arena_state.allocator(), "bad.json", parse_options, &diag);
    try testing.expect(std.meta.isError(result));
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expect(diag.col >= 1);
    try testing.expect(diag.message().len > 0);
}

test "json file: a type mismatch in a file is located at its source line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();
    try write_text(tmp.dir, "mismatch.json", "{\n  \"port\": 80,\n  \"name\": 5\n}");

    const arena = arena_state.allocator();
    const result = parse_in(tmp.dir, arena, "mismatch.json", parse_options, &diag);
    try testing.expectError(error.TypeMismatch, result);
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expectEqual(@as(u32, 11), diag.col);
}

test "json file: stringifyFile into a missing directory is FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();

    const value: Config = .{ .port = 1, .name = "a" };
    const result = stringify_in(tmp.dir, arena_state.allocator(), "no/such/app.json", value, &diag);
    try testing.expectError(error.FileNotFound, result);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(diag.message().len > 0);
}

test "json file: a value JSON cannot represent is Unrepresentable and writes diag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag = sentinel_diag();

    const value: Ratio = .{ .ratio = std.math.nan(f64) };
    const result = stringify_in(tmp.dir, arena_state.allocator(), "nan.json", value, &diag);
    try testing.expectError(error.Unrepresentable, result);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(diag.message().len > 0);
}

test "json file: stringifyFile runs out of arena memory as OutOfMemory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var diag = sentinel_diag();

    const value: Config = .{ .port = 1, .name = "a" };
    const result = stringify_in(tmp.dir, fixed.allocator(), "oom.json", value, &diag);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(diag.message().len > 0);
}

test "json file: read errors map to the documented names" {
    const cases = [_]struct { std_error: Io.Dir.ReadFileAllocError, mapped: file.ReadError }{
        .{ .std_error = error.OutOfMemory, .mapped = error.OutOfMemory },
        .{ .std_error = error.Canceled, .mapped = error.Canceled },
        .{ .std_error = error.FileNotFound, .mapped = error.FileNotFound },
        .{ .std_error = error.AccessDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.PermissionDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.StreamTooLong, .mapped = error.InputTooLarge },
        .{ .std_error = error.FileTooBig, .mapped = error.InputTooLarge },
        .{ .std_error = error.IsDir, .mapped = error.ReadFailed },
        .{ .std_error = error.SystemResources, .mapped = error.ReadFailed },
    };
    for (cases) |case| {
        try testing.expectEqual(case.mapped, file.map_read_error(case.std_error));
    }
}

test "json file: create errors map to the documented names" {
    const cases = [_]struct { std_error: Io.File.OpenError, mapped: file.WriteError }{
        .{ .std_error = error.Canceled, .mapped = error.Canceled },
        .{ .std_error = error.FileNotFound, .mapped = error.FileNotFound },
        .{ .std_error = error.AccessDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.PermissionDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.ReadOnlyFileSystem, .mapped = error.AccessDenied },
        .{ .std_error = error.NoSpaceLeft, .mapped = error.NoSpaceLeft },
        .{ .std_error = error.IsDir, .mapped = error.WriteFailed },
        .{ .std_error = error.SymLinkLoop, .mapped = error.WriteFailed },
    };
    for (cases) |case| {
        try testing.expectEqual(case.mapped, file.map_create_error(case.std_error));
    }
}

test "json file: write errors map to the documented names" {
    const cases = [_]struct { std_error: Io.File.Writer.Error, mapped: file.WriteError }{
        .{ .std_error = error.Canceled, .mapped = error.Canceled },
        .{ .std_error = error.NoSpaceLeft, .mapped = error.NoSpaceLeft },
        .{ .std_error = error.DiskQuota, .mapped = error.NoSpaceLeft },
        .{ .std_error = error.AccessDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.PermissionDenied, .mapped = error.AccessDenied },
        .{ .std_error = error.BrokenPipe, .mapped = error.WriteFailed },
        .{ .std_error = error.InputOutput, .mapped = error.WriteFailed },
    };
    for (cases) |case| {
        try testing.expectEqual(case.mapped, file.map_write_error(case.std_error));
    }
}

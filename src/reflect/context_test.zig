//! reflect/context tests — `Path`, `Context.fail` message rendering and `Context.parse_child`
//! (ADR 0002 sections 1-3): the exact grammar, the 128-byte reason cut, the path tail budget,
//! depth and path restoration, and a seeded model that compares all three after every step.
//! Split from `context.zig` to keep both files under the tidy file-length limit.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const nesting_max = core.value.nesting_max;
const position_none = core.diagnostics.position_none;
const Context = context_mod.Context;
const Path = context_mod.Path;
const Segment = context_mod.Segment;
const ParseError = context_mod.ParseError;
const reason_len_max = context_mod.reason_len_max;
const testing = std.testing;
const Map = core.Map;

const Fixture = struct {
    tree: ValueTree,
    diag: Diagnostics,
    path: Path,
    context: Context,

    fn begin(f: *Fixture) void {
        f.tree.init(testing.allocator);
        f.diag = sentinel();
        f.path.init();
        f.context.init(&f.tree, &f.diag, &f.path);
    }

    fn end(f: *Fixture) void {
        f.tree.deinit();
    }

    /// Pushes `segments` and sets the depth to match, as a real parse would have.
    fn enter(f: *Fixture, segments: []const Segment) void {
        for (segments) |segment| f.path.push(segment);
        f.context.depth = @intCast(segments.len);
    }
};

fn sentinel() Diagnostics {
    return Diagnostics.init(7, 9, "untouched", null);
}

fn expect_untouched(f: *const Fixture) !void {
    try testing.expectEqual(@as(u32, 7), f.diag.line);
    try testing.expectEqual(@as(u32, 9), f.diag.col);
    try testing.expectEqualStrings("untouched", f.diag.message());
    try testing.expect(!f.context.diag_written);
}

fn expect_written(f: *const Fixture, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, f.diag.message());
    try testing.expectEqual(position_none, f.diag.line);
    try testing.expectEqual(position_none, f.diag.col);
    try testing.expect(f.diag.snippet_text() == null);
    try testing.expect(f.context.diag_written);
    try testing.expect(f.diag.message().len <= core.diagnostics.default_limits.message_len_max);
}

fn expect_restored(f: *const Fixture, count: u32, depth: u32) !void {
    try testing.expectEqual(count, f.path.count);
    try testing.expectEqual(depth, f.context.depth);
}

/// Fails a fresh context sitting at `segments` with `reason` and checks the message.
fn expect_rendered(segments: []const Segment, reason: []const u8, expected: []const u8) !void {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    f.enter(segments);
    const err = f.context.fail(error.InvalidValue, "{s}", .{reason});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), err);
    try expect_written(&f, expected);
}

test "path: push stores segments in order and pop restores the count" {
    var path: Path = undefined;
    path.init();
    try testing.expectEqual(@as(u32, 0), path.count);
    path.push(.{ .key = "a" });
    path.push(.{ .index = 5 });
    path.push(.none);
    try testing.expectEqual(@as(u32, 3), path.count);
    try testing.expectEqualStrings("a", path.segments[0].key);
    try testing.expectEqual(@as(u64, 5), path.segments[1].index);
    try testing.expect(path.segments[2] == .none);
    path.pop();
    try testing.expectEqual(@as(u32, 2), path.count);
    path.push(.{ .key = "b" });
    try testing.expectEqual(@as(u32, 3), path.count);
    try testing.expectEqualStrings("b", path.segments[2].key);
    path.pop();
    path.pop();
    path.pop();
    try testing.expectEqual(@as(u32, 0), path.count);
}

test "path: accepts exactly nesting_max segments" {
    var path: Path = undefined;
    path.init();
    for (0..nesting_max) |index| path.push(.{ .index = index });
    try testing.expectEqual(nesting_max, path.count);
    try testing.expectEqual(@as(u64, nesting_max - 1), path.segments[nesting_max - 1].index);
    for (0..nesting_max) |_| path.pop();
    try testing.expectEqual(@as(u32, 0), path.count);
}

test "context: init starts at depth zero with nothing written" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    try testing.expectEqual(@as(u32, 0), f.context.depth);
    try testing.expectEqual(@as(u32, 0), f.path.count);
    try testing.expect(!f.context.diag_written);
    try testing.expect(f.context.tree == &f.tree);
    try testing.expect(f.context.diag == &f.diag);
    try testing.expect(f.context.path == &f.path);
}

test "context: fail returns every variant it is given and writes the diagnostics once" {
    const variants = @typeInfo(ParseError).error_set.?;
    try testing.expectEqual(@as(usize, 11), variants.len);
    inline for (variants) |variant| {
        const err = @field(ParseError, variant.name);
        var f: Fixture = undefined;
        f.begin();
        defer f.end();
        try expect_untouched(&f);
        try testing.expectEqual(err, f.context.fail(err, "reason {d}", .{3}));
        try expect_written(&f, "reason 3");
    }
}

test "context: fail renders the root without a path prefix" {
    try expect_rendered(&.{}, "expected string, found int", "expected string, found int");
    try expect_rendered(&.{.none}, "boom", "boom");
    try expect_rendered(&.{ .none, .none }, "boom", "boom");
}

test "context: fail renders bare keys with dots and indices in brackets" {
    try expect_rendered(&.{.{ .key = "name" }}, "boom", "name: boom");
    try expect_rendered(&.{ .{ .key = "tls" }, .{ .key = "cert" } }, "boom", "tls.cert: boom");
    try expect_rendered(&.{
        .{ .key = "servers" }, .{ .index = 2 }, .{ .key = "host" },
    }, "boom", "servers[2].host: boom");
    try expect_rendered(&.{.{ .key = "Ab_9-z" }}, "boom", "Ab_9-z: boom");
    const segments: []const Segment = &.{ .{ .key = "a" }, .{ .index = 0 }, .{ .index = 1 } };
    try expect_rendered(segments, "boom", "a[0][1]: boom");
}

test "context: fail renders a leading index and its follower" {
    try expect_rendered(&.{.{ .index = 3 }}, "boom", "[3]: boom");
    try expect_rendered(&.{ .{ .index = 3 }, .{ .key = "x" } }, "boom", "[3].x: boom");
    const largest: []const Segment = &.{.{ .index = std.math.maxInt(u64) }};
    try expect_rendered(largest, "boom", "[18446744073709551615]: boom");
}

test "context: fail skips none segments and keeps the first rendered key bare" {
    try expect_rendered(&.{ .{ .key = "a" }, .none, .{ .key = "b" } }, "boom", "a.b: boom");
    try expect_rendered(&.{ .none, .{ .key = "a" } }, "boom", "a: boom");
    const mixed: []const Segment = &.{ .none, .{ .index = 1 }, .none, .{ .key = "a" } };
    try expect_rendered(mixed, "boom", "[1].a: boom");
}

test "context: fail quotes keys that are empty or not word characters" {
    try expect_rendered(&.{.{ .key = "" }}, "boom", "[\"\"]: boom");
    const labels: []const Segment = &.{ .{ .key = "labels" }, .{ .key = "a.b" } };
    try expect_rendered(labels, "boom", "labels[\"a.b\"]: boom");
    try expect_rendered(&.{.{ .key = "a.b" }}, "boom", "[\"a.b\"]: boom");
    try expect_rendered(&.{.{ .key = "a b" }}, "boom", "[\"a b\"]: boom");
    try expect_rendered(&.{ .{ .index = 3 }, .{ .key = "a.b" } }, "boom", "[3][\"a.b\"]: boom");
    const middle: []const Segment = &.{ .{ .key = "a" }, .{ .key = "" }, .{ .key = "c" } };
    try expect_rendered(middle, "boom", "a[\"\"].c: boom");
    try expect_rendered(&.{.{ .key = "\xc3\xa9" }}, "boom", "[\"\xc3\xa9\"]: boom");
}

test "context: fail escapes quote, backslash, control bytes and 0x7f inside quoted keys" {
    try expect_rendered(&.{.{ .key = "a\"b" }}, "boom", "[\"a\\\"b\"]: boom");
    try expect_rendered(&.{.{ .key = "a\\b" }}, "boom", "[\"a\\\\b\"]: boom");
    try expect_rendered(&.{.{ .key = "\x01" }}, "boom", "[\"\\x01\"]: boom");
    try expect_rendered(&.{.{ .key = "a\nb" }}, "boom", "[\"a\\x0ab\"]: boom");
    try expect_rendered(&.{.{ .key = "\x1f\x00" }}, "boom", "[\"\\x1f\\x00\"]: boom");
    try expect_rendered(&.{.{ .key = "\x7f" }}, "boom", "[\"\\x7f\"]: boom");
    try expect_rendered(&.{.{ .key = " " }}, "boom", "[\" \"]: boom");
}

test "context: fail cuts a long reason to 128 bytes ending in the marker" {
    const at_limit = "x" ** reason_len_max;
    try expect_rendered(&.{}, at_limit, at_limit);
    const cut = "x" ** (reason_len_max - 3) ++ "...";
    try expect_rendered(&.{}, at_limit ++ "y", cut);
    try expect_rendered(&.{}, "x" ** 500, cut);
    try expect_rendered(&.{.{ .key = "k" }}, "x" ** 200, "k: " ++ cut);
}

test "context: fail keeps the tail of a path that exceeds its budget" {
    // Budget is message_len_max - reason.len - 2 = 256 - 4 - 2 = 250.
    const fits = "k" ** 250;
    try expect_rendered(&.{.{ .key = fits }}, "boom", fits ++ ": boom");
    const over = "k" ** 251;
    try expect_rendered(&.{.{ .key = over }}, "boom", "..." ++ "k" ** 247 ++ ": boom");
}

test "context: fail with a maximal reason leaves a 126-byte path budget" {
    const reason = "r" ** reason_len_max;
    const fits = "p" ** 126;
    try expect_rendered(&.{.{ .key = fits }}, reason, fits ++ ": " ++ reason);
    const over = "p" ** 127;
    try expect_rendered(&.{.{ .key = over }}, reason, "..." ++ "p" ** 123 ++ ": " ++ reason);
}

test "context: fail on a 128-segment path keeps the most specific segments" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    for (0..nesting_max - 2) |_| f.path.push(.{ .index = 0 });
    f.path.push(.{ .index = 7 });
    f.path.push(.{ .key = "host" });
    f.context.depth = nesting_max;
    const reason = "expected string, found int";
    const err = f.context.fail(error.TypeMismatch, "expected {s}, found {s}", .{ "string", "int" });
    try testing.expectEqual(@as(ParseError, error.TypeMismatch), err);
    const message = f.diag.message();
    try testing.expectEqual(@as(usize, 256), message.len);
    try testing.expect(std.mem.startsWith(u8, message, "..."));
    try testing.expect(std.mem.endsWith(u8, message, "[7].host: " ++ reason));
    try testing.expect(f.context.diag_written);
}

test "context: fail on a 128-segment index path fills the message to exactly the limit" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    var full: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&full);
    for (0..nesting_max) |index| {
        f.path.push(.{ .index = index });
        try writer.print("[{d}]", .{index});
    }
    f.context.depth = nesting_max;
    const err = f.context.fail(error.InvalidValue, "boom", .{});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), err);
    const rendered = writer.buffered();
    try testing.expect(rendered.len > 250);
    try testing.expectEqual(@as(usize, 256), f.diag.message().len);
    try testing.expect(std.mem.startsWith(u8, f.diag.message(), "..."));
    try testing.expectEqualStrings(rendered[rendered.len - 247 ..], f.diag.message()[3..250]);
    try testing.expectEqualStrings(": boom", f.diag.message()[250..]);
}

test "context: parse_child parses at depth zero and restores path and depth" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    const port = try f.context.parse_child(u8, .{ .key = "port" }, .{ .int = 80 });
    try testing.expectEqual(@as(u8, 80), port);
    try expect_restored(&f, 0, 0);
    try expect_untouched(&f);
}

test "context: parse_child failure carries the child segment and restores path and depth" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    const result = f.context.parse_child(u8, .{ .key = "port" }, .{ .int = 300 });
    try testing.expectError(error.IntegerOutOfRange, result);
    try expect_written(&f, "port: 300 is out of range for u8");
    try expect_restored(&f, 0, 0);
}

test "context: parse_child extends the path of the caller and restores it" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    f.enter(&.{ .{ .key = "servers" }, .{ .index = 2 } });
    const result = f.context.parse_child(bool, .{ .key = "tls" }, .{ .int = 1 });
    try testing.expectError(error.TypeMismatch, result);
    try expect_written(&f, "servers[2].tls: expected bool, found int");
    try expect_restored(&f, 2, 2);
    try testing.expectEqualStrings("servers", f.path.segments[0].key);
    try testing.expectEqual(@as(u64, 2), f.path.segments[1].index);
}

test "context: parse_child with a none segment adds no text and still restores" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    const result = f.context.parse_child(u8, .none, .{ .int = 300 });
    try testing.expectError(error.IntegerOutOfRange, result);
    try expect_written(&f, "300 is out of range for u8");
    try expect_restored(&f, 0, 0);
}

test "context: parse_child of an optional adds no segment and no depth of its own" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    const absent = try f.context.parse_child(?u8, .{ .key = "port" }, .null);
    try testing.expectEqual(@as(?u8, null), absent);
    const present = try f.context.parse_child(?u8, .{ .key = "port" }, .{ .int = 9 });
    try testing.expectEqual(@as(?u8, 9), present);
    try expect_untouched(&f);
    const result = f.context.parse_child(?u8, .{ .key = "port" }, .{ .int = 300 });
    try testing.expectError(error.IntegerOutOfRange, result);
    try expect_written(&f, "port: 300 is out of range for u8");
    try expect_restored(&f, 0, 0);
}

test "context: parse_child at depth nesting_max - 1 succeeds and at nesting_max is TooDeep" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    f.context.depth = nesting_max - 1;
    const value = try f.context.parse_child(u8, .{ .key = "x" }, .{ .int = 5 });
    try testing.expectEqual(@as(u8, 5), value);
    try expect_restored(&f, 0, nesting_max - 1);
    try expect_untouched(&f);

    f.context.depth = nesting_max;
    const refused = f.context.parse_child(u8, .{ .key = "x" }, .{ .int = 5 });
    try testing.expectError(error.TooDeep, refused);
    try expect_written(&f, "exceeds nesting depth limit 128");
    try expect_restored(&f, 0, nesting_max);
}

test "context: TooDeep names the path of the caller, not the refused child" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    f.enter(&.{.{ .key = "deep" }});
    f.context.depth = nesting_max;
    const refused = f.context.parse_child(u8, .{ .key = "child" }, .null);
    try testing.expectError(error.TooDeep, refused);
    try expect_written(&f, "deep: exceeds nesting depth limit 128");
    try expect_restored(&f, 1, nesting_max);
}

test "context: a child of a full 127-segment path fits and a full 128-segment path is TooDeep" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    for (0..nesting_max - 1) |index| f.path.push(.{ .index = index });
    f.context.depth = nesting_max - 1;
    const key: Segment = .{ .key = "k" };
    try testing.expectEqual(@as(u8, 1), try f.context.parse_child(u8, key, .{ .int = 1 }));
    try expect_restored(&f, nesting_max - 1, nesting_max - 1);
    const out_of_range = f.context.parse_child(u8, key, .{ .int = -1 });
    try testing.expectError(error.IntegerOutOfRange, out_of_range);
    try expect_restored(&f, nesting_max - 1, nesting_max - 1);
    try testing.expect(std.mem.endsWith(u8, f.diag.message(), "k: -1 is out of range for u8"));

    f.path.push(.{ .key = "last" });
    f.context.depth = nesting_max;
    f.context.diag_written = false;
    try testing.expectError(error.TooDeep, f.context.parse_child(u8, key, .{ .int = 1 }));
    try expect_restored(&f, nesting_max, nesting_max);
    const message = f.diag.message();
    try testing.expectEqual(@as(usize, 256), message.len);
    const tail = "[126].last: exceeds nesting depth limit 128";
    try testing.expect(std.mem.endsWith(u8, message, tail));
}

// ---------------------------------------------------------------------------------------------
// Seeded model: a plain array stack and a straight-line renderer written from ADR 0002 section
// 3, compared with `Path`, `Context.fail` and `Context.parse_child` after every step.
// ---------------------------------------------------------------------------------------------

const key_pool = [_][]const u8{
    "a", "b-c", "", "a.b", "q\"x", "\\", "\x01", "\x7f", "\xc3\xa9", "k_9",
};

const Model = struct {
    segments: [nesting_max]Segment,
    len: u32,

    fn render(model: *const Model, w: *std.Io.Writer) !void {
        var first = true;
        for (model.segments[0..model.len]) |segment| {
            switch (segment) {
                .none => continue,
                .index => |n| try w.print("[{d}]", .{n}),
                .key => |k| try render_key(w, k, first),
            }
            first = false;
        }
    }

    /// The message `fail` must produce for `reason`, written into `out`.
    fn expected(model: *const Model, out: []u8, reason: []const u8) ![]const u8 {
        var path_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&path_buf);
        try model.render(&w);
        const path = w.buffered();
        const budget = 256 - reason.len - 2;
        var out_w = std.Io.Writer.fixed(out);
        if (path.len == 0) {
            try out_w.writeAll(reason);
        } else if (path.len <= budget) {
            try out_w.print("{s}: {s}", .{ path, reason });
        } else {
            try out_w.print("...{s}: {s}", .{ path[path.len - (budget - 3) ..], reason });
        }
        return out_w.buffered();
    }
};

fn render_key(w: *std.Io.Writer, key: []const u8, first: bool) !void {
    var bare = key.len > 0;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') bare = false;
    }
    if (bare) {
        if (!first) try w.writeByte('.');
        return w.writeAll(key);
    }
    try w.writeAll("[\"");
    for (key) |byte| {
        if (byte == '"' or byte == '\\') {
            try w.writeByte('\\');
            try w.writeByte(byte);
        } else if (byte < 0x20 or byte == 0x7f) {
            try w.print("\\x{x:0>2}", .{byte});
        } else try w.writeByte(byte);
    }
    try w.writeAll("\"]");
}

fn random_segment(random: std.Random) Segment {
    return switch (random.uintLessThan(u8, 3)) {
        0 => .{ .key = key_pool[random.uintLessThan(usize, key_pool.len)] },
        1 => .{ .index = random.int(u64) >> random.uintLessThan(u6, 60) },
        else => .none,
    };
}

fn step_child(f: *Fixture, model: *Model, random: std.Random) !void {
    const segment = random_segment(random);
    const fits = random.boolean();
    const value: Value = .{ .int = if (fits) 5 else 300 };
    f.diag = sentinel();
    f.context.diag_written = false;
    const result = f.context.parse_child(u8, segment, value);
    try expect_restored(f, model.len, model.len);
    var buf: [256]u8 = undefined;
    if (model.len >= nesting_max) {
        try testing.expectError(error.TooDeep, result);
        try testing.expectEqualStrings(
            try model.expected(&buf, "exceeds nesting depth limit 128"),
            f.diag.message(),
        );
    } else if (fits) {
        try testing.expectEqual(@as(u8, 5), try result);
        try expect_untouched(f);
    } else {
        try testing.expectError(error.IntegerOutOfRange, result);
        var child = model.*;
        child.segments[child.len] = segment;
        child.len += 1;
        const reason = "300 is out of range for u8";
        try testing.expectEqualStrings(try child.expected(&buf, reason), f.diag.message());
    }
}

fn step_fail(f: *Fixture, model: *const Model) !void {
    f.diag = sentinel();
    f.context.diag_written = false;
    const err = f.context.fail(error.InvalidValue, "r{d}", .{model.len});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), err);
    var reason_buf: [16]u8 = undefined;
    const reason = try std.fmt.bufPrint(&reason_buf, "r{d}", .{model.len});
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try model.expected(&buf, reason), f.diag.message());
    try testing.expect(f.context.diag_written);
}

test "context: seeded model of path stack, fail rendering and parse_child agree at every step" {
    var f: Fixture = undefined;
    f.begin();
    defer f.end();
    var prng = std.Random.DefaultPrng.init(0x51617);
    const random = prng.random();
    var model: Model = .{ .segments = undefined, .len = 0 };
    var step: u32 = 0;
    while (step < 4000) : (step += 1) {
        switch (random.uintLessThan(u8, 10)) {
            0...4 => if (model.len < nesting_max) {
                const segment = random_segment(random);
                model.segments[model.len] = segment;
                model.len += 1;
                f.path.push(segment);
            },
            5, 6 => if (model.len > 0) {
                model.len -= 1;
                f.path.pop();
            },
            7, 8 => try step_fail(&f, &model),
            else => try step_child(&f, &model, random),
        }
        f.context.depth = model.len;
        try testing.expectEqual(model.len, f.path.count);
        try testing.expect(f.path.count <= f.context.depth and f.context.depth <= nesting_max);
    }
}

test "write_diagnostic: renders the path grammar without a Context and at position_none" {
    var path: Path = undefined;
    path.init();
    path.push(.{ .key = "servers" });
    path.push(.{ .index = 2 });
    path.push(.{ .key = "host name" });
    var diag = sentinel();
    context_mod.write_diagnostic(&diag, &path, "cannot write {s}", .{"bytes"});
    try testing.expectEqualStrings("servers[2][\"host name\"]: cannot write bytes", diag.message());
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
    try testing.expect(diag.snippet_text() == null);

    path.init();
    context_mod.write_diagnostic(&diag, &path, "root only", .{});
    try testing.expectEqualStrings("root only", diag.message());
}

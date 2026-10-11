//! reflect/parse trace tests (plan 004 item 8, ADR 0003 section 8): `parse_traced` is `parse`
//! plus a `*Path` that receives a copy of the live key path when the first diagnostic message
//! is written, because `Context` unwinds its own path on the way out and a format layer needs
//! the path to re-locate the error in its source. These tests pin what the copy holds for
//! each error site (the failing value, the struct for `MissingField`/`UnknownField`, hook
//! segments, `TooDeep`), that success leaves the trace empty, and that `parse` and
//! `parse_traced` agree on the error and the message in every case.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const Context = context_mod.Context;
const Path = context_mod.Path;
const Segment = context_mod.Segment;
const ParseError = context_mod.ParseError;
const StringifyError = context_mod.StringifyError;
const assert = std.debug.assert;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const nesting_max = core.value.nesting_max;
const parse_traced = parse_mod.parse_traced;
const Rig = rig_mod.Rig;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;
const Fleet = rig_mod.Fleet;
const Point = rig_mod.Point;
const Wrapper = rig_mod.Wrapper;

fn key(name: []const u8) Segment {
    return .{ .key = name };
}

fn index(number: u64) Segment {
    return .{ .index = number };
}

/// `parse_traced` with a fresh sentinel diagnostics and an empty trace.
fn run(rig: *Rig, comptime T: type, value: Value, trace: *Path) ParseError!T {
    rig.diag = sentinel();
    trace.init();
    return parse_traced(T, &rig.tree, value, &rig.diag, trace);
}

fn expect_trace(trace: *const Path, expected: []const Segment) !void {
    try testing.expectEqual(@as(u32, @intCast(expected.len)), trace.count);
    for (expected, trace.segments[0..expected.len]) |want, got| {
        try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .key => |text| try testing.expectEqualStrings(text, got.key),
            .index => |number| try testing.expectEqual(number, got.index),
            .none => {},
        }
    }
}

/// A fleet of three servers whose last `host` is an int.
fn fleet_with_bad_host(rig: *Rig) !Value {
    const hosts = [_]Value{ str("a"), str("b"), int(5) };
    var servers: [3]Value = undefined;
    for (hosts, &servers) |host, *slot| slot.* = try rig.obj(&.{kv("host", host)});
    return rig.obj(&.{ kv("name", str("f")), kv("servers", try rig.arr(&servers)) });
}

test "trace: a type mismatch in a slice element records the whole path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const value = try fleet_with_bad_host(&rig);

    try testing.expectError(error.TypeMismatch, run(&rig, Fleet, value, &trace));
    try expect_trace(&trace, &.{ key("servers"), index(2), key("host") });
    try testing.expectEqualStrings(
        "servers[2].host: expected string, found int",
        rig.diag.message(),
    );
    // `parse_traced` itself does not upgrade the position; the format layer does.
    try testing.expectEqual(position_none, rig.diag.line);
    try testing.expectEqual(position_none, rig.diag.col);
}

test "trace: MissingField records the struct that lacks the field, not the field" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const good = try rig.obj(&.{kv("host", str("a"))});
    const bad = try rig.obj(&.{kv("port", int(1))});
    const servers = try rig.arr(&.{ good, bad });
    const value = try rig.obj(&.{ kv("name", str("f")), kv("servers", servers) });

    try testing.expectError(error.MissingField, run(&rig, Fleet, value, &trace));
    try expect_trace(&trace, &.{ key("servers"), index(1) });
    try testing.expectEqualStrings("servers[1]: missing field \"host\"", rig.diag.message());

    const root = try rig.obj(&.{kv("name", str("f"))});
    try testing.expectError(error.MissingField, run(&rig, Fleet, root, &trace));
    try expect_trace(&trace, &.{});
    try testing.expectEqualStrings("missing field \"servers\"", rig.diag.message());
}

test "trace: UnknownField records the struct that holds the unknown key" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const server = try rig.obj(&.{ kv("host", str("h")), kv("bogus", int(1)) });
    const value = try rig.obj(&.{kv("server", server)});

    try testing.expectError(error.UnknownField, run(&rig, Wrapper, value, &trace));
    try expect_trace(&trace, &.{key("server")});
    try testing.expectEqualStrings("server: unknown field \"bogus\"", rig.diag.message());

    const top = try rig.obj(&.{ kv("x", int(1)), kv("y", int(2)), kv("z", int(3)) });
    try testing.expectError(error.UnknownField, run(&rig, Point, top, &trace));
    try expect_trace(&trace, &.{});
}

test "trace: a failure at the root leaves the trace empty and the live path unwound" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;

    try testing.expectError(error.TypeMismatch, run(&rig, Point, str("x"), &trace));
    try expect_trace(&trace, &.{});
    try testing.expectEqualStrings("expected map, found string", rig.diag.message());
}

test "trace: a trace that held an older path is overwritten, count included" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    rig.diag = sentinel();
    trace.init();
    for (0..3) |step| trace.push(index(90 + step));

    const value = try rig.obj(&.{ kv("x", int(1)), kv("y", str("no")) });
    const first = parse_traced(Point, &rig.tree, value, &rig.diag, &trace);
    try testing.expectError(error.TypeMismatch, first);
    try expect_trace(&trace, &.{key("y")});

    rig.diag = sentinel();
    const second = parse_traced(Point, &rig.tree, int(1), &rig.diag, &trace);
    try testing.expectError(error.TypeMismatch, second);
    try expect_trace(&trace, &.{});
}

test "trace: success writes neither the diagnostics nor the trace and equals parse" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const value = try rig.obj(&.{ kv("x", int(1)), kv("y", int(-2)) });

    const traced = try run(&rig, Point, value, &trace);
    try rig_mod.expect_untouched(&rig.diag);
    try expect_trace(&trace, &.{});
    try testing.expectEqual(try rig.ok(Point, value), traced);
    try testing.expectEqual(Point{ .x = 1, .y = -2 }, traced);

    const servers = try rig.arr(&.{try rig.obj(&.{kv("host", str("a"))})});
    const fleet = try rig.obj(&.{ kv("name", str("f")), kv("servers", servers) });
    const parsed = try run(&rig, Fleet, fleet, &trace);
    try rig_mod.expect_untouched(&rig.diag);
    try testing.expectEqual(@as(usize, 1), parsed.servers.len);
    try testing.expectEqual(@as(u16, 8080), parsed.servers[0].port);
    try expect_trace(&trace, &.{});
}

/// Fails `parse` and `parse_traced` on `value` and compares their errors and diagnostics.
fn expect_same(rig: *Rig, comptime T: type, value: Value, err: ParseError) !void {
    var trace: Path = undefined;
    rig.diag = sentinel();
    try testing.expectError(err, parse_mod.parse(T, &rig.tree, value, &rig.diag));
    const plain = rig.diag;
    try testing.expectError(err, run(rig, T, value, &trace));
    try testing.expectEqualStrings(plain.message(), rig.diag.message());
    try testing.expectEqual(plain.line, rig.diag.line);
    try testing.expectEqual(plain.col, rig.diag.col);
    try testing.expect(trace.count <= nesting_max);
}

const Color = enum { red, green };
const Tuple2 = struct { pair: [2]u8, color: Color, ratio: f32 };

/// A document for `Tuple2` from its three parts.
fn tuple(rig: *Rig, pair: []const i64, color: []const u8, ratio: Value) !Value {
    return rig.obj(&.{
        kv("pair", try rig.ints(pair)),
        kv("color", str(color)),
        kv("ratio", ratio),
    });
}

test "trace: parse and parse_traced agree on the error and the message for every kind" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const one: Value = .{ .float = 1 };
    const wide = try tuple(&rig, &.{ 1, 2, 3 }, "red", one);
    try expect_same(&rig, Tuple2, wide, error.LengthMismatch);
    const big = try tuple(&rig, &.{ 1, 300 }, "red", one);
    try expect_same(&rig, Tuple2, big, error.IntegerOutOfRange);
    const blue = try tuple(&rig, &.{ 1, 2 }, "blue", one);
    try expect_same(&rig, Tuple2, blue, error.UnknownEnumValue);
    const huge = try tuple(&rig, &.{ 1, 2 }, "red", .{ .float = 1e39 });
    try expect_same(&rig, Tuple2, huge, error.FloatOutOfRange);
    const inexact = try tuple(&rig, &.{ 1, 2 }, "red", int(1 << 30));
    try expect_same(&rig, Tuple2, inexact, error.InexactNumber);
    try expect_same(&rig, Tuple2, .null, error.TypeMismatch);
    try expect_same(&rig, Tuple2, try rig.obj(&.{}), error.MissingField);
}

// ---- Hooks: synthetic segments and bare error returns. ----

/// Parses its value as an int under a segment that has no source.
const Synthetic = struct {
    n: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Synthetic {
        assert(context.depth <= nesting_max);
        assert(context.path.count <= context.depth);
        return .{ .n = try context.parse_child(u8, .none, value) };
    }

    pub fn sigilStringify(self: *const Synthetic, context: *Context) StringifyError!Value {
        assert(self.n <= 255);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

/// Parses a nested value under the named key `inner`.
const Inner = struct {
    number: u32,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Inner {
        assert(context.depth <= nesting_max);
        assert(context.path.count <= context.depth);
        return .{ .number = try context.parse_child(u32, key("inner"), value) };
    }

    pub fn sigilStringify(self: *const Inner, context: *Context) StringifyError!Value {
        assert(self.number < std.math.maxInt(u32));
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

/// Returns an error without writing the diagnostics: reflect writes the fallback message.
const Bare = struct {
    n: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Bare {
        assert(context.depth <= nesting_max);
        assert(value != .map or value.map.count <= value.map.entries.len);
        return error.InvalidValue;
    }

    pub fn sigilStringify(self: *const Bare, context: *Context) StringifyError!Value {
        assert(self.n <= 255);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

/// Re-parses its own value: only `TooDeep` can end it.
const Loop = struct {
    x: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Loop {
        assert(context.depth <= nesting_max);
        assert(context.path.count <= context.depth);
        return context.parse_child(Loop, .none, value);
    }

    pub fn sigilStringify(self: *const Loop, context: *Context) StringifyError!Value {
        assert(self.x <= 255);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

test "trace: a hook's synthetic none segment is part of the trace" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;

    try testing.expectError(error.TypeMismatch, run(&rig, Synthetic, str("x"), &trace));
    try expect_trace(&trace, &.{.none});
    try testing.expectEqualStrings("expected integer, found string", rig.diag.message());

    const Holder = struct { when: Synthetic };
    const value = try rig.obj(&.{kv("when", str("x"))});
    try testing.expectError(error.TypeMismatch, run(&rig, Holder, value, &trace));
    try expect_trace(&trace, &.{ key("when"), .none });
    try testing.expectEqualStrings("when: expected integer, found string", rig.diag.message());
}

test "trace: a failing child call keeps the deep path of the first write" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const Holder = struct { cfg: Inner };
    const value = try rig.obj(&.{kv("cfg", str("x"))});

    try testing.expectError(error.TypeMismatch, run(&rig, Holder, value, &trace));
    try expect_trace(&trace, &.{ key("cfg"), key("inner") });
    try testing.expectEqualStrings("cfg.inner: expected integer, found string", rig.diag.message());

    const ok = try rig.obj(&.{kv("cfg", int(7))});
    try testing.expectEqual(@as(u32, 7), (try run(&rig, Holder, ok, &trace)).cfg.number);
    try rig_mod.expect_untouched(&rig.diag);
    try expect_trace(&trace, &.{});
}

test "trace: a hook that returns a bare error is traced to the hook's own value" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;
    const Holder = struct { items: []const Bare };
    const items = try rig.arr(&.{ .null, .null });
    const value = try rig.obj(&.{kv("items", items)});

    try testing.expectError(error.InvalidValue, run(&rig, Holder, value, &trace));
    try expect_trace(&trace, &.{ key("items"), index(0) });
    try testing.expect(std.mem.startsWith(u8, rig.diag.message(), "items[0]: "));
    try testing.expect(std.mem.endsWith(u8, rig.diag.message(), "failed: InvalidValue"));
}

test "trace: TooDeep from a looping hook holds nesting_max segments" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var trace: Path = undefined;

    try testing.expectError(error.TooDeep, run(&rig, Loop, .null, &trace));
    try testing.expectEqual(nesting_max, trace.count);
    for (trace.segments[0..trace.count]) |segment| try testing.expect(segment == .none);
    try testing.expectEqualStrings("exceeds nesting depth limit 128", rig.diag.message());
}

// ---- The Context seam itself. ----

test "trace: Context.init leaves the trace unset and fail without one writes only the message" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);

    try testing.expect(context.trace == null);
    path.push(key("a"));
    context.depth = 1;
    const err = context.fail(error.InvalidValue, "bad", .{});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), err);
    try testing.expectEqualStrings("a: bad", rig.diag.message());
    try testing.expect(context.trace == null);
}

test "trace: the first message write copies the live path and later writes do not" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var trace: Path = undefined;
    trace.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    context.trace = &trace;

    path.push(key("a"));
    path.push(index(3));
    context.depth = 2;
    const first = context.fail(error.InvalidValue, "first", .{});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), first);
    try expect_trace(&trace, &.{ key("a"), index(3) });
    try testing.expectEqualStrings("a[3]: first", rig.diag.message());

    // The copy is a snapshot: a later push, a pop or a second message never reaches it.
    path.push(key("b"));
    context.depth = 3;
    const second = context.fail(error.InvalidValue, "second", .{});
    try testing.expectEqual(@as(ParseError, error.InvalidValue), second);
    try expect_trace(&trace, &.{ key("a"), index(3) });
    path.pop();
    path.pop();
    try expect_trace(&trace, &.{ key("a"), index(3) });
}

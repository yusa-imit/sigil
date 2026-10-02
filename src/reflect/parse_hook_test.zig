//! reflect/parse hook tests — the `sigilParse` hook (ADR 0002 sections 1 and 5): a type that
//! declares the hook pair is parsed by the hook instead of the default mapping, under the same
//! `Context` (path and depth continue), with its diagnostics written exactly once, either by
//! `Context.fail`, by a failing `parse_child`, or by the fallback for a bare error return.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Context = context_mod.Context;
const Path = context_mod.Path;
const ParseError = context_mod.ParseError;
const StringifyError = context_mod.StringifyError;
const assert = std.debug.assert;
const parse = parse_mod.parse;
const parse_value = parse_mod.parse_value;
const testing = std.testing;
const nesting_max = core.value.nesting_max;
const position_none = core.diagnostics.position_none;
const Rig = rig_mod.Rig;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;

var hook_calls: u32 = 0;
var seen_depth: u32 = 0;
var seen_count: u32 = 0;
var seen_segment: context_mod.Segment = .none;
var seen_tree: ?*ValueTree = null;

/// A duration in milliseconds, written as "250ms" or "5s".
const Duration = struct {
    ms: u64,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Duration {
        assert(context.depth <= nesting_max);
        assert(context.path.count <= context.depth);
        hook_calls += 1;
        const text = switch (value) {
            .string => |text| text,
            else => return error.TypeMismatch, // No diagnostics: reflect writes the fallback.
        };
        const unit: u64 = if (std.mem.endsWith(u8, text, "ms")) 1 else 1000;
        const digits = if (unit == 1) text[0 .. text.len - 2] else text[0..text.len -| 1];
        const valid = unit == 1 or std.mem.endsWith(u8, text, "s");
        const number = std.fmt.parseInt(u64, digits, 10) catch null;
        if (!valid or number == null) {
            return context.fail(error.InvalidValue, "bad duration \"{s}\"", .{text});
        }
        return .{ .ms = number.? * unit };
    }

    pub fn sigilStringify(self: *const Duration, context: *Context) StringifyError!Value {
        assert(self.ms < std.math.maxInt(u64));
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

const Settings = struct { timeout: Duration, retries: u8 };

/// A struct the default mapping would accept from `{a: 1}`; the hook takes only a string.
const Fancy = struct {
    a: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Fancy {
        assert(context.depth <= nesting_max);
        assert(@intFromPtr(context) != 0);
        if (value != .string) return context.fail(error.TypeMismatch, "fancy wants text", .{});
        return .{ .a = 42 };
    }

    pub fn sigilStringify(self: *const Fancy, context: *Context) StringifyError!Value {
        assert(self.a <= 255);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

/// An unsupported type for the default mapping (packed), made parseable by its hook.
const Flags = packed struct(u8) {
    low: u4,
    high: u4,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Flags {
        assert(context.depth <= nesting_max);
        assert(@bitSizeOf(Flags) == 8);
        const number = switch (value) {
            .int => |number| number,
            else => return context.fail(error.TypeMismatch, "flags want an int", .{}),
        };
        const byte = std.math.cast(u8, number) orelse {
            return context.fail(error.IntegerOutOfRange, "flags {d} do not fit", .{number});
        };
        return @bitCast(byte);
    }

    pub fn sigilStringify(self: *const Flags, context: *Context) StringifyError!Value {
        assert(@bitSizeOf(Flags) == 8);
        assert(@intFromPtr(self) != 0 and @intFromPtr(context) != 0);
        return .null;
    }
};

/// A `[]u8` wrapper: the hook copies the text into the tree, upper-cased.
const Shout = struct {
    text: []u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Shout {
        assert(context.depth <= nesting_max);
        assert(@intFromPtr(context.tree) != 0);
        const text = switch (value) {
            .string => |text| text,
            else => return context.fail(error.TypeMismatch, "shout wants text", .{}),
        };
        const copy = try context.tree.arena.allocator().alloc(u8, text.len);
        for (text, copy) |byte, *out| out.* = std.ascii.toUpper(byte);
        return .{ .text = copy };
    }

    pub fn sigilStringify(self: *const Shout, context: *Context) StringifyError!Value {
        assert(self.text.len < std.math.maxInt(u32));
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

const Level = enum {
    low,
    high,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Level {
        assert(context.depth <= nesting_max);
        assert(@typeInfo(Level).@"enum".fields.len == 2);
        if (value == .int and value.int == 0) return .low;
        if (value == .int and value.int == 1) return .high;
        return context.fail(error.InvalidValue, "level must be 0 or 1", .{});
    }

    pub fn sigilStringify(self: *const Level, context: *Context) StringifyError!Value {
        assert(@intFromEnum(self.*) < 2);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

const Choice = union(enum) {
    a: u8,
    b,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Choice {
        assert(context.depth <= nesting_max);
        assert(@typeInfo(Choice).@"union".fields.len == 2);
        if (value == .int) return .{ .a = try context.parse_child(u8, .none, value) };
        return .b;
    }

    pub fn sigilStringify(self: *const Choice, context: *Context) StringifyError!Value {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

/// Delegates to `parse_child` under its own key; a failing child writes the diagnostics.
const Inner = struct {
    number: u32,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Inner {
        assert(context.depth <= nesting_max);
        assert(context.path.count <= context.depth);
        const number = try context.parse_child(u32, .{ .key = "inner" }, value);
        return .{ .number = number };
    }

    pub fn sigilStringify(self: *const Inner, context: *Context) StringifyError!Value {
        assert(self.number < std.math.maxInt(u32));
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};
const Outer = struct { cfg: Inner };

/// Re-parses its own value through `parse_child`: it can only end in `TooDeep`.
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

/// Records the context it runs under.
const Probe = struct {
    seen: bool,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Probe {
        assert(value == .null);
        assert(context.path.count <= context.depth);
        seen_depth = context.depth;
        seen_count = context.path.count;
        seen_segment = context.path.segments[context.path.count - 1];
        seen_tree = context.tree;
        return .{ .seen = true };
    }

    pub fn sigilStringify(self: *const Probe, context: *Context) StringifyError!Value {
        assert(self.seen);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};
const Probed = struct { probe: Probe, other: u8 };

/// A hook that returns `err` and never writes the diagnostics.
fn Failer(comptime err: ParseError) type {
    return struct {
        pub fn sigilParse(context: *Context, value: Value) ParseError!@This() {
            assert(context.depth <= nesting_max);
            assert(context.path.count <= context.depth);
            _ = value;
            return err;
        }

        pub fn sigilStringify(self: *const @This(), context: *Context) StringifyError!Value {
            assert(@intFromPtr(self) != 0);
            assert(@intFromPtr(context) != 0);
            return .null;
        }
    };
}

fn fallback(comptime T: type, comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    const format = "{s}sigilParse of {s} failed: {s}";
    return std.fmt.comptimePrint(format, .{ prefix, @typeName(T), name });
}

test "hook: the hook replaces the default mapping for an unsupported type" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try testing.expectEqual(Duration{ .ms = 5000 }, try rig.ok(Duration, str("5s")));
    try testing.expectEqual(Duration{ .ms = 250 }, try rig.ok(Duration, str("250ms")));
    const flags = try rig.ok(Flags, int(0xA5));
    try testing.expectEqual(@as(u4, 0x5), flags.low);
    try testing.expectEqual(@as(u4, 0xA), flags.high);
    const shout = try rig.ok(Shout, str("abc"));
    try testing.expectEqualStrings("ABC", shout.text);
}

test "hook: the hook wins over a default mapping that would accept the value" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try testing.expectEqual(@as(u8, 42), (try rig.ok(Fancy, str("anything"))).a);
    const as_map = try rig.obj(&.{kv("a", int(1))});
    try rig.fails(Fancy, as_map, error.TypeMismatch, "fancy wants text");
}

test "hook: enums and unions can declare the hook too" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try testing.expectEqual(Level.high, try rig.ok(Level, int(1)));
    try testing.expectEqual(Level.low, try rig.ok(Level, int(0)));
    try rig.fails(Level, str("high"), error.InvalidValue, "level must be 0 or 1");
    try testing.expectEqual(@as(u8, 7), (try rig.ok(Choice, int(7))).a);
    try testing.expect((try rig.ok(Choice, str("b"))) == .b);
    try rig.fails(Choice, int(300), error.IntegerOutOfRange, "300 is out of range for u8");
}

test "hook: context.fail writes the message once, with the key path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.fails(Duration, str("5x"), error.InvalidValue, "bad duration \"5x\"");
    try rig.fails(Duration, str(""), error.InvalidValue, "bad duration \"\"");
    try rig.fails(Duration, str("xs"), error.InvalidValue, "bad duration \"xs\"");
    const bad = try rig.obj(&.{ kv("timeout", str("5x")), kv("retries", int(1)) });
    try rig.fails(Settings, bad, error.InvalidValue, "timeout: bad duration \"5x\"");
    const wrong = try rig.obj(&.{ kv("timeout", str("1s")), kv("retries", int(256)) });
    try rig.fails(Settings, wrong, error.IntegerOutOfRange, "retries: 256 is out of range for u8");
}

test "hook: a bare error return gets the fallback message, whatever the error" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.fails(Duration, int(5), error.TypeMismatch, fallback(Duration, "", "TypeMismatch"));
    const invalid = Failer(error.InvalidValue);
    try rig.fails(invalid, .null, error.InvalidValue, fallback(invalid, "", "InvalidValue"));
    const oom = Failer(error.OutOfMemory);
    try rig.fails(oom, .null, error.OutOfMemory, fallback(oom, "", "OutOfMemory"));
    const range = Failer(error.IntegerOutOfRange);
    try rig.fails(range, .null, error.IntegerOutOfRange, fallback(range, "", "IntegerOutOfRange"));
    const Boxed = struct { slot: invalid };
    const input = try rig.obj(&.{kv("slot", .null)});
    try rig.fails(Boxed, input, error.InvalidValue, fallback(invalid, "slot: ", "InvalidValue"));
}

test "hook: an allocation failure inside the hook is OutOfMemory with the fallback" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    try testing.expectError(error.OutOfMemory, parse(Shout, &tree, str("abc"), &diag));
    try testing.expectEqualStrings(fallback(Shout, "", "OutOfMemory"), diag.message());
    try testing.expectEqual(position_none, diag.line);
}

test "hook: parse_child inside the hook continues the path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try testing.expectEqual(@as(u32, 9), (try rig.ok(Inner, int(9))).number);
    try rig.fails(Inner, str("x"), error.TypeMismatch, "inner: expected integer, found string");
    const field = try rig.obj(&.{kv("cfg", str("x"))});
    try rig.fails(Outer, field, error.TypeMismatch, "cfg.inner: expected integer, found string");
    const negative = try rig.obj(&.{kv("cfg", int(-3))});
    const range = "cfg.inner: -3 is out of range for u32";
    try rig.fails(Outer, negative, error.IntegerOutOfRange, range);
}

test "hook: a hook runs under the caller's tree, path and depth" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const input = try rig.obj(&.{ kv("probe", .null), kv("other", int(1)) });
    const got = try rig.ok(Probed, input);
    try testing.expect(got.probe.seen);
    try testing.expectEqual(@as(u32, 1), seen_depth);
    try testing.expectEqual(@as(u32, 1), seen_count);
    try testing.expectEqualStrings("probe", seen_segment.key);
    try testing.expect(seen_tree == &rig.tree);
    const items = try rig.arr(&.{ .null, .null });
    const list = try rig.ok([]const Probe, items);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u64, 1), seen_segment.index);
    try testing.expectEqual(@as(u32, 1), seen_depth);
}

test "hook: under a deep context the hook's child call is the one that is TooDeep" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    context.depth = nesting_max - 1;
    try testing.expectEqual(@as(u32, 4), (try parse_value(Inner, &context, int(4))).number);
    try testing.expect(!context.diag_written);
    context.depth = nesting_max;
    try testing.expectError(error.TooDeep, parse_value(Inner, &context, int(4)));
    try testing.expectEqualStrings("exceeds nesting depth limit 128", rig.diag.message());
    try testing.expect(context.diag_written);
    try testing.expectEqual(@as(u32, 0), context.path.count);
    try testing.expectEqual(nesting_max, context.depth);
}

test "hook: a hook that re-parses its own value ends in TooDeep, not a stack overflow" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.fails(Loop, .null, error.TooDeep, "exceeds nesting depth limit 128");
    const nested = try rig.obj(&.{kv("x", int(1))});
    try rig.fails(Loop, nested, error.TooDeep, "exceeds nesting depth limit 128");
}

test "hook: as a field, an optional and a slice element" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const input = try rig.obj(&.{ kv("timeout", str("2s")), kv("retries", int(3)) });
    const settings = try rig.ok(Settings, input);
    try testing.expectEqual(@as(u64, 2000), settings.timeout.ms);
    try testing.expectEqual(@as(u8, 3), settings.retries);

    hook_calls = 0;
    try testing.expect((try rig.ok(?Duration, .null)) == null);
    try testing.expectEqual(@as(u32, 0), hook_calls);
    try testing.expectEqual(@as(u64, 10), (try rig.ok(?Duration, str("10ms"))).?.ms);
    try testing.expectEqual(@as(u32, 1), hook_calls);

    const list = try rig.ok([]const Duration, try rig.arr(&.{ str("1s"), str("3ms") }));
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u64, 3), list[1].ms);
    const bad = try rig.arr(&.{ str("1s"), str("zz") });
    try rig.fails([]const Duration, bad, error.InvalidValue, "[1]: bad duration \"zz\"");
}

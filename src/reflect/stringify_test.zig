//! reflect/stringify tests — `stringify(T, tree, value, diag)` (ADR 0002 sections 1-5): the mirror
//! of `parse` for scalars, strings (UTF-8 checked, copied), enums, optionals, structs through the
//! options table, arrays, slices, tagged unions, string maps, `core.Value`, `core.Timestamp`
//! and the `sigilStringify` hook. Expected values are built independently and compared with
//! `core.value.eql`; every `StringifyError` variant is provoked.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const stringify_mod = @import("stringify.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const Context = context_mod.Context;
const ParseError = context_mod.ParseError;
const StringifyError = context_mod.StringifyError;
const assert = std.debug.assert;
const stringify = stringify_mod.stringify;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const Rig = rig_mod.Rig;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;

fn expect_value(expected: Value, actual: Value) !void {
    try testing.expect(try core.value.eql(expected, actual));
}

/// Stringifies `value`, which must succeed and leave the diagnostics untouched.
fn ok(rig: *Rig, comptime T: type, value: T) !Value {
    rig.diag = sentinel();
    const got = try stringify(T, &rig.tree, value, &rig.diag);
    try rig_mod.expect_untouched(&rig.diag);
    return got;
}

/// Expects `err` and a diagnostics at `position_none` whose message starts with `prefix`.
fn fails(rig: *Rig, comptime T: type, value: T, err: StringifyError, prefix: []const u8) !void {
    rig.diag = sentinel();
    try testing.expectError(err, stringify(T, &rig.tree, value, &rig.diag));
    try testing.expect(std.mem.startsWith(u8, rig.diag.message(), prefix));
    try testing.expectEqual(position_none, rig.diag.line);
    try testing.expectEqual(position_none, rig.diag.col);
}

test "scalars: signed is .int, unsigned is .int up to maxInt(i64) and .uint above" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try expect_value(.{ .bool = true }, try ok(&rig, bool, true));
    try expect_value(int(-128), try ok(&rig, i8, -128));
    try expect_value(int(std.math.minInt(i64)), try ok(&rig, i64, std.math.minInt(i64)));
    try expect_value(int(255), try ok(&rig, u8, 255));
    try expect_value(int(0), try ok(&rig, u64, 0));
    const top: u64 = std.math.maxInt(i64);
    try expect_value(int(std.math.maxInt(i64)), try ok(&rig, u64, top));
    try expect_value(.{ .uint = top + 1 }, try ok(&rig, u64, top + 1));
    try expect_value(.{ .uint = std.math.maxInt(u64) }, try ok(&rig, u64, std.math.maxInt(u64)));
    try expect_value(int(7), try ok(&rig, usize, 7));
    try expect_value(.{ .float = 1.5 }, try ok(&rig, f64, 1.5));
    try expect_value(.{ .float = 0.5 }, try ok(&rig, f32, 0.5));
    try testing.expect(!(try core.value.eql(int(1), try ok(&rig, f64, 1.0))));
}

test "scalars: f32 widens exactly and NaN and infinity pass through" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const third: f32 = 1.0 / 3.0;
    const widened = try ok(&rig, f32, third);
    try testing.expectEqual(@as(f64, third), widened.float);
    try testing.expect(std.math.isInf((try ok(&rig, f64, std.math.inf(f64))).float));
    try testing.expect(std.math.isNan((try ok(&rig, f32, std.math.nan(f32))).float));
}

test "string: copied into the tree, valid UTF-8 only" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    var buffer = [_]u8{ 'h', 'i', ' ', 0xc3, 0xa9 };
    const got = try ok(&rig, []const u8, &buffer);
    buffer[0] = 'X'; // The tree owns a copy; the caller's buffer may change.
    try expect_value(str("hi \xc3\xa9"), got);
    try testing.expect(got.string.ptr != &buffer);
    try expect_value(str(""), try ok(&rig, []const u8, ""));

    try fails(&rig, []const u8, "ab\xff", error.InvalidUtf8, "invalid UTF-8 at byte 2");
    try fails(&rig, []const u8, "\xed\xa0\x80", error.InvalidUtf8, "invalid UTF-8 at byte 0");
    const Named = struct { name: []const u8 };
    const bad: Named = .{ .name = "x\xc3" };
    try fails(&rig, Named, bad, error.InvalidUtf8, "name: invalid UTF-8 at byte 1");
}

test "string: a length past maxInt(u32) is InputTooLarge without reading the bytes" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    // The pointer is never dereferenced: the length gate runs before any byte is read.
    const base: [*]const u8 = @ptrFromInt(1);
    const huge = base[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try fails(&rig, []const u8, huge, error.InputTooLarge, "string is longer than");
    const Named = struct { name: []const u8 };
    try fails(&rig, Named, .{ .name = huge }, error.InputTooLarge, "name: string is longer");
}

const Color = enum { red, dark_green };
const Wire = enum {
    dark_green,
    red,
    pub const sigil_options = .{ .rename_all = .kebab_case };
};

test "enum and optional: wire name or null" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try expect_value(str("red"), try ok(&rig, Color, .red));
    try expect_value(str("dark_green"), try ok(&rig, Color, .dark_green));
    try expect_value(str("dark-green"), try ok(&rig, Wire, .dark_green));
    try expect_value(.null, try ok(&rig, ?u8, null));
    try expect_value(int(3), try ok(&rig, ?u8, 3));
    try expect_value(.null, try ok(&rig, ?Color, null));
    try expect_value(str("red"), try ok(&rig, ?Color, .red));
}

const Tls = struct { cert: []const u8, verify: bool = true };
const Config = struct {
    server_name: []const u8,
    port: u16 = 8080,
    tls: ?Tls = null,
    pub const sigil_options = .{ .rename = .{ .server_name = "host" } };
};

test "struct: every field in declaration order under its wire name, defaults included" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const plain = try ok(&rig, Config, .{ .server_name = "a" });
    const pairs = [_]rig_mod.Pair{ kv("host", str("a")), kv("port", int(8080)), kv("tls", .null) };
    const expected = try rig.obj(&pairs);
    try expect_value(expected, plain);
    try testing.expectEqualStrings("tls", plain.map.items()[2].key);

    const tls = try rig.obj(&.{ kv("cert", str("c.pem")), kv("verify", .{ .bool = false }) });
    const full = try ok(&rig, Config, .{
        .server_name = "b",
        .port = 1,
        .tls = .{ .cert = "c.pem", .verify = false },
    });
    const full_pairs = [_]rig_mod.Pair{ kv("host", str("b")), kv("port", int(1)), kv("tls", tls) };
    try expect_value(try rig.obj(&full_pairs), full);
    try expect_value(try rig.obj(&.{}), try ok(&rig, struct {}, .{}));
    full.map.check_invariants();
}

test "struct: a nested failure names the key path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const bad: Config = .{ .server_name = "a", .tls = .{ .cert = "\xff" } };
    try fails(&rig, Config, bad, error.InvalidUtf8, "tls.cert: invalid UTF-8 at byte 0");
    const Fleet = struct { servers: []const Tls };
    const servers = [_]Tls{ .{ .cert = "ok" }, .{ .cert = "x\xff" } };
    try fails(&rig, Fleet, .{ .servers = &servers }, error.InvalidUtf8, "servers[1].cert: invalid");
}

test "array and slice: .array of the elements, empty included" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try expect_value(try rig.ints(&.{ 1, 2, 3 }), try ok(&rig, [3]u8, .{ 1, 2, 3 }));
    try expect_value(try rig.ints(&.{}), try ok(&rig, [0]u8, .{}));
    const numbers = [_]i32{ -1, 0, 1 };
    try expect_value(try rig.ints(&.{ -1, 0, 1 }), try ok(&rig, []const i32, &numbers));
    try expect_value(try rig.ints(&.{}), try ok(&rig, []const i32, &.{}));
    const names = [_][]const u8{ "a", "b" };
    const wanted = try rig.arr(&.{ str("a"), str("b") });
    try expect_value(wanted, try ok(&rig, []const []const u8, &names));
    const nested = try ok(&rig, [2][]const u8, .{ "x", "y" });
    try expect_value(try rig.arr(&.{ str("x"), str("y") }), nested);
}

const Endpoint = union(enum) {
    tcp: struct { port: u16 },
    unix: []const u8,
    none,
    pub const sigil_options = .{ .rename = .{ .unix = "socket" } };
};

test "union: a void variant is its tag, any other is a one-entry map" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try expect_value(str("none"), try ok(&rig, Endpoint, .none));
    const tcp = try rig.obj(&.{kv("port", int(80))});
    const tcp_map = try rig.obj(&.{kv("tcp", tcp)});
    try expect_value(tcp_map, try ok(&rig, Endpoint, .{ .tcp = .{ .port = 80 } }));
    const unix = try rig.obj(&.{kv("socket", str("/run/x"))});
    try expect_value(unix, try ok(&rig, Endpoint, .{ .unix = "/run/x" }));
    try fails(&rig, Endpoint, .{ .unix = "\xff" }, error.InvalidUtf8, "socket: invalid UTF-8");
}

test "string map: insertion order, copied keys, UTF-8 checked keys" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const Labels = std.array_hash_map.String(u8);
    var labels: Labels = .empty;
    defer labels.deinit(testing.allocator);
    try labels.put(testing.allocator, "zeta", 1);
    try labels.put(testing.allocator, "alpha", 2);
    const got = try ok(&rig, Labels, labels);
    try expect_value(try rig.obj(&.{ kv("zeta", int(1)), kv("alpha", int(2)) }), got);
    try testing.expect(got.map.items()[0].key.ptr != labels.keys()[0].ptr);

    var empty: Labels = .empty;
    try expect_value(try rig.obj(&.{}), try ok(&rig, Labels, empty));
    empty.deinit(testing.allocator);

    try labels.put(testing.allocator, "bad\xff", 3);
    try fails(&rig, Labels, labels, error.InvalidUtf8, "key has invalid UTF-8 at byte 3");
}

test "Timestamp and Value: Timestamp as is, Value deep-copied into the tree" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const stamp: core.Timestamp = .{ .seconds = 5, .nanoseconds = 6, .offset_minutes = -60 };
    try expect_value(.{ .timestamp = stamp }, try ok(&rig, core.Timestamp, stamp));

    var scratch = rig_mod.Rig{ .tree = undefined, .diag = sentinel() };
    scratch.tree.init(testing.allocator);
    const blob: Value = .{ .bytes = "\x00\xff" };
    const source = try scratch.obj(&.{kv("k", try scratch.arr(&.{ str("v"), blob }))});
    const copy = try ok(&rig, Value, source);
    scratch.deinit(); // The copy must not point into the source tree.
    const list = copy.map.get("k").?.array;
    try testing.expectEqualStrings("v", list[0].string);
    try testing.expectEqualStrings("\x00\xff", list[1].bytes);
    try expect_value(try rig.obj(&.{kv("k", try rig.arr(&.{ str("v"), blob }))}), copy);
}

const Node = struct { kids: []const Node };

fn node_chain(arena: std.mem.Allocator, nodes: u32) !Node {
    assert(nodes > 0);
    var node: Node = .{ .kids = &.{} };
    for (1..nodes) |_| {
        const kids = try arena.alloc(Node, 1);
        kids[0] = node;
        node = .{ .kids = kids };
    }
    return node;
}

test "depth: 128 nested containers pass, the 129th is TooDeep with one diagnostics" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const exact = try ok(&rig, Node, try node_chain(arena.allocator(), 64)); // 128 containers.
    try testing.expect(exact == .map);
    try fails(&rig, Node, try node_chain(arena.allocator(), 65), error.TooDeep, "");
    try testing.expect(std.mem.endsWith(u8, rig.diag.message(), "exceeds nesting depth limit 128"));
}

test "depth: a Value deeper than nesting_max is TooDeep, exactly at the boundary" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    var inner: Value = .null;
    for (0..core.value.nesting_max) |_| inner = try rig.arr(&.{inner});
    _ = try ok(&rig, Value, inner); // 128 arrays pass.
    try fails(&rig, Value, try rig.arr(&.{inner}), error.TooDeep, "exceeds nesting depth limit");
}

const Doc = struct { name: []const u8, tags: []const []const u8, endpoint: Endpoint };

test "out of memory: every allocation point is a typed error and nothing leaks" {
    const tags = [_][]const u8{ "a", "b" };
    const doc: Doc = .{ .name = "n", .tags = &tags, .endpoint = .{ .unix = "u" } };
    var reached_success = false;
    for (0..64) |fail_index| {
        const budget: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, budget);
        var tree: core.ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        var diag = sentinel();
        if (stringify(Doc, &tree, doc, &diag)) |_| {
            reached_success = true;
            try rig_mod.expect_untouched(&diag);
            break;
        } else |err| switch (err) { // proof: not I/O, the error set is the four stringify errors.
            error.OutOfMemory => {
                try testing.expect(std.mem.endsWith(u8, diag.message(), "failed: OutOfMemory"));
            },
            error.InvalidUtf8, error.InputTooLarge, error.TooDeep => {
                return error.TestUnexpectedResult;
            },
        }
    }
    try testing.expect(reached_success);
}

/// A duration whose hook writes text; `sigilParse` only pairs it.
const Duration = struct {
    ms: u64,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Duration {
        assert(@intFromPtr(context) != 0);
        assert(value != .map);
        return context.fail(error.InvalidValue, "unused", .{});
    }

    pub fn sigilStringify(self: *const Duration, context: *Context) StringifyError!Value {
        assert(@intFromPtr(self) != 0);
        assert(context.depth <= core.value.nesting_max);
        if (self.ms == 0) return context.fail_stringify(error.InvalidUtf8, "zero duration", .{});
        if (self.ms == 1) return error.OutOfMemory; // No diagnostics: reflect writes the fallback.
        var buffer: [24]u8 = undefined;
        // proof: 20 digits plus "ms" fit the 24-byte buffer.
        const text = std.fmt.bufPrint(&buffer, "{d}ms", .{self.ms}) catch unreachable;
        return context.tree.dupe_string(text);
    }
};

/// A hook that delegates to `stringify_child` for a plain struct; the hook wins over the
/// default mapping (which would give a map).
const Wrapped = struct {
    inner: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Wrapped {
        assert(@intFromPtr(context) != 0);
        assert(value != .map);
        return context.fail(error.InvalidValue, "unused", .{});
    }

    pub fn sigilStringify(self: *const Wrapped, context: *Context) StringifyError!Value {
        assert(self.inner <= 255);
        assert(context.depth <= core.value.nesting_max);
        const label: []const u8 = "\xff";
        const list = [_]Value{
            try context.stringify_child(u8, .{ .index = 0 }, &self.inner),
            try context.stringify_child([]const u8, .{ .key = "label" }, &label),
        };
        return context.tree.dupe_array(&list);
    }
};

test "hook: sigilStringify replaces the default mapping and allocates in the tree" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const Job = struct { timeout: Duration };
    const expected = try rig.obj(&.{kv("timeout", str("250ms"))});
    try expect_value(expected, try ok(&rig, Job, .{ .timeout = .{ .ms = 250 } }));
    try expect_value(str("9ms"), try ok(&rig, Duration, .{ .ms = 9 }));
}

test "hook: failures write the diagnostics exactly once, with the path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const Job = struct { timeouts: []const Duration };
    const durations = [_]Duration{ .{ .ms = 5 }, .{ .ms = 0 } };
    const bad: Job = .{ .timeouts = &durations };
    try fails(&rig, Job, bad, error.InvalidUtf8, "timeouts[1]: zero duration");
    try testing.expectEqualStrings("timeouts[1]: zero duration", rig.diag.message());

    const bare = [_]Duration{.{ .ms = 1 }};
    rig.diag = sentinel();
    const job: Job = .{ .timeouts = &bare };
    try testing.expectError(error.OutOfMemory, stringify(Job, &rig.tree, job, &rig.diag));
    try testing.expectEqualStrings(
        "timeouts[0]: sigilStringify of " ++ @typeName(Duration) ++ " failed: OutOfMemory",
        rig.diag.message(),
    );
}

test "hook: stringify_child continues the path of the caller and reports its own failure" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const Holder = struct { wrapped: Wrapped };
    const holder: Holder = .{ .wrapped = .{ .inner = 1 } };
    try fails(&rig, Holder, holder, error.InvalidUtf8, "wrapped.label: invalid UTF-8");
    rig.diag = sentinel();
    var path: context_mod.Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    const wrapped: Wrapped = .{ .inner = 4 };
    // The second child fails; the first one's result is discarded with the tree.
    const failure = stringify_mod.stringify_value(Wrapped, &context, &wrapped);
    try testing.expectError(error.InvalidUtf8, failure);
    try testing.expect(context.diag_written);
    try testing.expectEqual(@as(u32, 0), context.depth);
    try testing.expectEqual(@as(u32, 0), context.path.count);
}

test "round trip: parse(stringify(x)) equals x and stringify of that equals the first Value" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const tls: Tls = .{ .cert = "c", .verify = false };
    const original: Config = .{ .server_name = "h", .port = 9, .tls = tls };
    const first = try ok(&rig, Config, original);
    const back = try rig.ok(Config, first);
    try testing.expectEqualStrings("h", back.server_name);
    try testing.expectEqual(@as(u16, 9), back.port);
    try testing.expectEqualStrings("c", back.tls.?.cert);
    try testing.expectEqual(false, back.tls.?.verify);
    try expect_value(first, try ok(&rig, Config, back));
}

/// Runs `stringify_value` for `T` under a context that already sits `depth` levels down.
fn at_depth(rig: *Rig, comptime T: type, value: T, depth: u32) StringifyError!Value {
    var path: context_mod.Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    context.depth = depth;
    return stringify_mod.stringify_value(T, &context, &value);
}

test "depth: every container kind enters at 127 and is TooDeep at 128, scalars always pass" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const Labels = std.array_hash_map.String(u8);
    var labels: Labels = .empty;
    defer labels.deinit(testing.allocator);
    try labels.put(testing.allocator, "k", 1);
    const holds_value: Value = try rig.arr(&.{.null});
    const nested: Value = try rig.arr(&.{holds_value});

    _ = try at_depth(&rig, Value, holds_value, 127);
    try testing.expectError(error.TooDeep, at_depth(&rig, Value, nested, 127));
    try testing.expectError(error.TooDeep, at_depth(&rig, Value, holds_value, 128));
    try expect_value(int(1), try at_depth(&rig, Value, int(1), 128));
    _ = try at_depth(&rig, Tls, .{ .cert = "c" }, 127);
    try testing.expectError(error.TooDeep, at_depth(&rig, Tls, .{ .cert = "c" }, 128));
    _ = try at_depth(&rig, Endpoint, .{ .unix = "u" }, 127);
    try testing.expectError(error.TooDeep, at_depth(&rig, Endpoint, .{ .unix = "u" }, 128));
    _ = try at_depth(&rig, Labels, labels, 127);
    try testing.expectError(error.TooDeep, at_depth(&rig, Labels, labels, 128));
    _ = try at_depth(&rig, [1]u8, .{1}, 127);
    try testing.expectError(error.TooDeep, at_depth(&rig, [1]u8, .{1}, 128));
    try expect_value(str("none"), try at_depth(&rig, Endpoint, .none, 128));
}

/// A hook that stringifies itself through `stringify_child` forever.
const Loop = struct {
    seed: u8,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Loop {
        assert(@intFromPtr(context) != 0);
        assert(value != .map);
        return context.fail(error.InvalidValue, "unused", .{});
    }

    pub fn sigilStringify(self: *const Loop, context: *Context) StringifyError!Value {
        assert(self.seed <= 255);
        assert(context.depth <= core.value.nesting_max);
        return context.stringify_child(Loop, .none, self);
    }
};

test "hook: a hook that re-stringifies itself ends in TooDeep, not a stack overflow" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try fails(&rig, Loop, .{ .seed = 1 }, error.TooDeep, "");
    try testing.expectEqualStrings("exceeds nesting depth limit 128", rig.diag.message());
    var path: context_mod.Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(&rig.tree, &rig.diag, &path);
    const loop: Loop = .{ .seed = 2 };
    try testing.expectError(error.TooDeep, stringify_mod.stringify_value(Loop, &context, &loop));
    try testing.expectEqual(@as(u32, 0), context.depth);
    try testing.expectEqual(@as(u32, 0), context.path.count);
}

test "array: a length past maxInt(u32) is InputTooLarge and allocates nothing" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    const base: [*]const Tls = @ptrFromInt(@alignOf(Tls));
    const huge = base[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    const before = rig.tree.arena.queryCapacity();
    try fails(&rig, []const Tls, huge, error.InputTooLarge, "array is longer than");
    try testing.expectEqual(before, rig.tree.arena.queryCapacity());
}

const Mixed = struct { labels: std.array_hash_map.String(u8), raw: Value };

test "out of memory: string maps and Value copies fail typed and leave no leak" {
    var labels: std.array_hash_map.String(u8) = .empty;
    defer labels.deinit(testing.allocator);
    try labels.put(testing.allocator, "a", 1);
    try labels.put(testing.allocator, "b", 2);
    var source = Rig{ .tree = undefined, .diag = sentinel() };
    source.tree.init(testing.allocator);
    defer source.deinit();
    const raw = try source.obj(&.{kv("k", try source.arr(&.{ str("v"), int(1) }))});
    const doc: Mixed = .{ .labels = labels, .raw = raw };
    var reached_success = false;
    for (0..64) |fail_index| {
        const budget: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, budget);
        var tree: core.ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        var diag = sentinel();
        // proof: not I/O; the error set is the four stringify errors.
        const got = stringify(Mixed, &tree, doc, &diag) catch |err| switch (err) {
            error.OutOfMemory => {
                try testing.expect(std.mem.endsWith(u8, diag.message(), "failed: OutOfMemory"));
                continue;
            },
            error.InvalidUtf8, error.InputTooLarge, error.TooDeep => {
                return error.TestUnexpectedResult;
            },
        };
        try rig_mod.expect_untouched(&diag);
        try testing.expect(try core.value.eql(got.map.get("raw").?.*, raw));
        reached_success = true;
        break;
    }
    try testing.expect(reached_success);
}

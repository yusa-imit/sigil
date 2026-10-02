//! reflect/parse string-map tests — `std.array_hash_map.String(V)` from a `.map` (ADR 0002
//! sections 2 and 5): insertion order, borrowed keys, value paths, one arena allocation, the
//! `TypeMismatch` of every other tag, maps inside structs and slices, the container depth
//! boundary, out-of-memory, and a seeded model run against a plain list of pairs.

const std = @import("std");
const core = @import("../core.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const parse = parse_mod.parse;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const Rig = rig_mod.Rig;
const Pair = rig_mod.Pair;
const Server = rig_mod.Server;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;

const Ports = std.array_hash_map.String(u16);
const Config = struct { ports: Ports };
const Servers = std.array_hash_map.String(Server);
const Lists = std.array_hash_map.String([]const u32);

fn Nest(comptime levels: u32) type {
    @setEvalBranchQuota(100_000);
    var T: type = u8;
    for (0..levels) |_| T = std.array_hash_map.String(T);
    return T;
}

fn map_chain(rig: *Rig, levels: u32) !Value {
    std.debug.assert(levels > 0);
    var current = int(1);
    var level: u32 = 0;
    while (level < levels) : (level += 1) current = try rig.obj(&.{kv("k", current)});
    return current;
}

test "map: count, key order and values follow the input map" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const input = try rig.obj(&.{ kv("http", int(80)), kv("alpha", int(1)), kv("ssh", int(22)) });
    const got = try rig.ok(Ports, input);
    try testing.expectEqual(@as(usize, 3), got.count());
    const expected_keys = [_][]const u8{ "http", "alpha", "ssh" };
    for (expected_keys, got.keys()) |expected, key| try testing.expectEqualStrings(expected, key);
    try testing.expectEqualSlices(u16, &.{ 80, 1, 22 }, got.values());
    try testing.expectEqual(@as(u16, 22), got.get("ssh").?);
    try testing.expect(got.get("missing") == null);
}

test "map: keys are borrowed from the input, values are parsed" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const input = try rig.obj(&.{ kv("a", int(1)), kv("b", .{ .uint = 2 }) });
    const got = try rig.ok(Ports, input);
    const entries = input.map.items();
    try testing.expectEqual(@as(usize, 2), got.count());
    for (entries, got.keys()) |entry, key| {
        try testing.expectEqual(entry.key.ptr, key.ptr);
        try testing.expectEqual(entry.key.len, key.len);
    }
}

test "map: an empty map parses to an empty result" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const got = try rig.ok(Ports, try rig.obj(&.{}));
    try testing.expectEqual(@as(usize, 0), got.count());
    try testing.expectEqual(@as(usize, 0), got.keys().len);
    try testing.expect(got.get("x") == null);
}

test "map: every non-map value is a type mismatch naming its tag" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.mismatch(Ports, try rig.ints(&.{ 1, 2 }), "map", "array");
    try rig.mismatch(Ports, try rig.arr(&.{}), "map", "array");
    try rig.mismatch(Ports, .null, "map", "null");
    try rig.mismatch(Ports, int(1), "map", "int");
    try rig.mismatch(Ports, str("http"), "map", "string");
    try rig.mismatch(Ports, .{ .bytes = "x" }, "map", "bytes");
    const field = try rig.obj(&.{kv("ports", try rig.ints(&.{80}))});
    try rig.fails(Config, field, error.TypeMismatch, "ports: expected map, found array");
}

test "map: a bad value reports the key as a path segment" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const range = "ports.http: 70000 is out of range for u16";
    const ports = try rig.obj(&.{ kv("ssh", int(22)), kv("http", int(70000)) });
    const big = try rig.obj(&.{kv("ports", ports)});
    try rig.fails(Config, big, error.IntegerOutOfRange, range);
    const root = try rig.obj(&.{ kv("a", int(1)), kv("b", int(-1)) });
    try rig.fails(Ports, root, error.IntegerOutOfRange, "b: -1 is out of range for u16");
    const typed = try rig.obj(&.{kv("a", str("x"))});
    try rig.fails(Ports, typed, error.TypeMismatch, "a: expected integer, found string");
}

test "map: a key that is not a bare word is written quoted in the path" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const dotted = try rig.obj(&.{kv("ports", try rig.obj(&.{kv("a.b", int(-1))}))});
    const message = "ports[\"a.b\"]: -1 is out of range for u16";
    try rig.fails(Config, dotted, error.IntegerOutOfRange, message);
    const empty_key = try rig.obj(&.{kv("", int(-1))});
    try rig.fails(Ports, empty_key, error.IntegerOutOfRange, "[\"\"]: -1 is out of range for u16");
}

test "map: as a struct field, of structs, of slices and of Value" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const one_port = try rig.obj(&.{kv("x", int(7))});
    const config = try rig.ok(Config, try rig.obj(&.{kv("ports", one_port)}));
    try testing.expectEqual(@as(u16, 7), config.ports.get("x").?);

    const a = try rig.obj(&.{ kv("host", str("ha")), kv("port", int(1)) });
    const b = try rig.obj(&.{kv("host", str("hb"))});
    const servers = try rig.ok(Servers, try rig.obj(&.{ kv("a", a), kv("b", b) }));
    try testing.expectEqualStrings("ha", servers.get("a").?.host);
    try testing.expectEqual(@as(u16, 8080), servers.get("b").?.port);
    const no_host = try rig.obj(&.{kv("a", try rig.obj(&.{}))});
    try rig.fails(Servers, no_host, error.MissingField, "a: missing field \"host\"");

    const p_items = try rig.ints(&.{ 1, 2 });
    const list_in = try rig.obj(&.{ kv("p", p_items), kv("q", try rig.arr(&.{})) });
    const lists = try rig.ok(Lists, list_in);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, lists.get("p").?);
    try testing.expectEqual(@as(usize, 0), lists.get("q").?.len);
    const bad = try rig.obj(&.{kv("p", try rig.arr(&.{ int(1), .null }))});
    try rig.fails(Lists, bad, error.TypeMismatch, "p[1]: expected integer, found null");

    const raw = try rig.ok(std.array_hash_map.String(Value), try rig.obj(&.{kv("any", .null)}));
    try testing.expect(raw.get("any").? == .null);
    const optional = try rig.ok(?Ports, .null);
    try testing.expect(optional == null);
}

test "map depth: a map is a container, 128 nested pass and the 129th is TooDeep" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const shallow = try rig.ok(Nest(3), try map_chain(&rig, 3));
    try testing.expectEqual(@as(u8, 1), shallow.get("k").?.get("k").?.get("k").?);
    const exact = try rig.ok(Nest(128), try map_chain(&rig, 128));
    try testing.expectEqual(@as(usize, 1), exact.count());
    const over = try map_chain(&rig, 129);
    try testing.expectError(error.TooDeep, parse(Nest(129), &rig.tree, over, &rig.diag));
    const message = rig.diag.message();
    try testing.expect(std.mem.endsWith(u8, message, ": exceeds nesting depth limit 128"));
    try testing.expect(std.mem.startsWith(u8, message, core.diagnostics.truncation_marker));
    try testing.expectEqual(position_none, rig.diag.line);
    const mid = try map_chain(&rig, 127);
    try testing.expectEqual(@as(usize, 1), (try rig.ok(Nest(127), mid)).count());
}

test "map: an allocator that fails is OutOfMemory with a path and leaks nothing" {
    var entries: [1]core.Map.Entry = undefined;
    var inner = core.Map.init(&entries);
    try inner.put("x", int(1));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    try testing.expectError(error.OutOfMemory, parse(Ports, &tree, .{ .map = inner }, &diag));
    try testing.expect(std.mem.endsWith(u8, diag.message(), "failed: OutOfMemory"));
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
}

test "map: seeded random maps match a plain list of pairs, in order, by lookup" {
    var seed: u64 = 0;
    while (seed < 24) : (seed += 1) {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        const arena = rig.tree.arena.allocator();
        const count = random.intRangeAtMost(u32, 0, 40);
        const pairs = try arena.alloc(Pair, count);
        const model = try arena.alloc(u16, count);
        for (pairs, model, 0..) |*pair, *expected, index| {
            expected.* = random.int(u16);
            const key = try std.fmt.allocPrint(arena, "k{d}-{d}", .{ index, random.int(u8) });
            pair.* = kv(key, .{ .uint = expected.* });
        }
        const input = try rig.obj(pairs);
        const got = try rig.ok(Ports, input);
        try testing.expectEqual(@as(usize, count), got.count());
        for (pairs, model, got.keys(), got.values()) |pair, expected, key, value| {
            try testing.expectEqualStrings(pair.key, key);
            try testing.expectEqual(expected, value);
            try testing.expectEqual(expected, got.get(pair.key).?);
        }
    }
}

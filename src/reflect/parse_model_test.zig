//! reflect/parse model tests — seeded random valid documents compared with the plain struct that
//! built them, one seeded mutation per document with a known error, and a `std.testing.fuzz`
//! run of random `Value` trees against a plain model of `Point` and `[2]u8`.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Context = context_mod.Context;
const Path = context_mod.Path;
const ParseError = context_mod.ParseError;
const parse = parse_mod.parse;
const parse_value = parse_mod.parse_value;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const nesting_max = core.value.nesting_max;
const Rig = rig_mod.Rig;
const Pair = rig_mod.Pair;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;
const expect_untouched = rig_mod.expect_untouched;
const Point = rig_mod.Point;
const Server = rig_mod.Server;
const Wrapper = rig_mod.Wrapper;
const Fleet = rig_mod.Fleet;
const Empty = rig_mod.Empty;

const Sample = struct {
    id: u32,
    flag: bool,
    name: []const u8,
    vals: []const i16,
    pair: [2]u8,
    points: []const Point,
    opt: ?u16 = null,
};

// ---------------------------------------------------------------------------------------------
// Model: seeded random valid documents for `Sample`, shuffled key order, compared with the plain
// struct that was used to build them. Then one seeded mutation per document with a known error.
// ---------------------------------------------------------------------------------------------

const Case = struct { pairs: [8]Pair, count: usize, expected: Sample };

fn int_or_uint(rng: std.Random, number: anytype) Value {
    if (number >= 0 and rng.boolean()) return .{ .uint = @intCast(number) };
    return .{ .int = number };
}

fn gen_vals(rig: *Rig, rng: std.Random, out: *Case, len_min: usize) !void {
    const arena = rig.tree.arena.allocator();
    const vals = try arena.alloc(i16, len_min + rng.uintAtMost(usize, 8));
    const items = try arena.alloc(Value, vals.len);
    for (vals, items) |*number, *item| {
        number.* = rng.int(i16);
        item.* = int_or_uint(rng, number.*);
    }
    out.expected.vals = vals;
    out.pairs[3] = kv("vals", .{ .array = items });
}

fn gen_points(rig: *Rig, rng: std.Random, out: *Case) !void {
    const arena = rig.tree.arena.allocator();
    const points = try arena.alloc(Point, rng.uintAtMost(usize, 4));
    const items = try arena.alloc(Value, points.len);
    for (points, items) |*point, *item| {
        point.* = .{ .x = rng.int(i32), .y = rng.int(i32) };
        item.* = try rig.obj(&.{ kv("y", int_or_uint(rng, point.y)), kv("x", int(point.x)) });
    }
    out.expected.points = points;
    out.pairs[5] = kv("points", .{ .array = items });
}

fn gen_case(rig: *Rig, rng: std.Random) !Case {
    const arena = rig.tree.arena.allocator();
    var case: Case = undefined;
    const name = try arena.alloc(u8, rng.uintAtMost(usize, 12));
    for (name) |*byte| byte.* = rng.intRangeAtMost(u8, 'a', 'z');
    const id = rng.int(u32);
    case.expected = .{
        .id = id,
        .flag = rng.boolean(),
        .name = name,
        .vals = &.{},
        .pair = .{ rng.int(u8), rng.int(u8) },
        .points = &.{},
    };
    try gen_vals(rig, rng, &case, 0);
    try gen_points(rig, rng, &case);
    const pair_in = try rig.ints(&.{ case.expected.pair[0], case.expected.pair[1] });
    case.pairs[0] = kv("id", int_or_uint(rng, id));
    case.pairs[1] = kv("flag", .{ .bool = case.expected.flag });
    case.pairs[2] = kv("name", str(name));
    case.pairs[4] = kv("pair", pair_in);
    case.count = 6;
    switch (rng.uintLessThan(u8, 3)) {
        0 => {},
        1 => {
            case.pairs[6] = kv("opt", .null);
            case.count = 7;
        },
        else => {
            case.expected.opt = rng.int(u16);
            case.pairs[6] = kv("opt", int_or_uint(rng, case.expected.opt.?));
            case.count = 7;
        },
    }
    return case;
}

fn build(rig: *Rig, rng: std.Random, case: *Case) !Value {
    rng.shuffle(Pair, case.pairs[0..case.count]);
    return rig.obj(case.pairs[0..case.count]);
}

test "model: seeded random valid documents parse to the struct that built them" {
    var prng = std.Random.DefaultPrng.init(0x5160_0006);
    const rng = prng.random();
    for (0..300) |_| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        var case = try gen_case(&rig, rng);
        const input = try build(&rig, rng, &case);
        input.map.check_invariants();
        const got = try rig.ok(Sample, input);
        try testing.expectEqualDeep(case.expected, got);
        try testing.expectEqual(case.expected.opt, got.opt);
    }
}

fn drop_pair(case: *Case, key: []const u8) void {
    for (case.pairs[0..case.count], 0..) |pair, index| {
        if (!std.mem.eql(u8, pair.key, key)) continue;
        case.pairs[index] = case.pairs[case.count - 1];
        case.count -= 1;
        return;
    }
    unreachable; // proof: gen_case always writes id, flag, name, vals, pair and points.
}

fn set_pair(case: *Case, key: []const u8, value: Value) void {
    for (case.pairs[0..case.count]) |*pair| {
        if (std.mem.eql(u8, pair.key, key)) {
            pair.value = value;
            return;
        }
    }
    unreachable; // proof: same as `drop_pair`.
}

const Mutation = struct { err: ParseError, message: []const u8 };

/// Applies mutation `kind` to `case` and returns the error and the message it must produce.
fn mutate(rig: *Rig, rng: std.Random, case: *Case, kind: u8, buf: []u8) !Mutation {
    switch (kind) {
        0 => {
            drop_pair(case, "id");
            return .{ .err = error.MissingField, .message = "missing field \"id\"" };
        },
        1 => {
            case.pairs[case.count] = kv("extra", int(1));
            case.count += 1;
            return .{ .err = error.UnknownField, .message = "unknown field \"extra\"" };
        },
        2 => {
            set_pair(case, "flag", .null);
            return .{ .err = error.TypeMismatch, .message = "flag: expected bool, found null" };
        },
        3 => {
            var len = rng.uintAtMost(usize, 5);
            if (len == 2) len = 3;
            const raw = try rig.tree.arena.allocator().alloc(Value, len);
            @memset(raw, int(1));
            set_pair(case, "pair", .{ .array = raw });
            const text = "pair: expected array of length 2, found {d}";
            const message = try std.fmt.bufPrint(buf, text, .{len});
            return .{ .err = error.LengthMismatch, .message = message };
        },
        else => return mutate_element(rig, rng, case, kind, buf),
    }
}

fn mutate_element(rig: *Rig, rng: std.Random, case: *Case, kind: u8, buf: []u8) !Mutation {
    switch (kind) {
        4 => {
            const items = try rig.tree.arena.allocator().alloc(Value, 1 + rng.uintAtMost(usize, 6));
            @memset(items, int(1));
            const at = rng.uintLessThan(usize, items.len);
            items[at] = str("x");
            set_pair(case, "vals", .{ .array = items });
            const text = "vals[{d}]: expected integer, found string";
            const message = try std.fmt.bufPrint(buf, text, .{at});
            return .{ .err = error.TypeMismatch, .message = message };
        },
        5 => {
            set_pair(case, "id", .{ .float = 1.5 });
            return .{ .err = error.TypeMismatch, .message = "id: expected integer, found float" };
        },
        6 => {
            set_pair(case, "name", .{ .bytes = "ab" });
            return .{ .err = error.TypeMismatch, .message = "name: expected string, found bytes" };
        },
        else => {
            set_pair(case, "id", int(-1 - @as(i64, rng.int(u16))));
            const text = "id: {d} is out of range for u32";
            const message = try std.fmt.bufPrint(buf, text, .{case.pairs[0].value.int});
            return .{ .err = error.IntegerOutOfRange, .message = message };
        },
    }
}

test "model: one seeded mutation per document yields the one error it must" {
    var prng = std.Random.DefaultPrng.init(0x5160_0007);
    const rng = prng.random();
    for (0..400) |round| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        var case = try gen_case(&rig, rng);
        var buf: [96]u8 = undefined;
        const expected = try mutate(&rig, rng, &case, @intCast(round % 8), &buf);
        const input = try build(&rig, rng, &case);
        try rig.fails(Sample, input, expected.err, expected.message);
    }
}

// ---------------------------------------------------------------------------------------------
// Fuzz (std.testing.fuzz, Zig 0.16): a random Value tree is parsed as `Point` and as `[2]u8`.
// Both results are compared with a plain model, including which error comes first; every failure
// writes a position-less message, every success leaves the diagnostics untouched.
// ---------------------------------------------------------------------------------------------

const key_pool = [_][]const u8{ "x", "y", "z", "id", "x" };

fn fuzz_value(rig: *Rig, smith: *testing.Smith, depth: u32) anyerror!Value {
    const choice = smith.value(u8) % (if (depth >= 3) @as(u8, 8) else 10);
    switch (choice) {
        0 => return .null,
        1 => return .{ .bool = smith.value(bool) },
        2 => return .{ .int = @as(i64, smith.value(i16)) },
        3 => return .{ .uint = smith.value(u16) },
        4 => return .{ .float = 2.5 },
        5 => return .{ .string = "s" },
        6 => return .{ .bytes = "b" },
        7 => return .{ .int = @as(i64, smith.value(i8)) },
        8 => {
            const items = try rig.tree.arena.allocator().alloc(Value, smith.value(u8) % 4);
            for (items) |*item| item.* = try fuzz_value(rig, smith, depth + 1);
            return .{ .array = items };
        },
        else => {
            var map = try rig.tree.new_map(4);
            for (0..smith.value(u8) % 4) |_| {
                const key = key_pool[smith.value(u8) % key_pool.len];
                const child = try fuzz_value(rig, smith, depth + 1);
                if (map.get(key) != null) continue;
                // proof: the key is new and at most 3 puts go into 4 slots.
                map.put(key, child) catch unreachable;
            }
            return .{ .map = map };
        },
    }
}

fn model_u8(value: Value) ParseError!u8 {
    return switch (value) {
        .int => |n| std.math.cast(u8, n) orelse error.IntegerOutOfRange,
        .uint => |n| std.math.cast(u8, n) orelse error.IntegerOutOfRange,
        else => error.TypeMismatch,
    };
}

fn model_i32(value: Value) ParseError!i32 {
    return switch (value) {
        .int => |n| std.math.cast(i32, n) orelse error.IntegerOutOfRange,
        .uint => |n| std.math.cast(i32, n) orelse error.IntegerOutOfRange,
        else => error.TypeMismatch,
    };
}

fn model_pair(value: Value) ParseError![2]u8 {
    if (value != .array) return error.TypeMismatch;
    if (value.array.len != 2) return error.LengthMismatch;
    return .{ try model_u8(value.array[0]), try model_u8(value.array[1]) };
}

fn model_point(value: Value) ParseError!Point {
    if (value != .map) return error.TypeMismatch;
    for (value.map.items()) |entry| {
        const known = std.mem.eql(u8, entry.key, "x") or std.mem.eql(u8, entry.key, "y");
        if (!known) return error.UnknownField;
    }
    const x = value.map.get("x") orelse return error.MissingField;
    const y = value.map.get("y") orelse return error.MissingField;
    return .{ .x = try model_i32(x.*), .y = try model_i32(y.*) };
}

fn check_against_model(comptime T: type, rig: *Rig, value: Value, model: ParseError!T) !void {
    rig.diag = sentinel();
    if (model) |want| {
        const got = try parse(T, &rig.tree, value, &rig.diag);
        try testing.expectEqualDeep(want, got);
        try expect_untouched(&rig.diag);
    } else |err| {
        try testing.expectError(err, parse(T, &rig.tree, value, &rig.diag));
        try testing.expect(rig.diag.message().len > 0);
        try testing.expect(!std.mem.eql(u8, rig.diag.message(), "untouched"));
        try testing.expectEqual(position_none, rig.diag.line);
        try testing.expectEqual(position_none, rig.diag.col);
    }
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const value = try fuzz_value(&rig, smith, 0);
    try check_against_model(Point, &rig, value, model_point(value));
    try check_against_model([2]u8, &rig, value, model_pair(value));
}

const fuzz_corpus = [_][]const u8{
    &.{},
    &([_]u8{0} ** 40),
    &([_]u8{0xff} ** 40),
    &([_]u8{ 9, 2, 0, 2, 2, 0, 2, 3, 0, 9, 0 } ++ [_]u8{0} ** 16),
    &([_]u8{ 8, 2, 2, 0, 1, 0, 2, 0, 5, 0 } ++ [_]u8{0} ** 16),
};

test "fuzz: random value trees agree with the plain model for Point and [2]u8" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

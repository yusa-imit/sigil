//! reflect round-trip property test — plan 003 item 9. A seeded generator builds random instances
//! of a fixed type matrix (bool, sized integers, floats, UTF-8 strings, enums, optionals, structs
//! with `sigil_options`, arrays, slices, tagged unions, string maps, `core.Value`,
//! `core.Timestamp` and a hooked type) nested three containers deep, then checks the pipeline
//! `stringify` -> `parse` against the original and `stringify` again against the first `Value`
//! with `core.value.eql`. A failure logs its seed; one seed reproduces one instance exactly.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");
const stringify_mod = @import("stringify.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const Context = context_mod.Context;
const ParseError = context_mod.ParseError;
const StringifyError = context_mod.StringifyError;
const assert = std.debug.assert;
const testing = std.testing;
const Rig = rig_mod.Rig;

/// Seeds `0..seed_count` each build, convert and compare one instance of `Root`.
const seed_count: u64 = 1000;
const items_max: u32 = 3;

const GenError = error{ OutOfMemory, DuplicateKey, OutOfSpace };

const Mode = enum { fast, slow, off };

/// An integer count of tenths, written on the wire as a plain integer by a hook.
const Tenths = struct {
    units: i32,

    pub fn sigilParse(context: *Context, value: Value) ParseError!Tenths {
        assert(context.depth <= core.value.nesting_max);
        assert(context.path.count <= context.depth);
        const number = switch (value) {
            .int => |number| number,
            else => return error.TypeMismatch,
        };
        const units = std.math.cast(i32, number) orelse return error.IntegerOutOfRange;
        return .{ .units = units };
    }

    pub fn sigilStringify(self: *const Tenths, context: *Context) StringifyError!Value {
        assert(@intFromPtr(self) != 0);
        assert(context.depth <= core.value.nesting_max);
        return .{ .int = self.units };
    }
};

const Leaf = struct {
    flag: bool,
    small: i8,
    wide: i64,
    big: u64,
    ratio: f64,
    single: f32,
    name: []const u8,
    mode: Mode,
    note: ?[]const u8,
    stamp: core.Timestamp,
    tenths: Tenths,
    retry_count: u8 = 3,

    pub const sigil_options = .{ .rename_all = .kebab_case };
};

const Shape = union(enum) {
    none,
    circle: f32,
    rect: Leaf,
    many: []const Leaf,

    pub const sigil_options = .{ .rename = .{ .many = "multiple" } };
};

const Kind = enum { alpha, beta_gamma };

/// Odd-width integers, a renamed field, optional containers and `deny_unknown_fields`.
const Extra = struct {
    tiny: u3,
    odd: i7,
    word: u32,
    kind: Kind,
    shape: ?Shape,
    leaves: ?[]const Leaf,

    pub const sigil_options = .{
        .rename = .{ .tiny = "t" },
        .deny_unknown_fields = true,
    };
};

const Branch = struct {
    leaf: Leaf,
    triple: [3]u16,
    shape: Shape,
    tags: std.array_hash_map.String(Leaf),
    free: Value,
};

const Root = struct {
    branch: Branch,
    branches: []const Branch,
    by_name: std.array_hash_map.String(Branch),
    maybe: ?Branch,
    extra: Extra,
};

// ---------------------------------------------------------------------------------------------
// Generator: one comptime function per kind, driven by the type, allocating from the tree arena.
// ---------------------------------------------------------------------------------------------

fn gen_text(rng: std.Random, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const code_point_count = rng.uintAtMost(usize, 6);
    var buffer = try arena.alloc(u8, code_point_count * 4);
    var used: usize = 0;
    for (0..code_point_count) |_| {
        const code_point: u21 = switch (rng.uintLessThan(u8, 5)) {
            0 => rng.intRangeAtMost(u21, 0x20, 0x7e),
            1 => rng.intRangeAtMost(u21, 0x80, 0x7ff),
            2 => rng.intRangeAtMost(u21, 0x800, 0xd7ff),
            3 => rng.intRangeAtMost(u21, 0xe000, 0xffff),
            else => rng.intRangeAtMost(u21, 0x10000, 0x10ffff),
        };
        used += std.unicode.utf8Encode(code_point, buffer[used..]) catch unreachable; // proof:
        // every drawn code point is a scalar value and 4 bytes were reserved per code point.
    }
    assert(used <= buffer.len);
    assert(std.unicode.utf8ValidateSlice(buffer[0..used]));
    return buffer[0..used];
}

fn gen_timestamp(rng: std.Random) core.Timestamp {
    const stamp: core.Timestamp = .{
        .seconds = rng.int(i64),
        .nanoseconds = rng.uintLessThan(u32, 1_000_000_000),
        .offset_minutes = if (rng.boolean()) rng.intRangeAtMost(i16, -1439, 1439) else null,
    };
    assert(stamp.nanoseconds < 1_000_000_000);
    assert(stamp.offset_minutes == null or @abs(stamp.offset_minutes.?) < 1440);
    return stamp;
}

fn gen_scalar_value(rng: std.Random, arena: std.mem.Allocator) GenError!Value {
    return switch (rng.uintLessThan(u8, 8)) {
        0 => .null,
        1 => .{ .bool = rng.boolean() },
        2 => .{ .int = rng.int(i64) },
        3 => .{ .uint = rng.intRangeAtMost(u64, std.math.maxInt(i64) + 1, std.math.maxInt(u64)) },
        4 => .{ .float = (rng.float(f64) - 0.5) * 1e9 },
        5 => .{ .string = try gen_text(rng, arena) },
        6 => .{ .bytes = try arena.dupe(u8, &.{ rng.int(u8), rng.int(u8) }) },
        else => .{ .timestamp = gen_timestamp(rng) },
    };
}

/// A `core.Value`: a scalar, an array of scalars or a map of scalars (one container deep).
fn gen_value(rng: std.Random, arena: std.mem.Allocator) GenError!Value {
    switch (rng.uintLessThan(u8, 3)) {
        0 => return gen_scalar_value(rng, arena),
        1 => {
            const items = try arena.alloc(Value, rng.uintAtMost(usize, items_max));
            for (items) |*item| item.* = try gen_scalar_value(rng, arena);
            return .{ .array = items };
        },
        else => {
            const count = rng.uintAtMost(u32, items_max);
            const buffer = try arena.alloc(core.Map.Entry, count);
            var map = core.Map.init(buffer);
            for (0..count) |index| {
                const key = try std.fmt.allocPrint(arena, "k{d}", .{index});
                try map.put(key, try gen_scalar_value(rng, arena));
            }
            return .{ .map = map };
        },
    }
}

fn gen_string_map(
    comptime T: type,
    comptime Item: type,
    rng: std.Random,
    arena: std.mem.Allocator,
) GenError!T {
    assert(T == std.array_hash_map.String(Item));
    var map: T = .empty;
    const count = rng.uintAtMost(u32, items_max);
    try map.ensureTotalCapacity(arena, count);
    for (0..count) |index| {
        const suffix = try gen_text(rng, arena);
        const key = try std.fmt.allocPrint(arena, "k{d}{s}", .{ index, suffix });
        map.putAssumeCapacityNoClobber(key, try gen(Item, rng, arena));
    }
    assert(map.count() == count);
    return map;
}

fn gen(comptime T: type, rng: std.Random, arena: std.mem.Allocator) GenError!T {
    if (T == Value) return gen_value(rng, arena);
    if (T == core.Timestamp) return gen_timestamp(rng);
    if (T == Tenths) return .{ .units = rng.int(i32) };
    if (T == []const u8) return gen_text(rng, arena);
    if (comptime parse_mod.string_map_value(T)) |Item| return gen_string_map(T, Item, rng, arena);
    switch (@typeInfo(T)) {
        .bool => return rng.boolean(),
        .int => return rng.int(T),
        .float => return @as(T, @floatCast((rng.float(f64) - 0.5) * 1e6)),
        .@"enum" => return rng.enumValue(T),
        .optional => |info| {
            const present = rng.boolean();
            const result: T = if (present) try gen(info.child, rng, arena) else null;
            assert((result != null) == present);
            return result;
        },
        .array => |info| {
            var result: T = undefined; // Every element is assigned below.
            for (&result) |*slot| slot.* = try gen(info.child, rng, arena);
            return result;
        },
        .pointer => |info| {
            const items = try arena.alloc(info.child, rng.uintAtMost(usize, items_max));
            for (items) |*item| item.* = try gen(info.child, rng, arena);
            assert(items.len <= items_max);
            return items;
        },
        .@"struct" => |info| {
            var result: T = undefined; // Every field is assigned below.
            inline for (info.fields) |field| {
                @field(result, field.name) = try gen(field.type, rng, arena);
            }
            return result;
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            switch (rng.enumValue(Tag)) {
                inline else => |tag| {
                    const Payload = @FieldType(T, @tagName(tag));
                    if (Payload == void) return @unionInit(T, @tagName(tag), {});
                    return @unionInit(T, @tagName(tag), try gen(Payload, rng, arena));
                },
            }
        },
        else => comptime unreachable,
    }
}

// ---------------------------------------------------------------------------------------------
// Comparison: structural equality of two instances; floats by bit pattern (all are finite).
// ---------------------------------------------------------------------------------------------

fn same(comptime T: type, a: T, b: T) bool {
    comptime assert(@typeName(T).len > 0);
    if (T == Value) return core.value.eql(a, b) catch false;
    if (T == core.Timestamp) return std.meta.eql(a, b);
    if (T == []const u8) return std.mem.eql(u8, a, b);
    if (comptime parse_mod.string_map_value(T)) |Item| {
        if (a.count() != b.count()) return false;
        for (a.keys(), a.values(), b.keys(), b.values()) |key_a, item_a, key_b, item_b| {
            if (!std.mem.eql(u8, key_a, key_b)) return false;
            if (!same(Item, item_a, item_b)) return false;
        }
        return true;
    }
    switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => return a == b,
        .float => |info| {
            const Bits = std.meta.Int(.unsigned, info.bits);
            return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return same(@typeInfo(T).optional.child, a.?, b.?);
        },
        .array, .pointer => {
            if (a.len != b.len) return false;
            for (a, b) |item_a, item_b| {
                if (!same(std.meta.Child(T), item_a, item_b)) return false;
            }
            return true;
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!same(field.type, @field(a, field.name), @field(b, field.name))) return false;
            }
            return true;
        },
        .@"union" => |info| {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| {
                    const Payload = @FieldType(T, @tagName(tag));
                    if (Payload == void) return true;
                    return same(Payload, payload, @field(b, @tagName(tag)));
                },
            }
            comptime assert(info.tag_type != null);
        },
        else => comptime unreachable,
    }
}

/// What the seeds actually produced: the generator must reach every branch of the matrix, or
/// the property would pass vacuously.
const Coverage = struct {
    shape_tags: [4]u32 = .{0} ** 4,
    value_tags: [value_tag_count]u32 = .{0} ** value_tag_count,
    optional_some: u32 = 0,
    optional_none: u32 = 0,
    deep: u32 = 0,
    modes_seen: [3]u32 = .{0} ** 3,

    const value_tag_count = @typeInfo(std.meta.Tag(Value)).@"enum".fields.len;

    fn tally(coverage: *Coverage, root: Root) void {
        assert(root.branches.len <= items_max);
        coverage.tally_branch(root.branch);
        for (root.branches) |branch| coverage.tally_branch(branch);
        for (root.by_name.values()) |branch| {
            coverage.tally_branch(branch);
            const many = switch (branch.shape) {
                .many => |leaves| leaves.len > 0,
                else => false,
            };
            // Root -> map -> Branch -> union map -> array -> Leaf: five containers.
            if (many and branch.tags.count() > 0) coverage.deep += 1;
        }
        if (root.maybe) |branch| coverage.tally_branch(branch);
        coverage.count_optional(root.maybe != null);
        coverage.count_optional(root.extra.shape != null);
        coverage.count_optional(root.extra.leaves != null);
    }

    fn tally_branch(coverage: *Coverage, branch: Branch) void {
        coverage.shape_tags[@intFromEnum(std.meta.activeTag(branch.shape))] += 1;
        coverage.value_tags[@intFromEnum(std.meta.activeTag(branch.free))] += 1;
        coverage.modes_seen[@intFromEnum(branch.leaf.mode)] += 1;
        coverage.count_optional(branch.leaf.note != null);
    }

    fn count_optional(coverage: *Coverage, present: bool) void {
        if (present) coverage.optional_some += 1 else coverage.optional_none += 1;
    }

    fn expect_complete(coverage: *const Coverage) !void {
        for (coverage.shape_tags) |count| try testing.expect(count > 0);
        for (coverage.value_tags) |count| try testing.expect(count > 0);
        for (coverage.modes_seen) |count| try testing.expect(count > 0);
        try testing.expect(coverage.optional_some > 0);
        try testing.expect(coverage.optional_none > 0);
        try testing.expect(coverage.deep > 0);
    }
};

fn round_trip(seed: u64, coverage: *Coverage) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const original = try gen(Root, prng.random(), rig.tree.arena.allocator());
    coverage.tally(original);

    const first = try stringify_mod.stringify(Root, &rig.tree, original, &rig.diag);
    try testing.expect(first == .map);
    const parsed = try parse_mod.parse(Root, &rig.tree, first, &rig.diag);
    try testing.expect(same(Root, original, parsed));
    const second = try stringify_mod.stringify(Root, &rig.tree, parsed, &rig.diag);
    try testing.expect(second == .map);
    // Two separate conversions never share storage.
    try testing.expect(first.map.entries.ptr != second.map.entries.ptr);
    try testing.expect(try core.value.eql(first, second));
    try rig_mod.expect_untouched(&rig.diag);
}

test "round-trip: 1,000 seeded instances of the type matrix survive stringify -> parse" {
    var coverage: Coverage = .{};
    for (0..seed_count) |seed| {
        round_trip(seed, &coverage) catch |err| {
            std.log.err("round-trip failed at seed {d}: {s}", .{ seed, @errorName(err) });
            return err;
        };
    }
    try coverage.expect_complete();
}

test "round-trip: one seed is reproducible, two seeds differ" {
    var first: Rig = undefined;
    first.init();
    defer first.deinit();
    var second: Rig = undefined;
    second.init();
    defer second.deinit();

    var prng_a = std.Random.DefaultPrng.init(42);
    var prng_b = std.Random.DefaultPrng.init(42);
    const a = try gen(Root, prng_a.random(), first.tree.arena.allocator());
    const b = try gen(Root, prng_b.random(), second.tree.arena.allocator());
    try testing.expect(same(Root, a, b));

    var prng_c = std.Random.DefaultPrng.init(43);
    const c = try gen(Root, prng_c.random(), second.tree.arena.allocator());
    try testing.expect(!same(Root, a, c));
}

const Pair = struct { text: []const u8, shape: Shape, note: ?u8, value: Value };

const Words = std.array_hash_map.String(u8);

test "round-trip: the comparison sees a change in every kind of field" {
    const leaves = [_]Leaf{ leaf_sample(), leaf_sample() };
    const base: Pair = .{
        .text = "abc",
        .shape = .{ .many = leaves[0..2] },
        .note = 5,
        .value = .{ .array = &.{.{ .int = 1 }} },
    };
    try testing.expect(same(Pair, base, base));

    var other = base;
    other.text = "abd";
    try testing.expect(!same(Pair, base, other));
    other = base;
    other.shape = .{ .many = leaves[0..1] };
    try testing.expect(!same(Pair, base, other));
    other.shape = .none;
    try testing.expect(!same(Pair, base, other));
    other = base;
    other.note = null;
    try testing.expect(!same(Pair, base, other));
    other.note = 6;
    try testing.expect(!same(Pair, base, other));
    other = base;
    other.value = .{ .array = &.{.{ .uint = 1 << 63 }} };
    try testing.expect(!same(Pair, base, other));

    var changed = leaves;
    changed[1].stamp.offset_minutes = 60;
    other = base;
    other.shape = .{ .many = changed[0..2] };
    try testing.expect(!same(Pair, base, other));
    changed = leaves;
    changed[1].ratio = @bitCast(@as(u64, @bitCast(changed[1].ratio)) ^ 1);
    other.shape = .{ .many = changed[0..2] };
    try testing.expect(!same(Pair, base, other));
}

test "round-trip: the comparison sees a changed string map" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const arena = rig.tree.arena.allocator();
    var a: Words = .empty;
    try a.put(arena, "x", 1);
    var b: Words = .empty;
    try b.put(arena, "x", 1);
    try testing.expect(same(Words, a, b));
    try b.put(arena, "x", 2);
    try testing.expect(!same(Words, a, b));
    var c: Words = .empty;
    try c.put(arena, "y", 1);
    try testing.expect(!same(Words, a, c));
    try c.put(arena, "x", 1);
    try testing.expect(!same(Words, a, c));
}

fn leaf_sample() Leaf {
    return .{
        .flag = true,
        .small = -3,
        .wide = 1,
        .big = 2,
        .ratio = 0.25,
        .single = 0.5,
        .name = "n",
        .mode = .fast,
        .note = null,
        .stamp = .{ .seconds = 1, .nanoseconds = 2, .offset_minutes = null },
        .tenths = .{ .units = 4 },
    };
}

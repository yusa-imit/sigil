//! Test-only property harness shared by `msgpack` and `cbor` (plan 007 item 9, ADR 0006
//! sections 2 and 10). `PropertyType(codec)` returns the three families both formats run:
//!
//! 1. Seeded `Value` trees in normal form (`uint` only above `maxInt(i64)`, one NaN, bounded
//!    depth and width, head-size boundaries) go encode -> decode -> `core.eql`, and a second
//!    encode is byte-identical. A failing seed is logged; the run reproduces from
//!    `(seed, commit)`.
//! 2. Seeded byte mutation (bit flip, byte replace, delete, insert, truncate, chunk copy) of
//!    caller-supplied valid inputs.
//! 3. `check_input`, the one oracle for the mutations and the `std.testing.fuzz` entry: bytes
//!    either decode to a tree whose invariants hold, whose arena stays linear in the input and
//!    whose re-encoding is a fixed point, or fail with a typed error carrying a position (line
//!    and column >= 1). Nothing panics.
//!
//! `codec` supplies `parse(tree, input, diag)`, `write(w, value, diag)`, `random_timestamp(random)`
//! (a timestamp the format can write and read back) and `eql_roundtrip` (false when the encoder
//! reorders maps). Allocation: everything comes from the caller's `gpa` and `arena`.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

pub const seed_count: u32 = 1000;
pub const sentinel_line: u32 = 777;
pub const fuzz_bytes_max: u32 = 512;

/// Generated containers nest at most this deep below the root; the formats allow 128.
const depth_gen_max: u32 = 4;
const width_gen_max: u32 = 4;
const walk_steps_max: u32 = 1 << 20;
/// The arena of an accepted input stays under `arena_per_byte_max * len + arena_slack`.
const arena_per_byte_max: usize = 96;
const arena_slack: usize = 16 * 1024;

const nan_bits: u64 = 0x7ff8000000000000;

const text_pieces = [_][]const u8{
    "a", "Z", "-", "\"", "\\", "\n", "\x00", "\x7f", "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80",
};

/// Lengths at the edges of the str, bin and text heads of both formats.
const run_lengths = [_]u32{ 15, 16, 23, 24, 31, 32, 255, 256 };

const int_edges = [_]i64{
    0,                    -1,                   23,         24,         -24,         -25,
    127,                  128,                  -32,        -33,        255,         256,
    -128,                 -129,                 -256,       -257,       32767,       32768,
    -32768,               -32769,               65535,      65536,      -65536,      -65537,
    2147483647,           2147483648,           4294967295, 4294967296, -2147483648, -2147483649,
    std.math.maxInt(i64), std.math.minInt(i64),
};

const float_edges = [_]f64{
    0.0,
    -0.0,
    1.0,
    -1.5,
    1.5,
    100000.0,
    65504.0,
    5.960464477539063e-8,
    6.103515625e-5,
    1.1,
    3.4028234663852886e38,
    5e-324,
    -1.5e300,
    std.math.inf(f64),
    -std.math.inf(f64),
};

const interesting_bytes = [_]u8{
    0x00, 0x7f, 0x80, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc4, 0xc7, 0xc9, 0xca, 0xcb, 0xcc, 0xcf,
    0xd0, 0xd3, 0xd4, 0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xff, 0x17, 0x18,
    0x1b, 0x1c, 0x3b, 0x5f, 0x61, 0x7f, 0xc2, 0xc3, 0xf8, 0xf9, 0xfa, 0xfb, 0xfd, 0xfe,
};

pub const Outcome = enum { accepted, rejected };

/// What a tree holds, for coverage assertions.
pub const Stats = struct {
    nodes: u32 = 0,
    maps: u32 = 0,
    arrays: u32 = 0,
    stamps: u32 = 0,
    uints: u32 = 0,
    nulls: u32 = 0,
    byte_strings: u32 = 0,
    floats: u32 = 0,

    fn add(stats: *Stats, other: Stats) void {
        inline for (@typeInfo(Stats).@"struct".fields) |field| {
            @field(stats, field.name) += @field(other, field.name);
        }
    }
};

pub const MutationTally = struct { accepted: u32 = 0, rejected: u32 = 0 };

const Frame = struct { value: Value, index: u32 };

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

fn child_count(value: Value) u32 {
    return switch (value) {
        .array => |items| @intCast(items.len),
        .map => |map| map.count,
        else => unreachable, // proof: only arrays and maps are pushed on the frame stack.
    };
}

fn child_at(value: Value, index: u32) Value {
    return switch (value) {
        .array => |items| items[index],
        .map => |map| map.items()[index].value,
        else => unreachable, // proof: only arrays and maps are pushed on the frame stack.
    };
}

/// Checks one node and counts it: valid UTF-8 text and keys, map and timestamp invariants.
fn visit(stats: *Stats, value: Value) !void {
    stats.nodes += 1;
    switch (value) {
        .null => stats.nulls += 1,
        .bool, .int => {},
        .uint => |number| {
            try expect(number > std.math.maxInt(i64));
            stats.uints += 1;
        },
        .float => stats.floats += 1,
        .bytes => stats.byte_strings += 1,
        .string => |text| try expect(std.unicode.utf8ValidateSlice(text)),
        .timestamp => |stamp| {
            stamp.check_invariants();
            stats.stamps += 1;
        },
        .array => stats.arrays += 1,
        .map => |map| {
            map.check_invariants();
            for (map.items()) |entry| try expect(std.unicode.utf8ValidateSlice(entry.key));
            stats.maps += 1;
        },
    }
}

/// Walks `root` on an explicit stack (no recursion) and checks every node.
pub fn check_tree(root: Value) !Stats {
    var frames: [core.value.nesting_max]Frame = undefined;
    var stats: Stats = .{};
    var depth: u32 = 0;

    assert(core.value.nesting_max >= 2);
    try visit(&stats, root);
    if (root == .array or root == .map) {
        frames[0] = .{ .value = root, .index = 0 };
        depth = 1;
    }
    for (0..walk_steps_max) |_| {
        if (depth == 0) {
            assert(stats.nodes >= 1);
            assert(stats.maps + stats.arrays <= stats.nodes);
            return stats;
        }
        const top = &frames[depth - 1];
        if (top.index == child_count(top.value)) {
            depth -= 1;
            continue;
        }
        const child = child_at(top.value, top.index);
        top.index += 1;
        try visit(&stats, child);
        if (child != .array and child != .map) continue;
        if (depth == core.value.nesting_max) return error.TooDeep;
        frames[depth] = .{ .value = child, .index = 0 };
        depth += 1;
    }
    return error.TooLarge;
}

/// What the generators can fail with: the arena, and a map that cannot take another entry.
pub const GenError = std.mem.Allocator.Error || error{ DuplicateKey, OutOfSpace };

pub const Mode = enum { generated, decoded };

fn random_run(arena: std.mem.Allocator, random: std.Random, fill: u8) ![]u8 {
    const len = run_lengths[random.uintLessThan(usize, run_lengths.len)];
    const run = try arena.alloc(u8, len);
    @memset(run, fill);
    return run;
}

fn random_text(arena: std.mem.Allocator, random: std.Random) ![]const u8 {
    if (random.uintLessThan(u8, 24) == 0) return random_run(arena, random, 'a');
    var text: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(u32, 6)) |_| {
        try text.appendSlice(arena, text_pieces[random.uintLessThan(usize, text_pieces.len)]);
    }
    return text.items;
}

fn random_bytes(arena: std.mem.Allocator, random: std.Random) ![]const u8 {
    if (random.uintLessThan(u8, 24) == 0) return random_run(arena, random, 0xab);
    const bytes = try arena.alloc(u8, random.uintLessThan(u32, 9));
    random.bytes(bytes);
    return bytes;
}

fn random_float(random: std.Random) f64 {
    const nan: f64 = @bitCast(nan_bits);
    switch (random.uintLessThan(u8, 4)) {
        0 => return float_edges[random.uintLessThan(usize, float_edges.len)],
        1 => {
            const narrow: f32 = @bitCast(random.int(u32));
            return if (std.math.isNan(narrow)) nan else narrow;
        },
        2 => return nan,
        else => {
            const wide: f64 = @bitCast(random.int(u64));
            return if (std.math.isNan(wide)) nan else wide;
        },
    }
}

fn random_int(random: std.Random) i64 {
    return switch (random.uintLessThan(u8, 3)) {
        0 => int_edges[random.uintLessThan(usize, int_edges.len)],
        1 => random.intRangeAtMost(i64, -40, 300),
        else => random.int(i64),
    };
}

fn random_width(random: std.Random, depth: u32) u32 {
    // Wide containers cross the fixed-size head boundary (15/16 and 23/24 entries).
    if (depth >= 2 and random.uintLessThan(u8, 16) == 0) {
        return random.intRangeAtMost(u32, 15, 17);
    }
    return random.uintLessThan(u32, width_gen_max + 1);
}

fn random_map(
    comptime codec: type,
    arena: std.mem.Allocator,
    random: std.Random,
    depth: u32,
) GenError!Value {
    const entries = try arena.alloc(Map.Entry, random_width(random, depth));
    var map = Map.init(entries);
    for (0..entries.len) |index| {
        // The `~index` suffix after the last `~` makes keys unique whatever the prefix.
        const prefix = try random_text(arena, random);
        const key = try std.fmt.allocPrint(arena, "{s}~{d}", .{ prefix, index });
        try map.put(key, try random_value(codec, arena, random, depth + 1));
    }
    map.check_invariants();
    return .{ .map = map };
}

fn random_array(
    comptime codec: type,
    arena: std.mem.Allocator,
    random: std.Random,
    depth: u32,
) GenError!Value {
    const items = try arena.alloc(Value, random_width(random, depth));
    for (items) |*item| item.* = try random_value(codec, arena, random, depth + 1);
    return .{ .array = items };
}

/// A normal-form value (ADR 0006 section 2): `uint` only above `maxInt(i64)`, one NaN.
fn random_value(
    comptime codec: type,
    arena: std.mem.Allocator,
    random: std.Random,
    depth: u32,
) GenError!Value {
    const container_kinds: u8 = if (depth < depth_gen_max) 2 else 0;
    switch (random.uintLessThan(u8, 9 + container_kinds)) {
        0 => return .null,
        1 => return .{ .bool = random.boolean() },
        2 => return .{ .int = random_int(random) },
        3 => {
            const above: u64 = @as(u64, std.math.maxInt(i64)) + 1;
            return .{ .uint = random.intRangeAtMost(u64, above, std.math.maxInt(u64)) };
        },
        4 => return .{ .float = random_float(random) },
        5 => return .{ .string = try random_text(arena, random) },
        6 => return .{ .bytes = try random_bytes(arena, random) },
        7 => return .{ .timestamp = codec.random_timestamp(random) },
        8 => return .{ .int = random.intRangeAtMost(i64, -10, 10) },
        9 => return random_array(codec, arena, random, depth),
        else => return random_map(codec, arena, random, depth),
    }
}

/// The tree of `seed`: a container seven times in eight, else a lone scalar.
pub fn random_root(comptime codec: type, arena: std.mem.Allocator, seed: u64) GenError!Value {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    if (random.uintLessThan(u8, 8) == 0) {
        const scalar = try random_value(codec, arena, random, depth_gen_max);
        assert(scalar != .map);
        assert(scalar != .array);
        return scalar;
    }
    if (random.boolean()) return random_map(codec, arena, random, 0);
    return random_array(codec, arena, random, 0);
}

/// Encodes `root` (and decodes it again unless it is unwritable), expecting the decoded
/// tree to be `eql` for a generated root and a second encode to be byte-identical.
/// Returns false when a decoded tree has no encoding (`Unrepresentable`).
pub fn round_trip(comptime codec: type, gpa: std.mem.Allocator, root: Value, mode: Mode) !bool {
    if (root == .map) assert(root.map.count <= root.map.entries.len);
    assert(@typeInfo(@TypeOf(codec.eql_roundtrip)) == .bool);
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();

    var diag = fresh_diag();
    codec.write(&first.writer, root, &diag) catch |err| {
        // proof: only a decoded tree may be unwritable; any other error fails the test.
        switch (err) {
            error.Unrepresentable => if (mode == .decoded) return false,
            else => {},
        }
        return err;
    };
    try expectEqual(sentinel_line, diag.line);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const reparsed = try codec.parse(&tree, first.written(), &diag);
    try expectEqual(sentinel_line, diag.line);
    if (mode == .generated and codec.eql_roundtrip) {
        try expect(try core.value.eql(root, reparsed));
    }
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();

    try codec.write(&second.writer, reparsed, &diag);
    try testing.expectEqualSlices(u8, first.written(), second.written());
    return true;
}

/// The oracle for arbitrary bytes. Never a panic.
pub fn check_input(comptime codec: type, gpa: std.mem.Allocator, input: []const u8) !Outcome {
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = fresh_diag();
    assert(diag.line == sentinel_line);
    assert(input.len < std.math.maxInt(u32));
    const root = codec.parse(&tree, input, &diag) catch {
        try expect(diag.line >= 1);
        try expect(diag.col >= 1);
        try expect(diag.line != sentinel_line);
        return .rejected;
    };
    try expectEqual(sentinel_line, diag.line);
    _ = try check_tree(root);
    try expect(tree.arena.queryCapacity() <= arena_per_byte_max * input.len + arena_slack);
    _ = try round_trip(codec, gpa, root, .decoded);
    return .accepted;
}

/// The encoding of the tree of `seed`, copied into `arena`.
pub fn encode_seed(
    comptime codec: type,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    seed: u64,
) ![]const u8 {
    const root = try random_root(codec, arena, seed);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var diag = fresh_diag();
    try codec.write(&out.writer, root, &diag);
    assert(out.written().len >= 1);
    assert(diag.line == sentinel_line);
    return arena.dupe(u8, out.written());
}

/// `source` with one seeded edit, built in `arena`.
pub fn mutate(arena: std.mem.Allocator, random: std.Random, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, source);
    assert(out.items.len == source.len);
    const pick = interesting_bytes[random.uintLessThan(usize, interesting_bytes.len)];
    if (out.items.len == 0) {
        try out.append(arena, pick);
        return out.items;
    }
    const at = random.uintLessThan(usize, out.items.len);
    switch (random.uintLessThan(u8, 6)) {
        0 => out.items[at] ^= @as(u8, 1) << random.int(u3),
        1 => out.items[at] = pick,
        2 => _ = out.orderedRemove(at),
        3 => try out.insert(arena, at, pick),
        4 => out.shrinkRetainingCapacity(at),
        else => {
            const end = at + random.uintLessThan(usize, out.items.len - at + 1);
            const chunk = try arena.dupe(u8, out.items[at..end]);
            try out.insertSlice(arena, random.uintLessThan(usize, out.items.len + 1), chunk);
        },
    }
    assert(out.items.len <= 2 * source.len + 1);
    return out.items;
}

/// Runs `seed_count` generated trees through `round_trip` and checks the generator
/// reached every kind; returns the totals.
pub fn run_seeds(comptime codec: type, gpa: std.mem.Allocator) !Stats {
    var totals: Stats = .{};
    for (0..seed_count) |seed| {
        errdefer std.log.err("property: failing seed {d}", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();

        const root = try random_root(codec, arena_state.allocator(), seed);
        totals.add(try check_tree(root));
        try expect(try round_trip(codec, gpa, root, .generated));
    }
    assert(totals.nodes >= seed_count);
    assert(totals.nodes >= totals.maps + totals.arrays);
    try expect(totals.maps > seed_count / 2);
    try expect(totals.arrays > seed_count / 2);
    try expect(totals.stamps > seed_count / 4);
    try expect(totals.uints > seed_count / 4);
    try expect(totals.nulls > seed_count / 4);
    try expect(totals.byte_strings > seed_count / 4);
    try expect(totals.floats > seed_count / 4);
    return totals;
}

/// Mutates each of `bases` `per_base` times from fixed seeds and judges every result.
pub fn run_mutations(
    comptime codec: type,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    bases: []const []const u8,
    per_base: u32,
) !MutationTally {
    var tally: MutationTally = .{};
    assert(bases.len >= 1);
    assert(per_base >= 1);
    for (bases, 0..) |base, base_index| {
        for (0..per_base) |round| {
            const seed = base_index * per_base + round;
            errdefer std.log.err("property: mutation seed {d} of base {d}", .{
                seed, base_index,
            });

            var prng = std.Random.DefaultPrng.init(seed);
            const mutated = try mutate(arena, prng.random(), base);
            switch (try check_input(codec, gpa, mutated)) {
                .accepted => tally.accepted += 1,
                .rejected => tally.rejected += 1,
            }
        }
    }
    return tally;
}

/// The body of a `std.testing.fuzz` target: up to `fuzz_bytes_max` bytes through `check_input`.
pub fn fuzz_input(comptime codec: type, smith: *testing.Smith) !void {
    var buffer: [fuzz_bytes_max]u8 = undefined;
    const len = smith.slice(&buffer);
    assert(len <= fuzz_bytes_max);
    assert(buffer.len == fuzz_bytes_max);
    _ = try check_input(codec, testing.allocator, buffer[0..len]);
}

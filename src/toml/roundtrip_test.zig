//! Round-trip property, seeded mutation and fuzz entry for TOML (plan 006 item 10, ADR 0005).
//! `REALM.md` makes round-trip a property, not a unit test, so three families run here:
//!
//! 1. 1,000 seeded `Value` trees the writer accepts (bounded depth and width, every scalar
//!    kind, arrays of maps, awkward keys) go write -> parse -> `core.eql`, and a second write is
//!    byte-identical. A failure reports its seed; the run is reproducible from `(seed, commit)`.
//! 2. Every valid file of the vendored toml-test corpus goes parse -> write -> parse, and each
//!    file is mutated `mutations_per_file` times from a fixed seed (bit flip, byte replace,
//!    delete, insert, truncate, chunk copy).
//! 3. `check_input` is the single oracle for both and for the `std.testing.fuzz` entry: text
//!    either parses to a tree whose invariants hold and that round-trips, or fails with a typed
//!    error carrying a position (line and column >= 1). Nothing panics.
//!
//! All memory comes from `std.testing.allocator`; the corpus is read through `std.testing.io`
//! from the repo root, as in `conformance_test.zig`.

const std = @import("std");
const core = @import("../core.zig");
const toml = @import("../toml.zig");
const conformance = @import("conformance_test.zig");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// What the generators can fail with: the arena, and a map that cannot take another entry.
const GenError = std.mem.Allocator.Error || error{ DuplicateKey, OutOfSpace };

const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

const seed_count: u32 = 1000;
const mutations_per_file: u32 = 8;
const sentinel_line: u32 = 777;
/// Generated containers nest at most this deep below the root; the writer allows 128.
const depth_gen_max: u32 = 4;
const width_gen_max: u32 = 4;
const walk_steps_max: u32 = 1 << 20;
const fuzz_bytes_max: u32 = 512;

const parse_options: toml.ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };
const write_options: toml.StringifyOptions = .{ .depth_max = 128 };

/// Unix seconds that keep the civil year within `0001..9999` even with a +-23:59 offset.
const seconds_min: i64 = -61_000_000_000;
const seconds_max: i64 = 250_000_000_000;
const seconds_per_day: i64 = 86_400;

const text_pieces = [_][]const u8{
    "a",                "Z", "-", "_",  " ",  ".",    "\"",   "'",    "\\",       "#",
    "=",                "[", "]", "\n", "\t", "\x00", "\x01", "\x7f", "\xC3\xA9", "\xE2\x82\xAC",
    "\xF0\x9F\x98\x80",
};

const special_floats = [_]f64{
    0.0,
    -0.0,
    1.0,
    -1.5e300,
    5e-324,
    std.math.inf(f64),
    -std.math.inf(f64),
};

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

fn random_text(arena: std.mem.Allocator, random: std.Random) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(u32, 6)) |_| {
        try text.appendSlice(arena, text_pieces[random.uintLessThan(usize, text_pieces.len)]);
    }
    return text.items;
}

fn random_float(random: std.Random) f64 {
    if (random.uintLessThan(u8, 4) == 0) {
        return special_floats[random.uintLessThan(usize, special_floats.len)];
    }
    // A random bit pattern is non-finite one time in 2048, so 64 tries cannot all miss.
    for (0..64) |_| {
        const candidate: f64 = @bitCast(random.int(u64));
        if (std.math.isFinite(candidate)) return candidate;
    }
    return 0.5;
}

/// A timestamp of a random kind that satisfies `check_invariants` and has a four-digit year.
fn random_timestamp(random: std.Random) Timestamp {
    const fraction: u32 = if (random.boolean()) 0 else random.uintLessThan(u32, 1_000_000_000);
    const stamp: Timestamp = switch (random.enumValue(Timestamp.Kind)) {
        .instant => .{
            .kind = .instant,
            .seconds = random.intRangeAtMost(i64, seconds_min, seconds_max),
            .nanoseconds = fraction,
            .offset_minutes = random.intRangeAtMost(i16, -1439, 1439),
        },
        .local_datetime => .{
            .kind = .local_datetime,
            .seconds = random.intRangeAtMost(i64, seconds_min, seconds_max),
            .nanoseconds = fraction,
            .offset_minutes = null,
        },
        .local_date => .{
            .kind = .local_date,
            .seconds = random.intRangeAtMost(i64, 0, 2_900_000) * seconds_per_day,
            .nanoseconds = 0,
            .offset_minutes = null,
        },
        .local_time => .{
            .kind = .local_time,
            .seconds = random.intRangeAtMost(i64, 0, seconds_per_day - 1),
            .nanoseconds = fraction,
            .offset_minutes = null,
        },
    };
    stamp.check_invariants();
    return stamp;
}

fn random_map(arena: std.mem.Allocator, random: std.Random, depth: u32) GenError!Value {
    const entries = try arena.alloc(Map.Entry, random.uintLessThan(u32, width_gen_max + 1));
    var map = Map.init(entries);
    for (0..entries.len) |index| {
        // The `~index` suffix after the last `~` makes keys unique whatever the prefix holds.
        const prefix = try random_text(arena, random);
        const key = try std.fmt.allocPrint(arena, "{s}~{d}", .{ prefix, index });
        try map.put(key, try random_value(arena, random, depth + 1));
    }
    map.check_invariants();
    return .{ .map = map };
}

/// An array whose members are all maps one time in three (array-of-tables territory).
fn random_array(arena: std.mem.Allocator, random: std.Random, depth: u32) GenError!Value {
    const items = try arena.alloc(Value, random.uintLessThan(u32, width_gen_max));
    const only_maps = random.uintLessThan(u8, 3) == 0;
    for (items) |*item| {
        item.* = if (only_maps)
            try random_map(arena, random, depth + 1)
        else
            try random_value(arena, random, depth + 1);
    }
    return .{ .array = items };
}

/// A random value the writer accepts: no null, bytes or unsigned integers (a parse never makes
/// them), finite or infinite floats, valid UTF-8 strings, unique keys.
fn random_value(arena: std.mem.Allocator, random: std.Random, depth: u32) GenError!Value {
    const container_kinds: u8 = if (depth < depth_gen_max) 2 else 0;
    switch (random.uintLessThan(u8, 6 + container_kinds)) {
        0 => return .{ .bool = random.boolean() },
        1 => return .{ .int = random.int(i64) },
        2 => return .{ .int = random.intRangeAtMost(i64, -10, 10) },
        3 => return .{ .float = random_float(random) },
        4 => return .{ .string = try random_text(arena, random) },
        5 => return .{ .timestamp = random_timestamp(random) },
        6 => return random_array(arena, random, depth),
        else => return random_map(arena, random, depth),
    }
}

/// What a tree holds, for coverage assertions.
const Stats = struct { nodes: u32 = 0, maps: u32 = 0, arrays: u32 = 0, stamps: u32 = 0 };

/// What the written text looked like.
const Shape = struct { has_table: bool, has_table_array: bool };

/// Checks one node: only kinds a TOML parse can produce, valid UTF-8, map and timestamp
/// invariants. Programmer-visible violations fail the test.
fn visit(stats: *Stats, value: Value) !void {
    stats.nodes += 1;
    switch (value) {
        .null, .uint, .bytes => return error.UnexpectedKind,
        .bool, .int, .float => {},
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

const Frame = struct { value: Value, index: u32 };

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

/// Walks `root` on an explicit stack (no recursion) and checks every node.
fn check_tree(root: Value) !Stats {
    var frames: [core.value.nesting_max]Frame = undefined;
    var stats: Stats = .{};
    var depth: u32 = 0;

    try visit(&stats, root);
    if (root == .array or root == .map) {
        frames[0] = .{ .value = root, .index = 0 };
        depth = 1;
    }
    for (0..walk_steps_max) |_| {
        if (depth == 0) return stats;
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

/// Writes the map `root`, parses the text back and expects an `eql` tree, then expects a second
/// write of the reparse to be byte-identical to the first.
fn round_trip(gpa: std.mem.Allocator, root: Value) !Shape {
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();

    var diag = fresh_diag();
    try toml.write_value(&first.writer, root, write_options, &diag);
    try expectEqual(sentinel_line, diag.line);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const reparsed = try toml.parse_value(gpa, &tree, first.written(), parse_options, &diag);
    try expectEqual(sentinel_line, diag.line);
    try expect(try core.value.eql(root, reparsed));
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();

    try toml.write_value(&second.writer, reparsed, write_options, &diag);
    try testing.expectEqualStrings(first.written(), second.written());
    return .{
        .has_table = std.mem.find(u8, first.written(), "\n[") != null or
            std.mem.startsWith(u8, first.written(), "["),
        .has_table_array = std.mem.find(u8, first.written(), "[[") != null,
    };
}

const Outcome = enum { accepted, rejected };

/// The oracle for arbitrary bytes: a parse that succeeds yields a tree that passes the
/// invariants and round-trips; one that fails is typed and positioned. Never a panic.
fn check_input(gpa: std.mem.Allocator, input: []const u8) !Outcome {
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = fresh_diag();
    const root = toml.parse_value(gpa, &tree, input, parse_options, &diag) catch {
        try expect(diag.line >= 1);
        try expect(diag.col >= 1);
        try expect(diag.line != sentinel_line);
        return .rejected;
    };
    try expectEqual(sentinel_line, diag.line);
    try expect(root == .map);
    _ = try check_tree(root);
    _ = try round_trip(gpa, root);
    return .accepted;
}

test "roundtrip: 1,000 seeded trees survive write, parse and a second write" {
    var totals: Stats = .{};
    var tables: u32 = 0;
    var table_arrays: u32 = 0;
    for (0..seed_count) |seed| {
        errdefer std.log.err("roundtrip: failing seed {d}", .{seed});

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();

        var prng = std.Random.DefaultPrng.init(seed);
        const root = try random_map(arena_state.allocator(), prng.random(), 0);
        const stats = try check_tree(root);
        totals.nodes += stats.nodes;
        totals.maps += stats.maps;
        totals.arrays += stats.arrays;
        totals.stamps += stats.stamps;
        const shape = try round_trip(testing.allocator, root);
        tables += @intFromBool(shape.has_table);
        table_arrays += @intFromBool(shape.has_table_array);
    }
    std.log.warn("roundtrip: {d} seeds, {d} nodes, {d} maps, {d} arrays, {d} timestamps, " ++
        "{d} with tables, {d} with table arrays", .{
        seed_count, totals.nodes, totals.maps, totals.arrays, totals.stamps,
        tables,     table_arrays,
    });
    // The generator must reach every structure the writer has a special form for.
    try expect(totals.maps > seed_count);
    try expect(totals.arrays > seed_count / 4);
    try expect(totals.stamps > seed_count / 4);
    try expect(tables > seed_count / 10);
    try expect(table_arrays > seed_count / 20);
}

/// The paths of the `valid/` cases in `list`, borrowed from `list`.
fn valid_paths(arena: std.mem.Allocator, list: []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".toml")) continue;
        if (std.mem.startsWith(u8, path, "valid/")) try paths.append(arena, path);
    }
    return paths.items;
}

test "roundtrip: every valid corpus file survives parse, write, parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const list = try conformance.read_case(testing.allocator, "files-toml-1.0.0");
    defer testing.allocator.free(list);

    const paths = try valid_paths(arena_state.allocator(), list);
    try expectEqual(conformance.valid_count, @as(u32, @intCast(paths.len)));
    for (paths) |path| {
        errdefer std.log.err("roundtrip: corpus file '{s}'", .{path});

        const input = try conformance.read_case(testing.allocator, path);
        defer testing.allocator.free(input);

        try expectEqual(Outcome.accepted, try check_input(testing.allocator, input));
    }
}

const structural = "\"'[]{}=.,#\\\n\r \t0aZ-:+";

/// `source` with one seeded edit, built in `arena`. An empty source gains one structural byte.
fn mutate(arena: std.mem.Allocator, random: std.Random, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, source);
    if (out.items.len == 0) {
        try out.append(arena, structural[random.uintLessThan(usize, structural.len)]);
        return out.items;
    }
    const at = random.uintLessThan(usize, out.items.len);
    switch (random.uintLessThan(u8, 6)) {
        0 => out.items[at] ^= @as(u8, 1) << random.int(u3),
        1 => out.items[at] = structural[random.uintLessThan(usize, structural.len)],
        2 => _ = out.orderedRemove(at),
        3 => try out.insert(arena, at, structural[random.uintLessThan(usize, structural.len)]),
        4 => out.shrinkRetainingCapacity(at),
        else => {
            const end = at + random.uintLessThan(usize, out.items.len - at + 1);
            const chunk = try arena.dupe(u8, out.items[at..end]);
            try out.insertSlice(arena, random.uintLessThan(usize, out.items.len + 1), chunk);
        },
    }
    return out.items;
}

test "roundtrip: seeded mutations of the valid corpus never panic and stay typed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const list = try conformance.read_case(testing.allocator, "files-toml-1.0.0");
    defer testing.allocator.free(list);

    const paths = try valid_paths(arena_state.allocator(), list);
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (paths, 0..) |path, file_index| {
        const input = try conformance.read_case(testing.allocator, path);
        defer testing.allocator.free(input);

        for (0..mutations_per_file) |round| {
            const seed = file_index * mutations_per_file + round;
            errdefer std.log.err("roundtrip: mutation seed {d} of '{s}'", .{ seed, path });

            var prng = std.Random.DefaultPrng.init(seed);
            const mutated = try mutate(arena_state.allocator(), prng.random(), input);
            switch (try check_input(testing.allocator, mutated)) {
                .accepted => accepted += 1,
                .rejected => rejected += 1,
            }
        }
    }
    std.log.warn("roundtrip: {d} mutations: {d} accepted, {d} rejected", .{
        accepted + rejected, accepted, rejected,
    });
    try expectEqual(conformance.valid_count * mutations_per_file, accepted + rejected);
    try expect(accepted > 0);
    try expect(rejected > accepted / 4);
}

const fuzz_corpus = [_][]const u8{
    "",
    "a = 1\n",
    "[a.b]\nc = [1, 2, {d = \"x\"}]\n",
    "[[t]]\nk = 1987-07-05T17:45:56.6Z\n[[t]]\nk = 07:32:00\n",
    "\"q.k\" = 'lit'\nf = [inf, -0.0, nan]\n",
    "a = \"\"\"\nmulti\\\n   line\"\"\"\n",
};

fn fuzz_one(_: void, smith: *testing.Smith) !void {
    var buffer: [fuzz_bytes_max]u8 = undefined;
    const len = smith.slice(&buffer);
    _ = try check_input(testing.allocator, buffer[0..len]);
}

test "roundtrip: a fuzz target never panics, and every accepted tree round-trips" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

test "roundtrip: the seed corpus alone is accepted or rejected as written" {
    // `.corpus` seeds run in `zig build test`; pin their verdicts so a parser change is seen.
    const expected = [_]Outcome{ .accepted, .accepted, .accepted, .accepted, .accepted, .accepted };
    comptime std.debug.assert(expected.len == fuzz_corpus.len);
    for (fuzz_corpus, expected) |input, want| {
        try expectEqual(want, try check_input(testing.allocator, input));
    }
}

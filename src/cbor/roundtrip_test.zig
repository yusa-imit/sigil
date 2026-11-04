//! Round-trip property, seeded mutation and fuzz entry for CBOR (plan 007 item 9, ADR 0006
//! sections 2, 7 and 10). The families live in `core/binary_property.zig`; this file supplies two
//! codecs (preferred and deterministic serialization, whose sorted maps break `eql` but not
//! byte stability), the timestamps the format can carry, and the base inputs: the RFC 8949
//! Appendix A items of `tests/cbor/appendix_a.json` plus encodings of generated trees.

const std = @import("std");
const core = @import("../core.zig");
const cbor = @import("../cbor.zig");
const binary_property = @import("../core/binary_property.zig");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_path = "tests/cbor/appendix_a.json";
const suite_bytes_max: usize = 1 << 16;
const item_bytes_max: u32 = 256;
const item_count: u32 = 82;
const generated_base_count: u32 = 200;
const mutations_per_base: u32 = 8;

/// Unix seconds that keep the civil year within `0001..9999` even with a +-23:59 offset.
const seconds_min: i64 = -61_000_000_000;
const seconds_max: i64 = 250_000_000_000;
/// Fractions a binary64 of `seconds + fraction` holds exactly, so tag 1 can carry them.
const exact_fractions = [_]u32{ 0, 250_000_000, 500_000_000, 750_000_000 };

const parse_options: cbor.ParseOptions = .{
    .depth_max = core.value.nesting_max,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};

fn CodecType(comptime deterministic: bool) type {
    return struct {
        pub const eql_roundtrip = !deterministic;

        pub fn parse(
            tree: *ValueTree,
            input: []const u8,
            diag: *Diagnostics,
        ) cbor.ParseValueError!Value {
            return cbor.parse_value(tree, input, parse_options, diag);
        }

        pub fn write(
            w: *std.Io.Writer,
            value: Value,
            diag: *Diagnostics,
        ) cbor.WriteValueError!void {
            const options: cbor.StringifyOptions = .{
                .depth_max = core.value.nesting_max,
                .deterministic = deterministic,
            };
            return cbor.write_value(w, value, options, diag);
        }

        /// Tag 0 (text, offset kept, any nanoseconds) or tag 1 (integer or exact binary64).
        pub fn random_timestamp(random: std.Random) Timestamp {
            const stamp: Timestamp = if (random.boolean()) .{
                .kind = .instant,
                .seconds = random.intRangeAtMost(i64, seconds_min, seconds_max),
                .nanoseconds = random.uintLessThan(u32, 1_000_000_000),
                .offset_minutes = random.intRangeAtMost(i16, -1439, 1439),
            } else .{
                .kind = .instant,
                .seconds = random.intRangeAtMost(i64, -(1 << 40), 1 << 40),
                .nanoseconds = exact_fractions[random.uintLessThan(usize, exact_fractions.len)],
                .offset_minutes = null,
            };
            stamp.check_invariants();
            return stamp;
        }
    };
}

const Preferred = CodecType(false);
const Deterministic = CodecType(true);

test "roundtrip: 1,000 seeded trees survive encode, decode and a second encode" {
    const totals = try binary_property.run_seeds(Preferred, testing.allocator);
    std.log.warn("cbor roundtrip: {d} seeds, {d} nodes, {d} maps, {d} arrays, " ++
        "{d} timestamps, {d} uints", .{
        binary_property.seed_count, totals.nodes,  totals.maps,
        totals.arrays,              totals.stamps, totals.uints,
    });
}

test "roundtrip: 1,000 seeded trees re-encode byte for byte under deterministic mode" {
    const totals = try binary_property.run_seeds(Deterministic, testing.allocator);
    try expect(totals.maps > binary_property.seed_count / 2);
}

/// Every hex item of the vendored Appendix A file, borrowed from `arena`.
fn suite_items(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    var bases: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |item| {
        const buffer = try arena.alloc(u8, item_bytes_max);
        try bases.append(arena, try std.fmt.hexToBytes(buffer, item.object.get("hex").?.string));
    }
    return bases.items;
}

fn run_mutation_family(comptime codec: type) !binary_property.MutationTally {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        suite_path,
        arena,
        .limited(suite_bytes_max),
    );
    var bases: std.ArrayList([]const u8) = .empty;
    try bases.appendSlice(arena, try suite_items(arena, text));
    try expectEqual(item_count, @as(u32, @intCast(bases.items.len)));
    for (0..generated_base_count) |seed| {
        const encoded = try binary_property.encode_seed(codec, testing.allocator, arena, seed);
        try bases.append(arena, encoded);
    }
    return binary_property.run_mutations(
        codec,
        testing.allocator,
        arena,
        bases.items,
        mutations_per_base,
    );
}

test "roundtrip: seeded mutations of the vectors and of generated trees stay typed" {
    const tally = try run_mutation_family(Preferred);
    std.log.warn("cbor roundtrip: {d} mutations: {d} accepted, {d} rejected", .{
        tally.accepted + tally.rejected, tally.accepted, tally.rejected,
    });
    const total = (item_count + generated_base_count) * mutations_per_base;
    try expectEqual(total, tally.accepted + tally.rejected);
    try expect(tally.accepted > 0);
    try expect(tally.rejected > tally.accepted / 4);
}

const fuzz_corpus = [_][]const u8{
    "\xf6",
    "\xa1\x61a\x01",
    "\xc1\x1a\x00\x00\x00\x01",
    "\x9f\x01\x02\xff",
    "\xf7",
    "\x82\x01",
};

fn fuzz_one(_: void, smith: *testing.Smith) !void {
    try binary_property.fuzz_input(Preferred, smith);
}

test "roundtrip: a fuzz target never panics, and every accepted tree is a fixed point" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

test "roundtrip: the seed corpus alone is accepted or rejected as written" {
    // `.corpus` seeds run in `zig build test`; pin their verdicts so a decoder change is seen.
    const A = binary_property.Outcome.accepted;
    const R = binary_property.Outcome.rejected;
    const expected = [_]binary_property.Outcome{ A, A, A, A, R, R };
    comptime std.debug.assert(expected.len == fuzz_corpus.len);
    for (fuzz_corpus, expected) |input, want| {
        try expectEqual(want, try binary_property.check_input(Preferred, testing.allocator, input));
    }
}

test "roundtrip: .uint = 5 encodes to 05 and decodes to int 5; deterministic sorts keys" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var diag = Diagnostics.init(1, 1, "untouched", null);
    try Preferred.write(&out.writer, .{ .uint = 5 }, &diag);
    try testing.expectEqualSlices(u8, "\x05", out.written());

    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const got = try Preferred.parse(&tree, out.written(), &diag);
    try expectEqual(@as(i64, 5), got.int);

    var entries: [2]core.Map.Entry = undefined;
    var map = core.Map.init(&entries);
    try map.put("bb", .null);
    try map.put("a", .null);
    var sorted: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sorted.deinit();

    try Deterministic.write(&sorted.writer, .{ .map = map }, &diag);
    try testing.expectEqualSlices(u8, "\xa2\x61a\xf6\x62bb\xf6", sorted.written());
}

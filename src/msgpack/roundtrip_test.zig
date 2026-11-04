//! Round-trip property, seeded mutation and fuzz entry for MessagePack (plan 007 item 9,
//! ADR 0006 sections 2 and 10). The families live in `core/binary_property.zig`; this file
//! supplies the codec (options, timestamps the format can carry) and the base inputs: the
//! encodings of `tests/msgpack-test-suite/` plus encodings of generated trees. Counts are
//! asserted so a generator that stops reaching a kind fails.

const std = @import("std");
const core = @import("../core.zig");
const msgpack = @import("../msgpack.zig");
const binary_property = @import("../core/binary_property.zig");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_path = "tests/msgpack-test-suite/msgpack-test-suite.json";
const suite_bytes_max: usize = 1 << 16;
const encoding_bytes_max: u32 = 512;
const encoding_count: u32 = 233;
const generated_base_count: u32 = 200;
const mutations_per_base: u32 = 8;

const parse_options: msgpack.ParseOptions = .{
    .depth_max = core.value.nesting_max,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const write_options: msgpack.StringifyOptions = .{ .depth_max = core.value.nesting_max };

const Codec = struct {
    pub const eql_roundtrip = true;

    pub fn parse(
        tree: *ValueTree,
        input: []const u8,
        diag: *Diagnostics,
    ) msgpack.ParseValueError!Value {
        return msgpack.parse_value(tree, input, parse_options, diag);
    }

    pub fn write(w: *std.Io.Writer, value: Value, diag: *Diagnostics) msgpack.WriteValueError!void {
        return msgpack.write_value(w, value, write_options, diag);
    }

    /// An instant without offset in each of the three ext forms (ext 4, 8 and 12).
    pub fn random_timestamp(random: std.Random) Timestamp {
        const form = random.uintLessThan(u8, 3);
        const stamp: Timestamp = .{
            .kind = .instant,
            .seconds = switch (form) {
                0 => random.int(u32),
                1 => random.intRangeAtMost(i64, 0, (1 << 34) - 1),
                else => random.int(i64),
            },
            .nanoseconds = if (form == 0) 0 else random.uintLessThan(u32, 1_000_000_000),
            .offset_minutes = null,
        };
        stamp.check_invariants();
        return stamp;
    }
};

test "roundtrip: 1,000 seeded trees survive encode, decode and a second encode" {
    const totals = try binary_property.run_seeds(Codec, testing.allocator);
    std.log.warn("msgpack roundtrip: {d} seeds, {d} nodes, {d} maps, {d} arrays, " ++
        "{d} timestamps, {d} uints", .{
        binary_property.seed_count, totals.nodes,  totals.maps,
        totals.arrays,              totals.stamps, totals.uints,
    });
}

/// Every listed encoding of the vendored suite, borrowed from `arena`.
fn suite_encodings(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    var bases: std.ArrayList([]const u8) = .empty;
    for (parsed.object.values()) |file| {
        for (file.array.items) |case| {
            for (case.object.get("msgpack").?.array.items) |hex| {
                const buffer = try arena.alloc(u8, encoding_bytes_max);
                var len: usize = 0;
                var parts = std.mem.splitScalar(u8, hex.string, '-');
                while (parts.next()) |part| {
                    buffer[len] = try std.fmt.parseInt(u8, part, 16);
                    len += 1;
                }
                try bases.append(arena, buffer[0..len]);
            }
        }
    }
    return bases.items;
}

test "roundtrip: seeded mutations of the vectors and of generated trees stay typed" {
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
    try bases.appendSlice(arena, try suite_encodings(arena, text));
    try expectEqual(encoding_count, @as(u32, @intCast(bases.items.len)));
    for (0..generated_base_count) |seed| {
        const encoded = try binary_property.encode_seed(Codec, testing.allocator, arena, seed);
        try bases.append(arena, encoded);
    }
    const tally = try binary_property.run_mutations(
        Codec,
        testing.allocator,
        arena,
        bases.items,
        mutations_per_base,
    );
    std.log.warn("msgpack roundtrip: {d} mutations: {d} accepted, {d} rejected", .{
        tally.accepted + tally.rejected, tally.accepted, tally.rejected,
    });
    const total = (encoding_count + generated_base_count) * mutations_per_base;
    try expectEqual(total, tally.accepted + tally.rejected);
    try expect(tally.accepted > 0);
    try expect(tally.rejected > tally.accepted / 4);
}

const fuzz_corpus = [_][]const u8{
    "\xc0",
    "\x81\xa1a\x01",
    "\x92\xd6\xff\x00\x00\x00\x01\xc4\x02\x00\xff",
    "\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00",
    "\xc1",
    "\x92\x01",
};

fn fuzz_one(_: void, smith: *testing.Smith) !void {
    try binary_property.fuzz_input(Codec, smith);
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
        try expectEqual(want, try binary_property.check_input(Codec, testing.allocator, input));
    }
}

test "roundtrip: a uint above maxInt(i64) is the normal form and .uint = 5 decodes to int 5" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var diag = Diagnostics.init(1, 1, "untouched", null);
    try Codec.write(&out.writer, .{ .uint = 5 }, &diag);
    try testing.expectEqualSlices(u8, "\x05", out.written());

    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const got = try Codec.parse(&tree, out.written(), &diag);
    try expectEqual(@as(i64, 5), got.int);
}

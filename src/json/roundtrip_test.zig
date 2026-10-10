//! Round-trip property for `json/writer.zig` and `json/dom.zig` (plan 004 item 6): for every
//! canonical JSON-representable `Value`, `write` then `dom.parse` yields a `Value` that is
//! `core.eql` to the original, in both layouts and with sorted keys. `REALM.md` makes this a
//! property, not a unit test: 1,000 seeded values plus the number edges, reproducible from the
//! seed that `std.log.err` reports on failure. All memory comes from `std.testing.allocator`.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("dom.zig");
const writer = @import("writer.zig");
const writer_test = @import("writer_test.zig");
const expect = std.testing.expect;

const Value = core.Value;
const Map = core.Map;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const StringifyOptions = writer.StringifyOptions;

const seed_count: u32 = 1000;
const parse_options: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .reject };

const layouts = [_]StringifyOptions{
    .{ .layout = .minified, .sort_keys = false, .escape = .minimal, .depth_max = 128 },
    .{ .layout = .minified, .sort_keys = true, .escape = .minimal, .depth_max = 128 },
    .{
        .layout = .{ .pretty = .{ .indent_spaces = 2 } },
        .sort_keys = false,
        .escape = .minimal,
        .depth_max = 128,
    },
    .{
        .layout = .{ .pretty = .{ .indent_spaces = writer.indent_spaces_max } },
        .sort_keys = true,
        .escape = .minimal,
        .depth_max = 128,
    },
};

/// Writes `value` with `options`, parses the text back and reports whether the two are equal.
/// Sorted output reorders map entries, so `sort_keys` compares against the sorted original.
fn round_trips(gpa: std.mem.Allocator, value: Value, options: StringifyOptions) !bool {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var write_diag = Diagnostics.init(0, 0, "", null);
    try writer.write(&aw.writer, value, options, &write_diag);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var parse_diag = Diagnostics.init(0, 0, "", null);
    const parsed = try dom.parse(&tree, aw.written(), parse_options, &parse_diag);
    if (options.sort_keys) return try eql_unordered(value, parsed);
    return try core.value.eql(value, parsed);
}

/// Equality that ignores map entry order (keys are unique by construction), so a sorted write
/// can be checked against the generator's insertion order.
fn eql_unordered(a: Value, b: Value) error{TooDeep}!bool {
    return eql_unordered_at(a, b, 0);
}

fn eql_unordered_at(a: Value, b: Value, depth: u32) error{TooDeep}!bool {
    if (depth >= core.value.nesting_max) return error.TooDeep;
    switch (a) {
        .array => |left| {
            if (b != .array or b.array.len != left.len) return false;
            for (left, b.array) |l, r| {
                if (!try eql_unordered_at(l, r, depth + 1)) return false;
            }
            return true;
        },
        .map => |left| {
            if (b != .map or b.map.items().len != left.items().len) return false;
            for (left.items()) |entry| {
                const other = b.map.get(entry.key) orelse return false;
                if (!try eql_unordered_at(entry.value, other.*, depth + 1)) return false;
            }
            return true;
        },
        else => return core.value.eql(a, b),
    }
}

test "roundtrip: 1,000 seeded values survive every layout" {
    for (0..seed_count) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();

        var prng = std.Random.DefaultPrng.init(seed);
        const value = try writer_test.random_value(arena_state.allocator(), prng.random(), 0);
        errdefer std.log.err("json round trip failed, seed {d}", .{seed});

        for (layouts) |options| {
            try expect(try round_trips(std.testing.allocator, value, options));
        }
    }
}

test "roundtrip: number edges keep their kind and bits" {
    const edges = [_]Value{
        .{ .int = std.math.minInt(i64) },
        .{ .int = -1 },
        .{ .int = 0 },
        .{ .int = std.math.maxInt(i64) },
        .{ .uint = writer_test.uint_min },
        .{ .uint = std.math.maxInt(u64) },
        .{ .float = -0.0 },
        .{ .float = 0.0 },
        .{ .float = 0.1 },
        .{ .float = 1.0 },
        .{ .float = 5e-324 },
        .{ .float = std.math.floatMax(f64) },
        .{ .float = -std.math.floatMax(f64) },
        .{ .float = 1e300 },
    };
    const root: Value = .{ .array = &edges };
    for (layouts) |options| {
        try expect(try round_trips(std.testing.allocator, root, options));
    }
}

test "roundtrip: the checker rejects a value that does not survive" {
    // Negative space: `eql_unordered` must tell a changed number kind and a missing key apart,
    // or the property above would pass vacuously.
    try expect(!try eql_unordered(.{ .int = 1 }, .{ .uint = 1 }));
    try expect(!try eql_unordered(.{ .float = 0.0 }, .{ .float = -0.0 }));
    var left_entries: [1]Map.Entry = undefined;
    var left = Map.init(&left_entries);
    try left.put("a", .null);
    var right_entries: [1]Map.Entry = undefined;
    var right = Map.init(&right_entries);
    try right.put("b", .null);
    try expect(!try eql_unordered(.{ .map = left }, .{ .map = right }));
}

test {
    std.testing.refAllDecls(@This());
}

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
/// Sorted output reorders map entries, so `sort_keys` also demands ascending keys.
fn round_trips(
    gpa: std.mem.Allocator,
    value: Value,
    options: StringifyOptions,
) !bool {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var write_diag = Diagnostics.init(0, 0, "", null);
    try writer.write(&aw.writer, value, options, &write_diag);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var parse_diag = Diagnostics.init(0, 0, "", null);
    const parsed = try dom.parse(&tree, aw.written(), parse_options, &parse_diag);
    if (options.sort_keys) return try eql_sorted(value, parsed);
    return try core.value.eql(value, parsed);
}

/// Compares `original` with the `sort_keys` parse of it: equal contents, and every map in
/// `parsed` has strictly ascending keys (unique, so ties cannot occur). An explicit frame stack
/// bounded by `nesting_max` replaces recursion; the walk is depth-first in `parsed` order.
fn eql_sorted(original: Value, parsed: Value) error{ TooDeep, NotSorted }!bool {
    const Frame = struct { a: Value, b: Value, index: u32 };
    var frames: [core.value.nesting_max]Frame = undefined;
    var depth: u32 = 0;

    if (!try shallow_match(original, parsed)) return false;
    if (parsed != .array and parsed != .map) return true;
    frames[0] = .{ .a = original, .b = parsed, .index = 0 };
    depth = 1;
    for (0..walk_steps_max) |_| {
        if (depth == 0) return true;
        const frame = &frames[depth - 1];
        const count: u32 = switch (frame.b) {
            .array => |items| @intCast(items.len),
            .map => |map| @intCast(map.items().len),
            else => unreachable, // proof: only arrays and maps are pushed.
        };
        if (frame.index == count) {
            depth -= 1;
            continue;
        }
        const index = frame.index;
        frame.index += 1;
        const pair = try child_pair(frame.a, frame.b, index) orelse return false;
        if (!try shallow_match(pair[0], pair[1])) return false;
        if (pair[1] != .array and pair[1] != .map) continue;
        if (depth == core.value.nesting_max) return error.TooDeep;
        frames[depth] = .{ .a = pair[0], .b = pair[1], .index = 0 };
        depth += 1;
    }
    return error.TooDeep;
}

/// Upper bound on frame steps: generous for the generator's small values.
const walk_steps_max: u32 = 1 << 16;

/// The `index`th child of `parsed` and its counterpart in `original`; null when the counterpart
/// is missing. Errors when a map's keys are not strictly ascending.
fn child_pair(original: Value, parsed: Value, index: u32) error{NotSorted}!?[2]Value {
    switch (parsed) {
        .array => |items| return .{ original.array[index], items[index] },
        .map => |map| {
            const entries = map.items();
            if (index > 0) {
                const order = std.mem.order(u8, entries[index - 1].key, entries[index].key);
                if (order != .lt) return error.NotSorted;
            }
            const other = original.map.get(entries[index].key) orelse return null;
            return .{ other.*, entries[index].value };
        },
        else => unreachable, // proof: only arrays and maps are pushed.
    }
}

/// Kinds and sizes agree for containers; scalars compare with `core.value.eql`.
fn shallow_match(a: Value, b: Value) error{TooDeep}!bool {
    switch (a) {
        .array => |left| return b == .array and b.array.len == left.len,
        .map => |left| return b == .map and b.map.items().len == left.items().len,
        else => return core.value.eql(a, b),
    }
}

test "roundtrip: 1,000 seeded values survive every layout" {
    var multi_key_maps: u32 = 0;
    var filled_arrays: u32 = 0;
    for (0..seed_count) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();

        var prng = std.Random.DefaultPrng.init(seed);
        const value = try writer_test.random_value(arena_state.allocator(), prng.random(), 0);
        switch (value) {
            .map => |map| multi_key_maps += @intFromBool(map.items().len >= 2),
            .array => |items| filled_arrays += @intFromBool(items.len >= 1),
            else => {},
        }

        for (layouts, 0..) |options, layout_index| {
            errdefer std.log.err("json round trip failed, seed {d} layout {d}", .{
                seed,
                layout_index,
            });
            try expect(try round_trips(std.testing.allocator, value, options));
        }
    }
    // The generator must reach containers, or the property above would pass vacuously.
    try expect(multi_key_maps > 0);
    try expect(filled_arrays > 0);
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
    // Negative space: `eql_sorted` must tell a changed number kind, a missing key and an
    // unsorted map apart, or the property above would pass vacuously.
    try expect(!try eql_sorted(.{ .int = 1 }, .{ .uint = 1 }));
    try expect(!try eql_sorted(.{ .float = 0.0 }, .{ .float = -0.0 }));
    var left_entries: [1]Map.Entry = undefined;
    var left = Map.init(&left_entries);
    try left.put("a", .null);
    var right_entries: [1]Map.Entry = undefined;
    var right = Map.init(&right_entries);
    try right.put("b", .null);
    try expect(!try eql_sorted(.{ .map = left }, .{ .map = right }));

    var original_entries: [2]Map.Entry = undefined;
    var original = Map.init(&original_entries);
    try original.put("b", .null);
    try original.put("a", .null);
    // Insertion order b, a is the unsorted form `sort_keys` must never produce.
    try std.testing.expectError(
        error.NotSorted,
        eql_sorted(.{ .map = original }, .{ .map = original }),
    );
}

test {
    std.testing.refAllDecls(@This());
}

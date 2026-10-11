//! Tests for `scanner.locate` (plan 004 item 8, ADR 0003 section 8): the offset of the value a
//! `reflect.Path` names, found by walking a `Scanner` over the source. `.index` counts whole
//! elements, `.none` descends nowhere, `.key` matches the LAST occurrence by decoded bytes, and
//! a path that leaves the document stops at the deepest segment found, so the function is total.
//! The offset is the first byte of the value, never of its key. A seeded model records the
//! offset of every value while it writes a document and checks `locate` against the record.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("../reflect/context.zig");
const scanner = @import("scanner.zig");
const raw_eql_test = @import("raw_eql_test.zig");
const assert = std.debug.assert;
const testing = std.testing;

const Path = context_mod.Path;
const Segment = context_mod.Segment;
const nesting_max = core.value.nesting_max;

/// `locate` over `input` for `segments`; asserts the result is a position inside the input.
fn locate_at(input: []const u8, depth_max: u16, segments: []const Segment) !u32 {
    var path: Path = undefined;
    path.init();
    for (segments) |segment| path.push(segment);
    const before = path.count;
    const offset = scanner.locate(input, .{ .depth_max = depth_max }, &path);
    try testing.expect(offset <= input.len);
    try testing.expectEqual(before, path.count);
    return offset;
}

/// The offset of the first byte of the unique `needle` in `input`.
fn at(input: []const u8, needle: []const u8) u32 {
    // proof: every caller passes a needle that occurs in its own literal input.
    const first = std.mem.find(u8, input, needle) orelse unreachable;
    assert(std.mem.findLast(u8, input, needle).? == first);
    return @intCast(first);
}

fn expect_at(input: []const u8, segments: []const Segment, expected: u32) !void {
    try testing.expectEqual(expected, try locate_at(input, 128, segments));
}

fn key(name: []const u8) Segment {
    return .{ .key = name };
}

fn index(number: u64) Segment {
    return .{ .index = number };
}

const doc =
    \\ {
    \\   "name": "fleet",
    \\   "servers": [
    \\     {"host": "a", "port": 1},
    \\     {"host": "b"},
    \\     {"host": 5}
    \\   ]
    \\ }
;

test "locate: the empty path is the first byte of the root value after whitespace" {
    try expect_at(doc, &.{}, 1);
    try expect_at("  \n\t[1]", &.{}, 4);
    try expect_at("\"s\"", &.{}, 0);
    try expect_at(" 12 ", &.{}, 1);
    try expect_at("null", &.{}, 0);
}

test "locate: a key segment lands on the value, not on the key" {
    try expect_at(doc, &.{key("name")}, at(doc, "\"fleet\""));
    try expect_at(doc, &.{key("servers")}, at(doc, "[\n"));
    try expect_at("{\"a\" :\n\t[1]}", &.{key("a")}, 8);
    try expect_at("{\"a\":{\"b\":true}}", &.{ key("a"), key("b") }, 10);
}

test "locate: an index segment counts whole elements and skips what is inside them" {
    const text = "[1, [2, 3], \"],\", {\"a\": 4}, \"\\\"]\", 5]";
    try expect_at(text, &.{index(0)}, 1);
    try expect_at(text, &.{index(1)}, at(text, "[2, 3]"));
    try expect_at(text, &.{ index(1), index(1) }, at(text, "3]"));
    try expect_at(text, &.{index(2)}, at(text, "\"],\""));
    try expect_at(text, &.{index(3)}, at(text, "{\"a\""));
    try expect_at(text, &.{ index(3), key("a") }, at(text, "4}"));
    try expect_at(text, &.{index(4)}, at(text, "\"\\\"]\""));
    try expect_at(text, &.{index(5)}, at(text, "5]"));
}

test "locate: the first and last index are found and one past the end stops at the array" {
    try expect_at("[7]", &.{index(0)}, 1);
    try expect_at("[7]", &.{index(1)}, 0);
    try expect_at("[]", &.{index(0)}, 0);
    try expect_at("[8,9]", &.{index(1)}, 3);
    try expect_at("[8,9]", &.{index(2)}, 0);
    try expect_at("{\"a\":[8,9]}", &.{ key("a"), index(2) }, 5);
}

test "locate: a key that is absent stops at the object that lacks it" {
    try expect_at("{}", &.{key("a")}, 0);
    try expect_at("{\"b\":1}", &.{key("a")}, 0);
    try expect_at("{\"b\":1}", &.{key("")}, 0);
    try expect_at("{\"b\":1}", &.{key("B")}, 0);
    try expect_at("{\"b\":1}", &.{key("b ")}, 0);
    try expect_at("{\"\":1}", &.{key("")}, 4);
    try expect_at("{\"a\":{\"b\":1}}", &.{ key("a"), key("c") }, 5);
}

test "locate: a segment of the wrong shape stops at the value it was applied to" {
    try expect_at("{\"a\":1}", &.{index(0)}, 0);
    try expect_at("[1]", &.{key("a")}, 0);
    try expect_at("5", &.{key("a")}, 0);
    try expect_at("\"text\"", &.{index(0)}, 0);
    try expect_at("null", &.{index(0)}, 0);
    try expect_at("{\"a\":[1]}", &.{ key("a"), key("x") }, 5);
    try expect_at("{\"a\":7}", &.{ key("a"), index(0) }, 5);
}

test "locate: none descends nowhere and is skipped wherever it stands" {
    try expect_at(doc, &.{.none}, 1);
    try expect_at(doc, &.{ .none, .none }, 1);
    const direct = try locate_at(doc, 128, &.{ key("servers"), index(2), key("host") });
    const spaced = try locate_at(doc, 128, &.{
        .none, key("servers"), .none, index(2), .none, .none, key("host"), .none,
    });
    try testing.expectEqual(at(doc, "5}"), direct);
    try testing.expectEqual(direct, spaced);
    try expect_at("{\"a\":1}", &.{ key("a"), .none }, 5);
}

test "locate: a path that leaves the document stops at the deepest segment it found" {
    const host = at(doc, "5}");
    try expect_at(doc, &.{ key("servers"), index(2), key("host") }, host);
    try expect_at(doc, &.{ key("servers"), index(2), key("host"), key("deeper") }, host);
    try expect_at(doc, &.{ key("servers"), index(2), key("nope") }, at(doc, "{\"host\": 5}"));
    try expect_at(doc, &.{ key("servers"), index(3), key("host") }, at(doc, "[\n"));
    try expect_at(doc, &.{ key("server"), index(0) }, 1);
    try expect_at(doc, &.{ key("servers"), key("host") }, at(doc, "[\n"));
    // A hook's synthetic segment between real ones has no source: the walk ends before it.
    const second = at(doc, "{\"host\": \"b\"}");
    try expect_at(doc, &.{ key("servers"), index(1), key("synthetic"), index(0) }, second);
}

test "locate: the last occurrence of a duplicate key wins" {
    const text = "{\"a\":1,\"a\":{\"b\":2},\"a\":3}";
    try expect_at(text, &.{key("a")}, at(text, "3}"));
    const pair = "{\"a\":{\"x\":1},\"a\":{\"y\":2}}";
    try expect_at(pair, &.{key("a")}, at(pair, "{\"y\""));
    try expect_at(pair, &.{ key("a"), key("y") }, at(pair, "2}"));
    // `x` exists only in the first occurrence, which the parse discarded: stop at the last one.
    try expect_at(pair, &.{ key("a"), key("x") }, at(pair, "{\"y\""));
    const nested = "{\"k\":[0],\"j\":1,\"k\":[0,9]}";
    try expect_at(nested, &.{ key("k"), index(1) }, at(nested, "9]"));
}

test "locate: keys match by decoded bytes, not by spelling" {
    const text = "{\"h\\u006fst\": 7, \"a\\\"b\": {\"c\\\\d\": 8}, \"\\u00e9\": 9}";
    try expect_at(text, &.{key("host")}, at(text, "7,"));
    try expect_at(text, &.{ key("a\"b"), key("c\\d") }, at(text, "8}"));
    try expect_at(text, &.{key("\u{e9}")}, at(text, "9}"));
    // The escape text itself is not the key.
    try expect_at(text, &.{key("h\\u006fst")}, 0);
    try expect_at(text, &.{key("a\\\"b")}, 0);
    const mixed = "{\"a\": 1, \"\\u0061\": 2}";
    try expect_at(mixed, &.{key("a")}, at(mixed, "2}"));
}

test "locate: an index past u32 is not found and never overflows" {
    try expect_at("[1,2]", &.{index(std.math.maxInt(u64))}, 0);
    try expect_at("[1,2]", &.{index(std.math.maxInt(u32))}, 0);
    try expect_at("[1,2]", &.{index(@as(u64, std.math.maxInt(u32)) + 1)}, 0);
}

test "locate: depth_max containers are reachable and the next one is not" {
    const four = "[[[[1]]]]";
    const index_zero: Segment = index(0);
    const zeros = [_]Segment{ index_zero, index_zero, index_zero, index_zero };
    try testing.expectEqual(@as(u32, 4), try locate_at(four, 4, &zeros));
    try testing.expectEqual(@as(u32, 3), try locate_at(four, 4, zeros[0..3]));

    // Container number depth_max + 1 is refused by the scanner, so it is never found: the walk
    // stops at the deepest container it did see (the 4th, at offset 3).
    const five = "[[[[[1]]]]]";
    const walk = [_]Segment{ index_zero, index_zero, index_zero, index_zero, index_zero };
    try testing.expectEqual(@as(u32, 3), try locate_at(five, 4, &walk));
    try testing.expectEqual(@as(u32, 3), try locate_at(five, 4, walk[0..4]));
    try testing.expectEqual(@as(u32, 4), try locate_at(five, 5, walk[0..4]));
    try testing.expectEqual(@as(u32, 5), try locate_at(five, 5, &walk));
}

test "locate: nesting_max index segments reach the innermost scalar of nesting_max arrays" {
    const text = ("[" ** nesting_max) ++ "1" ++ ("]" ** nesting_max);
    var segments: [nesting_max]Segment = @splat(index(0));
    try testing.expectEqual(@as(u32, nesting_max), try locate_at(text, nesting_max, &segments));
    try testing.expectEqual(
        @as(u32, nesting_max - 1),
        try locate_at(text, nesting_max, segments[0 .. nesting_max - 1]),
    );
    try testing.expectEqual(@as(u32, 0), try locate_at(text, nesting_max, &.{}));
}

test "locate: is total on input that is not a document" {
    const inputs = [_][]const u8{
        "",
        "   ",
        "[",
        "[1,",
        "{\"a\":",
        "{\"a\":1,\"b\"",
        "[1 2]",
        "}",
        "\"unterminated",
        "[\"\\x\"]",
        "{\"a\":01}",
        "\xff\xfe",
        "[[[[[[[[1",
    };
    const walks = [_][]const Segment{
        &.{},
        &.{index(0)},
        &.{ index(1), index(0) },
        &.{key("a")},
        &.{ key("a"), key("b"), key("c") },
        &.{ .none, index(5) },
    };
    for (inputs) |input| {
        for (walks) |walk| _ = try locate_at(input, 8, walk);
    }
    try expect_at("", &.{key("a")}, 0);
}

// ---- Seeded model: the generator records where it wrote every value. ----

const model_seeds: u32 = 300;
const model_depth_max: u32 = 5;
const names = [_][]const u8{ "a", "b", "host", "h\"q", "back\\slash", "\u{e9}", "line\nbreak", "" };
const scalars = [_][]const u8{ "0", "-1.5e3", "true", "null", "\"x\"", "\"],}{\"", "\"\\\\\\\"\"" };

const Record = struct {
    segments: [model_depth_max]Segment,
    len: u32,
    offset: u32,
};

const Model = struct {
    gpa: std.mem.Allocator,
    rng: std.Random,
    text: std.ArrayList(u8),
    records: std.ArrayList(Record),
    stack: [model_depth_max]Segment,

    fn space(model: *Model) !void {
        const choices = [_][]const u8{ "", "", " ", "\n", "\t ", "\r\n" };
        const pick = model.rng.uintLessThan(usize, choices.len);
        try model.text.appendSlice(model.gpa, choices[pick]);
    }

    /// Writes one value at `depth` segments from the root and records where it starts.
    fn value(model: *Model, depth: u32) !void {
        assert(depth <= model_depth_max);
        try model.space();
        const offset: u32 = @intCast(model.text.items.len);
        const record: Record = .{ .segments = model.stack, .len = depth, .offset = offset };
        try model.records.append(model.gpa, record);
        const container = depth < model_depth_max and model.rng.uintLessThan(u8, 3) != 0;
        if (!container) {
            const pick = model.rng.uintLessThan(usize, scalars.len);
            return model.text.appendSlice(model.gpa, scalars[pick]);
        }
        if (model.rng.boolean()) return model.object(depth);
        return model.array(depth);
    }

    fn array(model: *Model, depth: u32) !void {
        assert(depth < model_depth_max);
        try model.text.append(model.gpa, '[');
        const count = model.rng.uintLessThan(u32, 5);
        for (0..count) |element| {
            if (element > 0) try model.text.append(model.gpa, ',');
            model.stack[depth] = index(element);
            try model.value(depth + 1);
        }
        try model.space();
        try model.text.append(model.gpa, ']');
    }

    fn object(model: *Model, depth: u32) !void {
        assert(depth < model_depth_max);
        try model.text.append(model.gpa, '{');
        const count = model.rng.uintLessThan(u32, 5);
        var used: u32 = 0;
        for (0..count) |member| {
            if (member > 0) try model.text.append(model.gpa, ',');
            const name_index = model.unused_name(&used);
            try model.space();
            try model.spell(names[name_index]);
            try model.space();
            try model.text.append(model.gpa, ':');
            model.stack[depth] = key(names[name_index]);
            try model.value(depth + 1);
        }
        try model.space();
        try model.text.append(model.gpa, '}');
    }

    fn unused_name(model: *Model, used: *u32) usize {
        for (0..64) |_| {
            const pick = model.rng.uintLessThan(usize, names.len);
            if (used.* & (@as(u32, 1) << @intCast(pick)) != 0) continue;
            used.* |= @as(u32, 1) << @intCast(pick);
            return pick;
        }
        unreachable; // proof: at most 4 of the 8 names are used per object, so 64 draws suffice.
    }

    /// Writes `"name"` with a random escape spelling.
    fn spell(model: *Model, name: []const u8) !void {
        var buffer: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try w.writeByte('"');
        var view = std.unicode.Utf8View.initUnchecked(name).iterator();
        while (view.nextCodepoint()) |codepoint| {
            try raw_eql_test.encode_random(&w, model.rng, codepoint);
        }
        try w.writeByte('"');
        try model.text.appendSlice(model.gpa, w.buffered());
    }
};

test "locate: model: every recorded path lands on the offset the writer recorded" {
    var prng = std.Random.DefaultPrng.init(0x6c6f_6361_7465);
    var checked: u32 = 0;
    for (0..model_seeds) |seed| {
        errdefer std.log.err("locate model failed at seed {d}", .{seed});
        var model: Model = .{
            .gpa = testing.allocator,
            .rng = prng.random(),
            .text = .empty,
            .records = .empty,
            .stack = @splat(.none),
        };
        defer model.text.deinit(testing.allocator);
        defer model.records.deinit(testing.allocator);
        try model.value(0);
        try model.space();
        for (model.records.items) |record| {
            checked += try check_record(&model, record);
        }
    }
    try testing.expect(checked > model_seeds);
}

/// Checks one record three ways: exact, with `.none` sprinkled in, and with a missing segment
/// appended (which must stop at the record). Returns how many paths it checked.
fn check_record(model: *Model, record: Record) !u32 {
    const input = model.text.items;
    const real = record.segments[0..record.len];
    try testing.expectEqual(record.offset, try locate_at(input, 128, real));

    var padded: [model_depth_max * 2 + 1]Segment = undefined;
    var padded_len: u32 = 0;
    for (real) |segment| {
        if (model.rng.boolean()) {
            padded[padded_len] = .none;
            padded_len += 1;
        }
        padded[padded_len] = segment;
        padded_len += 1;
    }
    try testing.expectEqual(record.offset, try locate_at(input, 128, padded[0..padded_len]));

    padded[padded_len] = key("zz_missing");
    try testing.expectEqual(record.offset, try locate_at(input, 128, padded[0 .. padded_len + 1]));
    padded[padded_len] = index(1000);
    try testing.expectEqual(record.offset, try locate_at(input, 128, padded[0 .. padded_len + 1]));
    return 3;
}

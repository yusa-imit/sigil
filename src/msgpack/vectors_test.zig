//! msgpack-test-suite vectors for `msgpack` (plan 007 item 8, ADR 0006 section 10): the 85 cases
//! of `tests/msgpack-test-suite/msgpack-test-suite.json` (see its `SOURCE`), each with several
//! encodings of one value. Every encoding is decoded with `parse_value` and must give the value
//! the case names: nil, bool, binary, number (an integer written as a float decodes to a float,
//! anything else keeps its integer kind), string, array and map (compared by
//! `core/json_compare.zig` with `std.json`, so nothing under `src/msgpack/` imports `json/`),
//! timestamp, and ext. An ext other than -1 is refused with `UnsupportedExt` (ADR 0006
//! section 4) and counted as pinned unsupported, never skipped. The first accepted encoding of
//! each case is also re-encoded, and the shortest-head output must be one of the listed
//! encodings. The counts are asserted, so a change of behavior in either direction fails. The
//! file is read at run time through `std.testing.io`; the test step runs from the repo root.

const std = @import("std");
const core = @import("../core.zig");
const msgpack = @import("../msgpack.zig");
const json_compare = @import("../core/json_compare.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_path = "tests/msgpack-test-suite/msgpack-test-suite.json";
const suite_bytes_max: usize = 1 << 16;
/// Longest hex text of one encoding, dashes included, with room to spare.
const encoding_bytes_max: u32 = 512;

/// Counts of the vendored file. A different total means the vendoring changed.
const file_count: u32 = 15;
const case_count: u32 = 85;
const encoding_count: u32 = 233;
const unsupported_count: u32 = 11;
const encoder_count: u32 = 78;

const parse_options: msgpack.ParseOptions = .{
    .depth_max = core.value.nesting_max,
    .bytes_max = 1 << 16,
    .duplicate_key = .reject,
};
const write_options: msgpack.StringifyOptions = .{ .depth_max = core.value.nesting_max };

const Tally = struct {
    files: u32 = 0,
    cases: u32 = 0,
    encodings: u32 = 0,
    accepted: u32 = 0,
    unsupported: u32 = 0,
    encoder_checked: u32 = 0,
    encoder_in_set: u32 = 0,
    unexpected: u32 = 0,
};

/// The value a case names, in the case's own field: one of the suite's type keys.
const Kind = enum { nil, bool, binary, number, string, array, map, timestamp, ext };

const kind_keys = [_][]const u8{
    "nil", "bool", "binary", "number", "string", "array", "map", "timestamp", "ext",
};

fn kind_of(case: std.json.ObjectMap) Kind {
    for (kind_keys, 0..) |key, index| {
        if (case.get(key) != null) return @enumFromInt(index);
    }
    // A case that names only a `bignum` is a number whose JSON form would lose digits.
    if (case.get("bignum") != null) return .number;
    // proof: the vendored file gives every case one type key; the case counts pin it.
    unreachable;
}

/// `bytes` of the dash-separated hex text, in `buffer`.
fn unhex(buffer: []u8, text: []const u8) ![]const u8 {
    var len: usize = 0;
    var parts = std.mem.splitScalar(u8, text, '-');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const byte = try std.fmt.parseInt(u8, part, 16);
        buffer[len] = byte;
        len += 1;
    }
    return buffer[0..len];
}

/// The integer a `number` case names (`bignum` text wins over the lossy JSON number), or null
/// when the case holds a float.
fn integer_of(case: std.json.ObjectMap) !?i128 {
    if (case.get("bignum")) |text| return try std.fmt.parseInt(i128, text.string, 10);
    const number = case.get("number").?;
    return switch (number) {
        .integer => |n| n,
        else => null,
    };
}

fn number_matches(case: std.json.ObjectMap, first_byte: u8, got: Value) !bool {
    const integer = try integer_of(case) orelse {
        const want = case.get("number").?.float;
        return got == .float and @as(u64, @bitCast(got.float)) == @as(u64, @bitCast(want));
    };
    const wire_float = first_byte == 0xca or first_byte == 0xcb;
    if (wire_float) return got == .float and got.float == @as(f64, @floatFromInt(integer));
    if (integer > std.math.maxInt(i64)) return got == .uint and got.uint == integer;
    return got == .int and got.int == integer;
}

fn timestamp_matches(case: std.json.ObjectMap, got: Value) bool {
    const pair = case.get("timestamp").?.array.items;
    if (got != .timestamp) return false;
    const stamp = got.timestamp;
    return stamp.kind == .instant and stamp.seconds == pair[0].integer and
        stamp.nanoseconds == pair[1].integer and stamp.offset_minutes == null;
}

/// Whether `got`, decoded from an encoding that starts with `first_byte`, is the case's value.
fn case_matches(kind: Kind, case: std.json.ObjectMap, first_byte: u8, got: Value) !bool {
    var buffer: [encoding_bytes_max]u8 = undefined;
    switch (kind) {
        .nil => return got == .null,
        .bool => return got == .bool and got.bool == case.get("bool").?.bool,
        .binary => {
            const want = try unhex(&buffer, case.get("binary").?.string);
            return got == .bytes and std.mem.eql(u8, got.bytes, want);
        },
        .number => return number_matches(case, first_byte, got),
        .string => {
            const want = case.get("string").?.string;
            return got == .string and std.mem.eql(u8, got.string, want);
        },
        .array => return json_compare.matches(case.getPtr("array").?, &got),
        .map => return json_compare.matches(case.getPtr("map").?, &got),
        .timestamp => return timestamp_matches(case, got),
        .ext => return false,
    }
}

/// Re-encodes `root` and reports whether the bytes are one of the listed `encodings`.
fn encoded_in_set(gpa: std.mem.Allocator, root: Value, encodings: []const std.json.Value) !bool {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    msgpack.write_value(&aw.writer, root, write_options, &diag) catch return false;
    var buffer: [encoding_bytes_max]u8 = undefined;
    for (encodings) |encoding| {
        if (std.mem.eql(u8, try unhex(&buffer, encoding.string), aw.written())) return true;
    }
    return false;
}

/// Judges every encoding of one case; `report` logs each unexpected outcome (an error-level log
/// fails a test).
fn judge(gpa: std.mem.Allocator, case: std.json.ObjectMap, tally: *Tally, report: bool) !void {
    const kind = kind_of(case);
    const encodings = case.get("msgpack").?.array.items;
    tally.cases += 1;
    var first_root: ?Value = null;

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    for (encodings) |encoding| {
        var buffer: [encoding_bytes_max]u8 = undefined;
        const input = try unhex(&buffer, encoding.string);
        tally.encodings += 1;

        var diag = Diagnostics.init(0, 0, "", null);
        const outcome = msgpack.parse_value(&tree, input, parse_options, &diag);
        if (outcome) |root| {
            if (try case_matches(kind, case, input[0], root)) {
                tally.accepted += 1;
                if (first_root == null) first_root = root;
                continue;
            }
            tally.unexpected += 1;
            if (report) std.log.err("vectors: {s} decodes to the wrong value", .{encoding.string});
        } else |err| {
            const pinned = kind == .ext and std.mem.eql(u8, @errorName(err), "UnsupportedExt");
            if (pinned and diag.line == 1 and diag.col >= 1) {
                tally.unsupported += 1;
                continue;
            }
            tally.unexpected += 1;
            if (report) std.log.err("vectors: {s} fails with {s}", .{
                encoding.string,
                @errorName(err),
            });
        }
    }
    const root = first_root orelse return;
    tally.encoder_checked += 1;
    if (try encoded_in_set(gpa, root, encodings)) {
        tally.encoder_in_set += 1;
    } else {
        tally.unexpected += 1;
        if (report) std.log.err("vectors: {s} re-encodes outside the list", .{encodings[0].string});
    }
}

fn run_suite(gpa: std.mem.Allocator, text: []const u8, report: bool) !Tally {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();

    var tally: Tally = .{};
    try expect(parsed.value == .object);
    for (parsed.value.object.values()) |file| {
        tally.files += 1;
        try expect(file == .array);
        for (file.array.items) |case| {
            try expect(case == .object);
            try judge(gpa, case.object, &tally, report);
        }
    }
    return tally;
}

test "vectors: the msgpack-test-suite cases have the pinned verdict counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, suite_path, gpa, .limited(suite_bytes_max));
    defer gpa.free(text);

    const tally = try run_suite(gpa, text, true);
    std.log.warn("vectors: {d} files, {d} cases, {d} encodings: {d} accepted, " ++
        "{d} pinned unsupported, {d} unexpected; {d} of {d} re-encodings in the list", .{
        tally.files,          tally.cases,           tally.encodings,
        tally.accepted,       tally.unsupported,     tally.unexpected,
        tally.encoder_in_set, tally.encoder_checked,
    });
    try expectEqual(file_count, tally.files);
    try expectEqual(case_count, tally.cases);
    try expectEqual(encoding_count, tally.encodings);
    try expectEqual(@as(u32, 0), tally.unexpected);
    try expectEqual(unsupported_count, tally.unsupported);
    try expectEqual(encoding_count - unsupported_count, tally.accepted);
    try expectEqual(encoder_count, tally.encoder_checked);
    try expectEqual(tally.encoder_checked, tally.encoder_in_set);
}

test "vectors: the runner rejects every wrong expectation" {
    const gpa = std.testing.allocator;
    const wrong_value = try run_suite(gpa, "{\"f\":[{\"number\":2,\"msgpack\":[\"01\"]}]}", false);
    try expectEqual(@as(u32, 1), wrong_value.unexpected);
    try expectEqual(@as(u32, 0), wrong_value.accepted);

    const unlisted = try run_suite(gpa, "{\"f\":[{\"number\":1,\"msgpack\":[\"cc-01\"]}]}", false);
    try expectEqual(@as(u32, 1), unlisted.accepted);
    try expectEqual(@as(u32, 1), unlisted.unexpected);
    try expectEqual(@as(u32, 0), unlisted.encoder_in_set);

    const reserved = try run_suite(gpa, "{\"f\":[{\"nil\":null,\"msgpack\":[\"c1\"]}]}", false);
    try expectEqual(@as(u32, 1), reserved.unexpected);
    try expectEqual(@as(u32, 0), reserved.unsupported);

    const as_float = "{\"f\":[{\"number\":1,\"msgpack\":[\"ca-3f-80-00-00\"]}]}";
    const float_form = try run_suite(gpa, as_float, false);
    try expectEqual(@as(u32, 1), float_form.accepted);
    try expectEqual(@as(u32, 0), float_form.unexpected);
}

test {
    _ = json_compare;
}

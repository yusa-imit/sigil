//! TOML compliance suite for `toml/parser.zig` (plan 006 item 8, ADR 0005 section 9): the MIT
//! licensed TOML 1.0.0 cases of toml-test v2.2.0, vendored in `tests/toml-test/` (see its
//! `SOURCE`). `files-toml-1.0.0` lists every case file. An `invalid/` case must fail
//! `parse_value` with a typed error and a position (line >= 1); a `valid/` case must parse and
//! equal its tagged-JSON expectation (`{"type": ..., "value": "..."}` leaves), which is decoded
//! with `std.json` so nothing under `src/toml/` imports `json/`. Floats compare by bit pattern
//! with every NaN equal; datetimes by kind and by the value `core.timestamp.parse` gives the
//! expected token (the expectations pad fractions to milliseconds). Every case is
//! judged and tallied and the exact counts are asserted, so a change of behavior in either
//! direction fails the test; a case that still diverges is named in `pinned_divergent` with the
//! reason, never skipped. The suite is read at run time through `std.testing.io`; the test step
//! runs from the repo root.

const std = @import("std");
const core = @import("../core.zig");
const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_dir = "tests/toml-test/";
const list_bytes_max: usize = 1 << 16;
const case_bytes_max: usize = 1 << 20;
/// Pairs awaiting comparison; the deepest corpus document is far below this.
const pending_max: u32 = 4096;

/// Counts of the vendored suite. A different total means the vendoring changed.
const case_count: u32 = 679;
pub const valid_count: u32 = 205;
const invalid_count: u32 = 474;
const divergent_count: u32 = 0;

const options: parser.ParseOptions = .{ .depth_max = core.value.nesting_max, .bytes_max = 1 << 20 };

/// A case path and why this implementation judges it differently from the suite.
const Pin = struct { path: []const u8, reason: []const u8 };

const pinned_divergent = [_]Pin{};

const Verdict = enum { pass, diverges };

const Tally = struct {
    valid: u32 = 0,
    invalid: u32 = 0,
    pass: u32 = 0,
    pinned: u32 = 0,
    diverging: u32 = 0,
};

const Pair = struct { want: *const std.json.Value, got: *const Value };

const leaf_types = [_][]const u8{
    "string",   "integer",        "float",      "bool",
    "datetime", "datetime-local", "date-local", "time-local",
};

/// The `type` and `value` strings when `object` is a tagged leaf, else null (a table).
fn leaf_of(object: std.json.ObjectMap) ?struct { kind: []const u8, text: []const u8 } {
    if (object.count() != 2) return null;
    const kind = object.get("type") orelse return null;
    const text = object.get("value") orelse return null;
    if (kind != .string or text != .string) return null;
    for (leaf_types) |known| {
        if (std.mem.eql(u8, known, kind.string)) {
            return .{ .kind = kind.string, .text = text.string };
        }
    }
    return null;
}

fn float_matches(text: []const u8, got: f64) bool {
    const body = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    if (std.mem.eql(u8, body, "nan")) return std.math.isNan(got);
    const want = if (std.mem.eql(u8, body, "inf"))
        (if (text[0] == '-') -std.math.inf(f64) else std.math.inf(f64))
    else
        std.fmt.parseFloat(f64, text) catch return false;
    return @as(u64, @bitCast(want)) == @as(u64, @bitCast(got));
}

fn stamp_matches(kind: []const u8, text: []const u8, stamp: core.Timestamp) bool {
    const want: core.Timestamp.Kind = if (std.mem.eql(u8, kind, "datetime"))
        .instant
    else if (std.mem.eql(u8, kind, "datetime-local"))
        .local_datetime
    else if (std.mem.eql(u8, kind, "date-local"))
        .local_date
    else
        .local_time;
    if (stamp.kind != want) return false;
    // The expectation pads fractions to milliseconds (".600"), which `format` does not, so the
    // text is compared as a value: the expected token parsed by `core.timestamp.parse`.
    const expected = core.timestamp.parse(text) catch return false;
    if (expected.kind != stamp.kind) return false;
    if (expected.seconds != stamp.seconds) return false;
    if (expected.nanoseconds != stamp.nanoseconds) return false;
    return expected.offset_minutes == stamp.offset_minutes;
}

fn leaf_matches(kind: []const u8, text: []const u8, got: *const Value) bool {
    if (std.mem.eql(u8, kind, "string")) {
        return got.* == .string and std.mem.eql(u8, got.string, text);
    }
    if (std.mem.eql(u8, kind, "integer")) {
        const want = std.fmt.parseInt(i64, text, 10) catch return false;
        return got.* == .int and got.int == want;
    }
    if (std.mem.eql(u8, kind, "float")) return got.* == .float and float_matches(text, got.float);
    if (std.mem.eql(u8, kind, "bool")) {
        return got.* == .bool and std.mem.eql(u8, text, if (got.bool) "true" else "false");
    }
    return got.* == .timestamp and stamp_matches(kind, text, got.timestamp);
}

/// True when `got` equals the tagged-JSON expectation `want`. Walks both trees on an explicit
/// stack; an overflow of it is an error, never a verdict.
fn expectation_matches(want: *const std.json.Value, got: *const Value) error{StackFull}!bool {
    var pending: [pending_max]Pair = undefined;
    var count: u32 = 1;
    pending[0] = .{ .want = want, .got = got };
    for (0..pending_max * 64) |_| {
        if (count == 0) return true;
        count -= 1;
        const pair = pending[count];
        switch (pair.want.*) {
            .object => |object| {
                if (leaf_of(object)) |leaf| {
                    if (!leaf_matches(leaf.kind, leaf.text, pair.got)) return false;
                    continue;
                }
                if (pair.got.* != .map) return false;
                if (pair.got.map.count != object.count()) return false;
                for (object.keys(), object.values()) |key, *member| {
                    const child = pair.got.map.get(key) orelse return false;
                    if (count == pending_max) return error.StackFull;
                    pending[count] = .{ .want = member, .got = child };
                    count += 1;
                }
            },
            .array => |items| {
                if (pair.got.* != .array) return false;
                if (pair.got.array.len != items.items.len) return false;
                for (items.items, pair.got.array) |*member, *child| {
                    if (count == pending_max) return error.StackFull;
                    pending[count] = .{ .want = member, .got = child };
                    count += 1;
                }
            },
            else => return false,
        }
    }
    return error.StackFull;
}

pub fn read_case(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ suite_dir, path });
    defer gpa.free(full);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, gpa, .limited(case_bytes_max));
}

/// Judges one `invalid/` case: `parse_value` must fail and say where.
fn judge_invalid(gpa: std.mem.Allocator, path: []const u8) !Verdict {
    const input = try read_case(gpa, path);
    defer gpa.free(input);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    _ = parser.parse_value(gpa, &tree, input, options, &diag) catch {
        return if (diag.line >= 1 and diag.col >= 1) .pass else .diverges;
    };
    return .diverges;
}

/// Judges one `valid/` case against the `.json` file beside it.
fn judge_valid(gpa: std.mem.Allocator, path: []const u8) !Verdict {
    const input = try read_case(gpa, path);
    defer gpa.free(input);

    const expectation_path = try std.fmt.allocPrint(gpa, "{s}.json", .{path[0 .. path.len - 5]});
    defer gpa.free(expectation_path);

    const expectation = try read_case(gpa, expectation_path);
    defer gpa.free(expectation);

    var decoded = try std.json.parseFromSlice(std.json.Value, gpa, expectation, .{});
    defer decoded.deinit();

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const root = parser.parse_value(gpa, &tree, input, options, &diag) catch return .diverges;
    return if (try expectation_matches(&decoded.value, &root)) .pass else .diverges;
}

fn pin_of(pins: []const Pin, path: []const u8) ?Pin {
    for (pins) |pin| {
        if (std.mem.eql(u8, pin.path, path)) return pin;
    }
    return null;
}

/// Judges every case of the list; `report` logs each unexpected divergence (an error-level
/// log fails a test, so the probe test passes false).
fn run_suite(gpa: std.mem.Allocator, list: []const u8, pins: []const Pin, report: bool) !Tally {
    var tally: Tally = .{};
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".toml")) continue;
        const invalid = std.mem.startsWith(u8, path, "invalid/");
        if (!invalid) try expect(std.mem.startsWith(u8, path, "valid/"));
        const verdict = if (invalid) try judge_invalid(gpa, path) else try judge_valid(gpa, path);
        if (invalid) tally.invalid += 1 else tally.valid += 1;
        switch (verdict) {
            .pass => tally.pass += 1,
            .diverges => if (pin_of(pins, path) != null) {
                tally.pinned += 1;
            } else {
                tally.diverging += 1;
                if (report) std.log.err("conformance: '{s}' diverges", .{path});
            },
        }
    }
    return tally;
}

test "conformance: the vendored toml-test suite has the pinned verdict counts" {
    const gpa = std.testing.allocator;
    const list = try read_case(gpa, "files-toml-1.0.0");
    defer gpa.free(list);

    const tally = try run_suite(gpa, list, &pinned_divergent, true);
    const total = tally.valid + tally.invalid;
    std.log.warn("conformance: {d} cases ({d} invalid, {d} valid): {d} pass, " ++
        "{d} pinned divergent, {d} unexpected", .{
        total,      tally.invalid, tally.valid,
        tally.pass, tally.pinned,  tally.diverging,
    });
    try expectEqual(case_count, total);
    try expectEqual(invalid_count, tally.invalid);
    try expectEqual(valid_count, tally.valid);
    try expectEqual(@as(u32, 0), tally.diverging);
    try expectEqual(divergent_count, tally.pinned);
    try expectEqual(case_count - divergent_count, tally.pass);
}

/// Parses `toml_text` and judges it against the tagged-JSON `json_text`.
fn probe(toml_text: []const u8, json_text: []const u8) !bool {
    const gpa = std.testing.allocator;
    var decoded = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer decoded.deinit();

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const root = try parser.parse_value(gpa, &tree, toml_text, options, &diag);
    return expectation_matches(&decoded.value, &root);
}

test "conformance: the comparator rejects every wrong expectation" {
    try expect(try probe("a = 1", "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}"));
    try expect(!try probe("a = 1", "{\"a\":{\"type\":\"integer\",\"value\":\"2\"}}"));
    try expect(!try probe("a = 1", "{\"a\":{\"type\":\"float\",\"value\":\"1\"}}"));
    try expect(!try probe("a = 1", "{\"b\":{\"type\":\"integer\",\"value\":\"1\"}}"));
    try expect(!try probe("a = 1", "{}"));
    try expect(!try probe("", "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}"));
    try expect(try probe("a = nan", "{\"a\":{\"type\":\"float\",\"value\":\"nan\"}}"));
    try expect(try probe("a = -inf", "{\"a\":{\"type\":\"float\",\"value\":\"-inf\"}}"));
    try expect(!try probe("a = inf", "{\"a\":{\"type\":\"float\",\"value\":\"-inf\"}}"));
    try expect(!try probe("a = -0.0", "{\"a\":{\"type\":\"float\",\"value\":\"0\"}}"));
    try expect(try probe("a = [1, 2]", "{\"a\":[{\"type\":\"integer\",\"value\":\"1\"}," ++
        "{\"type\":\"integer\",\"value\":\"2\"}]}"));
    try expect(!try probe("a = [1, 2]", "{\"a\":[{\"type\":\"integer\",\"value\":\"1\"}]}"));
    try expect(!try probe("a = true", "{\"a\":{\"type\":\"bool\",\"value\":\"false\"}}"));
    try expect(!try probe("a = 'x'", "{\"a\":{\"type\":\"string\",\"value\":\"y\"}}"));
}

test "conformance: datetimes compare by kind and value, not by fraction text" {
    const shape = "{\"a\":{\"type\":\"datetime\",\"value\":\"1987-07-05T17:45:56.600Z\"}}";
    try expect(try probe("a = 1987-07-05T17:45:56.6Z", shape));
    try expect(!try probe("a = 1987-07-05T17:45:56.7Z", shape));
    try expect(!try probe("a = 1987-07-05T17:45:56.6", shape));
    const local = "{\"a\":{\"type\":\"datetime-local\",\"value\":\"1987-07-05T17:45:56.600\"}}";
    try expect(try probe("a = 1987-07-05 17:45:56.6", local));
    try expect(!try probe("a = 1987-07-05T17:45:56.6Z", local));
}

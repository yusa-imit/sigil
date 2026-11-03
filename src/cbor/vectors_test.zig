//! RFC 8949 Appendix A vectors for `cbor` (plan 007 item 8, ADR 0006 section 10): the 82 items
//! of `tests/cbor/appendix_a.json` (see its `SOURCE`). Each hex item is decoded with
//! `parse_value`. An item whose expected form is JSON (`decoded`) must equal it, compared by
//! `core/json_compare.zig` with `std.json`, so nothing under `src/cbor/` imports `json/`. An
//! item given in diagnostic notation is judged by `diagnostic_matches`. An item this decoder
//! refuses on purpose (ADR 0006 sections 3 and 4) is named in `pinned_unsupported` with its
//! error and reason, never skipped: the error must be that one, at a position. Every item the
//! decoder accepts and the file marks `roundtrip` must re-encode to the same bytes. The counts
//! are asserted, so a change of behavior in either direction fails. The file is read at run
//! time through `std.testing.io`; the test step runs from the repo root.

const std = @import("std");
const core = @import("../core.zig");
const cbor = @import("../cbor.zig");
const json_compare = @import("../core/json_compare.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_path = "tests/cbor/appendix_a.json";
const suite_bytes_max: usize = 1 << 16;
const item_bytes_max: u32 = 256;

/// Counts of the vendored file. A different total means the vendoring changed.
const item_count: u32 = 82;
const json_count: u32 = 59;
const diagnostic_count: u32 = 23;
const unsupported_count: u32 = 11;
const roundtrip_count: u32 = 54;

const parse_options: cbor.ParseOptions = .{
    .depth_max = core.value.nesting_max,
    .bytes_max = 1 << 16,
    .duplicate_key = .reject,
};
const write_options: cbor.StringifyOptions = .{
    .depth_max = core.value.nesting_max,
    .deterministic = false,
};

/// An item the decoder refuses on purpose: its hex, the error it returns, and why.
const Pin = struct { hex: []const u8, error_name: []const u8, reason: []const u8 };

const pinned_unsupported = [_]Pin{
    .{ .hex = "c249010000000000000000", .error_name = "IntegerAboveMax", .reason = "2^64" },
    .{ .hex = "3bffffffffffffffff", .error_name = "IntegerBelowMin", .reason = "-2^64" },
    .{ .hex = "c349010000000000000000", .error_name = "IntegerBelowMin", .reason = "-2^64-1" },
    .{ .hex = "f7", .error_name = "UnsupportedSimple", .reason = "undefined, ADR 0006 s4" },
    .{ .hex = "f0", .error_name = "UnsupportedSimple", .reason = "simple(16), ADR 0006 s4" },
    .{ .hex = "f818", .error_name = "NotWellFormed", .reason = "simple(24), RFC 8949 3.3" },
    .{ .hex = "f8ff", .error_name = "UnsupportedSimple", .reason = "simple(255), ADR 0006 s4" },
    .{ .hex = "d74401020304", .error_name = "UnsupportedTag", .reason = "tag 23, ADR 0006 s4" },
    .{ .hex = "d818456449455446", .error_name = "UnsupportedTag", .reason = "tag 24, s4" },
    .{
        .hex = "d82076687474703a2f2f7777772e6578616d706c652e636f6d",
        .error_name = "UnsupportedTag",
        .reason = "tag 32, ADR 0006 s4",
    },
    .{ .hex = "a201020304", .error_name = "NonStringKey", .reason = "integer keys, ADR 0006 s3" },
};

const Tally = struct {
    json: u32 = 0,
    diagnostic: u32 = 0,
    accepted: u32 = 0,
    unsupported: u32 = 0,
    roundtrip_checked: u32 = 0,
    roundtrip_identical: u32 = 0,
    unexpected: u32 = 0,
};

fn pin_of(hex: []const u8) ?Pin {
    for (pinned_unsupported) |pin| {
        if (std.mem.eql(u8, pin.hex, hex)) return pin;
    }
    return null;
}

/// What a diagnostic-notation item decodes to; the accepted ones among them.
const Shape = enum {
    nan,
    inf_pos,
    inf_neg,
    time_text,
    time_int,
    time_float,
    bytes_empty,
    bytes_four,
    bytes_chunks,
};

const Diagnostic = struct { hex: []const u8, shape: Shape };

const diagnostic_cases = [_]Diagnostic{
    .{ .hex = "f97c00", .shape = .inf_pos },
    .{ .hex = "f97e00", .shape = .nan },
    .{ .hex = "f9fc00", .shape = .inf_neg },
    .{ .hex = "fa7f800000", .shape = .inf_pos },
    .{ .hex = "fa7fc00000", .shape = .nan },
    .{ .hex = "faff800000", .shape = .inf_neg },
    .{ .hex = "fb7ff0000000000000", .shape = .inf_pos },
    .{ .hex = "fb7ff8000000000000", .shape = .nan },
    .{ .hex = "fbfff0000000000000", .shape = .inf_neg },
    .{ .hex = "c074323031332d30332d32315432303a30343a30305a", .shape = .time_text },
    .{ .hex = "c11a514b67b0", .shape = .time_int },
    .{ .hex = "c1fb41d452d9ec200000", .shape = .time_float },
    .{ .hex = "40", .shape = .bytes_empty },
    .{ .hex = "4401020304", .shape = .bytes_four },
    .{ .hex = "5f42010243030405ff", .shape = .bytes_chunks },
};

/// 2013-03-21T20:04:00Z, the instant RFC 8949 Appendix A uses for tags 0 and 1.
const instant_seconds: i64 = 1_363_896_240;

fn instant_is(got: Value, nanoseconds: u32, offset_minutes: ?i16) bool {
    if (got != .timestamp) return false;
    const stamp = got.timestamp;
    if (stamp.kind != .instant) return false;
    if (stamp.seconds != instant_seconds) return false;
    if (stamp.nanoseconds != nanoseconds) return false;
    return stamp.offset_minutes == offset_minutes;
}

fn shape_matches(shape: Shape, got: Value) bool {
    switch (shape) {
        .nan => return got == .float and std.math.isNan(got.float),
        .inf_pos => return got == .float and got.float == std.math.inf(f64),
        .inf_neg => return got == .float and got.float == -std.math.inf(f64),
        .time_text => return instant_is(got, 0, 0),
        .time_int => return instant_is(got, 0, null),
        .time_float => return instant_is(got, 500_000_000, null),
        .bytes_empty => return got == .bytes and got.bytes.len == 0,
        .bytes_four => return got == .bytes and std.mem.eql(u8, got.bytes, &.{ 1, 2, 3, 4 }),
        .bytes_chunks => return got == .bytes and std.mem.eql(u8, got.bytes, &.{ 1, 2, 3, 4, 5 }),
    }
}

/// Whether `got` is the value the diagnostic notation of the item with this `hex` names; an
/// item with no entry in `diagnostic_cases` matches nothing.
fn diagnostic_matches(hex: []const u8, got: Value) bool {
    for (diagnostic_cases) |case| {
        if (std.mem.eql(u8, case.hex, hex)) return shape_matches(case.shape, got);
    }
    return false;
}

fn read_suite(gpa: std.mem.Allocator) ![]u8 {
    const io = std.testing.io;
    return std.Io.Dir.cwd().readFileAlloc(io, suite_path, gpa, .limited(suite_bytes_max));
}

/// Judges one item; `report` logs each unexpected outcome (an error-level log fails a test).
fn judge(gpa: std.mem.Allocator, item: std.json.ObjectMap, tally: *Tally, report: bool) !void {
    const hex = item.get("hex").?.string;
    var bytes: [item_bytes_max]u8 = undefined;
    const input = try std.fmt.hexToBytes(&bytes, hex);
    const expected = item.get("decoded");
    if (expected != null) tally.json += 1 else tally.diagnostic += 1;

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const root = cbor.parse_value(&tree, input, parse_options, &diag) catch |err| {
        const pin = pin_of(hex) orelse {
            tally.unexpected += 1;
            if (report) std.log.err("vectors: {s} fails with {s}", .{ hex, @errorName(err) });
            return;
        };
        const named = std.mem.eql(u8, pin.error_name, @errorName(err));
        if (named and diag.line == 1 and diag.col >= 1) {
            tally.unsupported += 1;
        } else {
            tally.unexpected += 1;
            if (report) std.log.err("vectors: {s} pinned {s}, got {s}", .{
                hex, pin.error_name, @errorName(err),
            });
        }
        return;
    };
    const agrees = if (expected) |want|
        json_compare.matches(&want, &root)
    else
        diagnostic_matches(hex, root);
    if (!agrees) {
        tally.unexpected += 1;
        if (report) std.log.err("vectors: {s} decodes to the wrong value", .{hex});
        return;
    }
    tally.accepted += 1;
    if (item.get("roundtrip").?.bool) try judge_roundtrip(gpa, hex, root, input, tally, report);
}

fn judge_roundtrip(
    gpa: std.mem.Allocator,
    hex: []const u8,
    root: Value,
    input: []const u8,
    tally: *Tally,
    report: bool,
) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    tally.roundtrip_checked += 1;
    cbor.write_value(&aw.writer, root, write_options, &diag) catch {
        tally.unexpected += 1;
        if (report) std.log.err("vectors: {s} does not re-encode", .{hex});
        return;
    };
    if (std.mem.eql(u8, aw.written(), input)) {
        tally.roundtrip_identical += 1;
    } else {
        tally.unexpected += 1;
        if (report) std.log.err("vectors: {s} re-encodes differently", .{hex});
    }
}

fn run_suite(gpa: std.mem.Allocator, text: []const u8, report: bool) !Tally {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();

    var tally: Tally = .{};
    try expect(parsed.value == .array);
    for (parsed.value.array.items) |item| {
        try expect(item == .object);
        try judge(gpa, item.object, &tally, report);
    }
    return tally;
}

test "vectors: the RFC 8949 Appendix A items have the pinned verdict counts" {
    const gpa = std.testing.allocator;
    const text = try read_suite(gpa);
    defer gpa.free(text);

    const tally = try run_suite(gpa, text, true);
    const total = tally.json + tally.diagnostic;
    std.log.warn("vectors: {d} items ({d} json, {d} diagnostic): {d} accepted, " ++
        "{d} pinned unsupported, {d} unexpected; {d} of {d} roundtrip items re-encode same", .{
        total,                     tally.json,              tally.diagnostic,
        tally.accepted,            tally.unsupported,       tally.unexpected,
        tally.roundtrip_identical, tally.roundtrip_checked,
    });
    try expectEqual(item_count, total);
    try expectEqual(json_count, tally.json);
    try expectEqual(diagnostic_count, tally.diagnostic);
    try expectEqual(@as(u32, 0), tally.unexpected);
    try expectEqual(unsupported_count, tally.unsupported);
    try expectEqual(item_count - unsupported_count, tally.accepted);
    try expectEqual(roundtrip_count, tally.roundtrip_checked);
    try expectEqual(tally.roundtrip_checked, tally.roundtrip_identical);
}

test "vectors: the runner rejects every wrong expectation" {
    const gpa = std.testing.allocator;
    const wrong = try run_suite(gpa, "[{\"hex\":\"01\",\"roundtrip\":true,\"decoded\":2}]", false);
    try expectEqual(@as(u32, 1), wrong.unexpected);
    try expectEqual(@as(u32, 0), wrong.accepted);

    const wide = try run_suite(gpa, "[{\"hex\":\"1801\",\"roundtrip\":true,\"decoded\":1}]", false);
    try expectEqual(@as(u32, 1), wide.accepted);
    try expectEqual(@as(u32, 1), wide.roundtrip_checked);
    try expectEqual(@as(u32, 0), wide.roundtrip_identical);
    try expectEqual(@as(u32, 1), wide.unexpected);

    const stray = "[{\"hex\":\"ff\",\"roundtrip\":false,\"diagnostic\":\"x\"}]";
    const unnamed = try run_suite(gpa, stray, false);
    try expectEqual(@as(u32, 1), unnamed.unexpected);
    try expectEqual(@as(u32, 0), unnamed.unsupported);

    const nan = "[{\"hex\":\"f97e00\",\"roundtrip\":true,\"diagnostic\":\"NaN\"}]";
    const named = try run_suite(gpa, nan, false);
    try expectEqual(@as(u32, 1), named.accepted);
    try expectEqual(@as(u32, 0), named.unexpected);
}

test {
    _ = json_compare;
}

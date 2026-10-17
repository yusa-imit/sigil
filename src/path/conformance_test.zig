//! JSONPath compliance suite for `path/jsonpath.zig` (plan 005 item 8): the BSD-2 licensed
//! `cts.json` of the jsonpath-standard project (commit 20ebdcc, license and notice beside it in
//! `tests/jsonpath/`). Every test is judged and tallied: an `invalid_selector` test must fail
//! `compile` with a typed error; a valid test must compile, select, and render each result to
//! the expected JSON (the `results` alternatives of the nine object-order tests match if any
//! one does); the `match`/`search` tests, which need an I-Regexp matcher (ADR 0004 section 6),
//! are pinned as `UnsupportedFunction` rather than skipped. The exact counts are asserted, so a
//! change of behavior in either direction fails the test instead of passing silently, and the
//! tests that still diverge from the suite are named in `pinned_divergent`.
//! The suite is read at run time through `std.testing.io`; the test step runs from the repo root.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("../json/dom.zig");
const writer = @import("../json/writer.zig");
const jsonpath = @import("jsonpath.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const Program = jsonpath.Program;
const Value = core.Value;
const ValueTree = core.ValueTree;

const suite_path = "tests/jsonpath/cts.json";
const suite_bytes_max: usize = 1 << 20;
const nodes_max: u32 = 2048;

/// Counts of the vendored suite. A different total means the vendoring changed.
const suite_count: u32 = 715;
const invalid_count: u32 = 249;
const valid_count: u32 = 466;
/// Tests whose selector uses `match` or `search` (24 + 32 tagged in the suite), valid or not.
const unsupported_count: u32 = 56;
/// Tests expected to be accepted (or rejected) that this implementation judges the other way.
const divergent_count: u32 = 0;

/// Suite tests (by `name`) on which this implementation differs from the suite, with the reason.
const pinned_divergent = [_][]const u8{};

const parse_options: dom.ParseOptions = .{
    .depth_max = core.value.nesting_max,
    .duplicate_key = .reject,
};
const render_options: writer.StringifyOptions = .{
    .layout = .minified,
    .sort_keys = true,
    .escape = .minimal,
    .depth_max = core.value.nesting_max,
};

const Verdict = enum { pass, unsupported, diverges };

const Tally = struct {
    invalid: u32 = 0,
    valid: u32 = 0,
    pass: u32 = 0,
    unsupported: u32 = 0,
    /// Unsupported tests the suite does not tag `match` or `search`: must stay zero.
    untagged: u32 = 0,
    diverging: u32 = 0,
};

/// True when the case carries `tag` in its `tags` array.
fn has_tag(case: *const core.Map, tag: []const u8) bool {
    const tags = case.get("tags") orelse return false;
    for (tags.array) |entry| {
        if (std.mem.eql(u8, entry.string, tag)) return true;
    }
    return false;
}

fn is_pinned(name: []const u8) bool {
    for (pinned_divergent) |pinned| {
        if (std.mem.eql(u8, pinned, name)) return true;
    }
    return false;
}

fn render(gpa: std.mem.Allocator, value: *const Value) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    try writer.write(&text.writer, value.*, render_options, &diag);
    return text.toOwnedSlice();
}

/// True when the selected `nodes` render to the array `want` of expected results, in order.
fn nodes_match(gpa: std.mem.Allocator, nodes: []const *const Value, want: []const Value) !bool {
    if (nodes.len != want.len) return false;
    for (nodes, want) |node, expected| {
        const got_text = try render(gpa, node);
        defer gpa.free(got_text);

        const want_text = try render(gpa, &expected);
        defer gpa.free(want_text);

        if (!std.mem.eql(u8, got_text, want_text)) return false;
    }
    return true;
}

/// Judges one valid test: compile, select, compare against `result` or any of `results`.
fn judge_valid(gpa: std.mem.Allocator, case: *const core.Map) !Verdict {
    const selector = case.get("selector").?.string;
    var program: Program = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    // proof: `compile` does no I/O, so `error.Canceled` cannot occur; the set is exhaustive.
    jsonpath.compile(&program, selector, &diag) catch |err| switch (err) {
        error.UnsupportedFunction => return .unsupported,
        error.InvalidSyntax,
        error.QueryTooLong,
        error.TooManySegments,
        error.TooManySelectors,
        error.IntegerOutOfRange,
        error.FilterTooDeep,
        error.FilterTooLong,
        error.UnknownFunction,
        => return .diverges,
    };
    var out: [nodes_max]*const Value = undefined;
    const document = case.get("document").?;
    // A bigger answer than the buffer is a divergence to report, not a crash.
    const nodes = jsonpath.select(&program, document, &out) catch return .diverges;
    if (case.get("result")) |want| {
        return if (try nodes_match(gpa, nodes, want.array)) .pass else .diverges;
    }
    for (case.get("results").?.array) |alternative| {
        if (try nodes_match(gpa, nodes, alternative.array)) return .pass;
    }
    return .diverges;
}

/// Judges one `invalid_selector` test: `compile` must fail with a typed error.
fn judge_invalid(case: *const core.Map) Verdict {
    const selector = case.get("selector").?.string;
    var program: Program = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    // proof: `compile` does no I/O, so `error.Canceled` cannot occur; the set is exhaustive.
    jsonpath.compile(&program, selector, &diag) catch |err| switch (err) {
        error.UnsupportedFunction => return .unsupported,
        error.InvalidSyntax,
        error.QueryTooLong,
        error.TooManySegments,
        error.TooManySelectors,
        error.IntegerOutOfRange,
        error.FilterTooDeep,
        error.FilterTooLong,
        error.UnknownFunction,
        => return .pass,
    };
    return .diverges;
}

fn run_suite(gpa: std.mem.Allocator, tests: []const Value) !Tally {
    var tally: Tally = .{};
    for (tests) |*item| {
        const case = &item.map;
        const name = case.get("name").?.string;
        const invalid = case.get("invalid_selector") != null;
        const verdict = if (invalid) judge_invalid(case) else try judge_valid(gpa, case);
        if (invalid) tally.invalid += 1 else tally.valid += 1;
        switch (verdict) {
            .pass => tally.pass += 1,
            .unsupported => {
                tally.unsupported += 1;
                if (!has_tag(case, "match") and !has_tag(case, "search")) tally.untagged += 1;
            },
            .diverges => {
                if (is_pinned(name)) continue;
                tally.diverging += 1;
                std.log.err("conformance: '{s}' [{s}] diverges", .{
                    name, case.get("selector").?.string,
                });
            },
        }
    }
    return tally;
}

test "conformance: the vendored JSONPath suite has the pinned verdict counts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);

    const bytes = try dir.readFileAlloc(io, suite_path, gpa, .limited(suite_bytes_max));
    defer gpa.free(bytes);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, bytes, parse_options, &diag);
    const tests = root.map.get("tests").?.array;
    const tally = try run_suite(gpa, tests);
    std.log.warn("conformance: {d} tests, {d} invalid, {d} valid, {d} pass, {d} unsupported", .{
        tests.len, tally.invalid, tally.valid, tally.pass, tally.unsupported,
    });
    try expectEqual(suite_count, @as(u32, @intCast(tests.len)));
    try expectEqual(invalid_count, tally.invalid);
    try expectEqual(valid_count, tally.valid);
    try expectEqual(unsupported_count, tally.unsupported);
    try expectEqual(@as(u32, 0), tally.untagged);
    try expectEqual(divergent_count, tally.diverging);
    try expectEqual(suite_count - unsupported_count - divergent_count, tally.pass);
}

const probe_cases =
    \\[{"name":"ok","selector":"$.a","document":{"a":1},"result":[1]},
    \\{"name":"wrong result","selector":"$.a","document":{"a":1},"result":[2]},
    \\{"name":"valid but marked invalid","selector":"$.a","invalid_selector":true},
    \\{"name":"invalid","selector":"$.","invalid_selector":true}]
;

test "conformance: the judges fail a wrong expectation and a wrong validity" {
    const gpa = std.testing.allocator;
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const cases = try dom.parse(&tree, probe_cases, parse_options, &diag);
    const items = cases.array;
    try expectEqual(Verdict.pass, try judge_valid(gpa, &items[0].map));
    try expectEqual(Verdict.diverges, try judge_valid(gpa, &items[1].map));
    try expectEqual(Verdict.diverges, judge_invalid(&items[2].map));
    try expectEqual(Verdict.pass, judge_invalid(&items[3].map));
}

test "conformance: a divergence is pinned by name or counted" {
    comptime std.debug.assert(pinned_divergent.len == divergent_count);
    try expect(!is_pinned("basic, root"));
}

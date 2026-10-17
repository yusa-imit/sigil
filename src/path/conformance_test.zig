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
    /// Divergences named in `pinned_divergent`.
    pinned: u32 = 0,
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

fn is_pinned(pins: []const []const u8, name: []const u8) bool {
    for (pins) |pinned| {
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

/// How `compile` treated a selector. `limit` is a resource limit, never a grammar verdict.
const Compiled = enum { ok, unsupported, syntax, limit };

fn compile_class(selector: []const u8, diag: *Diagnostics) Compiled {
    var program: Program = undefined;
    // proof: exhaustive over `QueryError`, which has no I/O error; new variants need an arm.
    jsonpath.compile(&program, selector, diag) catch |err| switch (err) {
        error.UnsupportedFunction => return .unsupported,
        error.InvalidSyntax, error.IntegerOutOfRange, error.UnknownFunction => return .syntax,
        error.QueryTooLong,
        error.TooManySegments,
        error.TooManySelectors,
        error.FilterTooDeep,
        error.FilterTooLong,
        => return .limit,
    };
    return .ok;
}

/// Judges one valid test: compile, select, compare against `result` or any of `results`.
fn judge_valid(gpa: std.mem.Allocator, case: *const core.Map) !Verdict {
    const selector = case.get("selector").?.string;
    var diag = Diagnostics.init(0, 0, "", null);
    switch (compile_class(selector, &diag)) {
        .ok => {},
        .unsupported => return .unsupported,
        .syntax, .limit => return .diverges,
    }
    var program: Program = undefined;
    try jsonpath.compile(&program, selector, &diag);

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

/// Judges one `invalid_selector` test: `compile` must reject it as a grammar error (a limit
/// error would be the right outcome for the wrong reason) with a byte column on line 1.
fn judge_invalid(case: *const core.Map) Verdict {
    const selector = case.get("selector").?.string;
    var diag = Diagnostics.init(0, 0, "", null);
    switch (compile_class(selector, &diag)) {
        .ok, .limit => return .diverges,
        .unsupported => return .unsupported,
        .syntax => {},
    }
    if (diag.line != 1) return .diverges;
    if (diag.col < 1) return .diverges;
    return .pass;
}

/// Judges every test; `report` logs each unexpected divergence (an error-level log fails a
/// test, so the probe test passes false).
fn run_suite(
    gpa: std.mem.Allocator,
    tests: []const Value,
    pins: []const []const u8,
    report: bool,
) !Tally {
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
            .diverges => if (is_pinned(pins, name)) {
                tally.pinned += 1;
            } else {
                tally.diverging += 1;
                if (report) std.log.err("conformance: '{s}' [{s}] diverges", .{
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

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, suite_path, gpa, .limited(suite_bytes_max));
    defer gpa.free(bytes);

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, bytes, parse_options, &diag);
    const tests = root.map.get("tests").?.array;
    const tally = try run_suite(gpa, tests, &pinned_divergent, true);
    std.log.warn("conformance: {d} tests ({d} invalid, {d} valid): {d} pass, {d} unsupported, " ++
        "{d} pinned divergent, {d} unexpected", .{
        tests.len,       tally.invalid,     tally.valid,
        tally.pass,      tally.unsupported, tally.pinned,
        tally.diverging,
    });
    try expectEqual(suite_count, @as(u32, @intCast(tests.len)));
    try expectEqual(invalid_count, tally.invalid);
    try expectEqual(valid_count, tally.valid);
    try expectEqual(unsupported_count, tally.unsupported);
    try expectEqual(@as(u32, 0), tally.untagged);
    try expectEqual(@as(u32, 0), tally.diverging);
    try expectEqual(divergent_count, tally.pinned);
    try expectEqual(suite_count - unsupported_count - divergent_count, tally.pass);
}

const probe_cases =
    \\[{"name":"ok","selector":"$.a","document":{"a":1},"result":[1]},
    \\{"name":"wrong result","selector":"$.a","document":{"a":1},"result":[2]},
    \\{"name":"wrong count","selector":"$.*","document":{"a":1,"b":2},"result":[1]},
    \\{"name":"key order","selector":"$.a","document":{"a":{"x":1,"y":2}},"result":[{"y":2,"x":1}]},
    \\{"name":"alt hit","selector":"$.*","document":{"a":1,"b":2},"results":[[2,1],[1,2]]},
    \\{"name":"alt miss","selector":"$.*","document":{"a":1,"b":2},"results":[[2,1],[3]]},
    \\{"name":"rejected valid","selector":"$.","document":{"a":1},"result":[1]},
    \\{"name":"match","selector":"$[?match(@, 'a')]","document":["a"],"result":[],"tags":["match"]},
    \\{"name":"match untagged","selector":"$[?search(@, 'a')]","document":["a"],"result":["a"]},
    \\{"name":"valid but marked invalid","selector":"$.a","invalid_selector":true},
    \\{"name":"invalid","selector":"$.","invalid_selector":true},
    \\{"name":"unsupported invalid","selector":"$[?match(@)]","invalid_selector":true}]
;

test "conformance: the judges fail wrong expectations and the tally counts them" {
    const gpa = std.testing.allocator;
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    const items = (try dom.parse(&tree, probe_cases, parse_options, &diag)).array;
    const expected = [_]Verdict{
        .pass,     .diverges,    .diverges,    .pass,     .pass, .diverges,
        .diverges, .unsupported, .unsupported, .diverges, .pass, .unsupported,
    };
    try expectEqual(expected.len, items.len);
    for (items, expected) |*item, want| {
        const case = &item.map;
        const got = if (case.get("invalid_selector") != null)
            judge_invalid(case)
        else
            try judge_valid(gpa, case);
        try expectEqual(want, got);
    }
    const pins = [_][]const u8{ "wrong result", "no such test" };
    const tally = try run_suite(gpa, items, &pins, false);
    try expectEqual(@as(u32, 12), tally.invalid + tally.valid);
    try expectEqual(@as(u32, 2), tally.untagged);
    try expectEqual(@as(u32, 1), tally.pinned);
    try expectEqual(@as(u32, 4), tally.diverging);
}

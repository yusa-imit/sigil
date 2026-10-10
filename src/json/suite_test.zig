//! JSONTestSuite for `json/dom.zig` (plan 004 item 7): the MIT-licensed `test_parsing/` corpus
//! of Nicolas Seriot, vendored under `tests/json/` with its license. Every `y_` file must parse;
//! every `n_` file must fail with a typed error and a diagnostic at a real line:col (both
//! nonzero); every `i_` file (the suite leaves it to the implementation) is pinned in
//! `implementation_defined` so a change of behavior shows up as a failing test, not silently.
//! The corpus is read at run time through `std.testing.io`; the test step runs from the repo
//! root. A short corpus (a failed vendoring) fails the count checks, not a lucky pass.

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("dom.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

const corpus_path = "tests/json/test_parsing";
const file_bytes_max: usize = 1 << 20;
const file_count_max: usize = 1024;
/// `.last` is the JavaScript reading that the suite's `y_` duplicate-key files expect.
const parse_options: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .last };

/// Files in the vendored corpus, by prefix. A different count means the vendoring changed.
const accept_count: usize = 95;
const reject_count: usize = 188;
const either_count: usize = 35;

/// The `i_` files this parser parses: finite floats that underflow to zero (ADR 0003 section 2).
const pinned_accepted = [_][]const u8{
    "i_number_double_huge_neg_exp.json",
    "i_number_real_underflow.json",
};

/// The `i_` files this parser rejects: floats and integers out of range, lone or inverted
/// surrogates, invalid UTF-8, a BOM or UTF-16 text, and nesting past `depth_max`.
const pinned_rejected = [_][]const u8{
    "i_number_huge_exp.json",
    "i_number_neg_int_huge_exp.json",
    "i_number_pos_double_huge_exp.json",
    "i_number_real_neg_overflow.json",
    "i_number_real_pos_overflow.json",
    "i_number_too_big_neg_int.json",
    "i_number_too_big_pos_int.json",
    "i_number_very_big_negative_int.json",
    "i_object_key_lone_2nd_surrogate.json",
    "i_string_1st_surrogate_but_2nd_missing.json",
    "i_string_1st_valid_surrogate_2nd_invalid.json",
    "i_string_UTF-16LE_with_BOM.json",
    "i_string_UTF-8_invalid_sequence.json",
    "i_string_UTF8_surrogate_U+D800.json",
    "i_string_incomplete_surrogate_and_escape_valid.json",
    "i_string_incomplete_surrogate_pair.json",
    "i_string_incomplete_surrogates_escape_valid.json",
    "i_string_invalid_lonely_surrogate.json",
    "i_string_invalid_surrogate.json",
    "i_string_invalid_utf-8.json",
    "i_string_inverted_surrogates_U+1D11E.json",
    "i_string_iso_latin_1.json",
    "i_string_lone_second_surrogate.json",
    "i_string_lone_utf8_continuation_byte.json",
    "i_string_not_in_unicode_range.json",
    "i_string_overlong_sequence_2_bytes.json",
    "i_string_overlong_sequence_6_bytes.json",
    "i_string_overlong_sequence_6_bytes_null.json",
    "i_string_truncated-utf-8.json",
    "i_string_utf16BE_no_BOM.json",
    "i_string_utf16LE_no_BOM.json",
    "i_structure_500_nested_arrays.json",
    "i_structure_UTF-8_BOM_empty_object.json",
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// What this parser does with the `i_` file `name`, or `null` if it is not pinned.
fn pinned_outcome(name: []const u8) ?bool {
    if (contains(&pinned_accepted, name)) return true;
    if (contains(&pinned_rejected, name)) return false;
    return null;
}

/// How one file fared: the result of `dom.parse` and, on failure, its diagnostic.
const Outcome = struct { accepted: bool, line: u32, col: u32, message_len: usize };

fn parse_outcome(gpa: std.mem.Allocator, input: []const u8) !Outcome {
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    // proof: `ParseValueError` holds no I/O error, so `error.Canceled` cannot occur.
    _ = dom.parse(&tree, input, parse_options, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .accepted = false,
            .line = diag.line,
            .col = diag.col,
            .message_len = diag.message().len,
        },
    };
    return .{ .accepted = true, .line = 0, .col = 0, .message_len = 0 };
}

/// Returns the corpus file names, sorted, allocated from `arena`.
fn list_corpus(arena: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    for (0..file_count_max) |_| {
        const entry = try it.next(io) orelse break;
        if (entry.kind != .file) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, name_less);
    return names.items;
}

fn name_less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Tallies of the verdicts on one run, so one failing file does not hide the rest.
const Tally = struct { accept: usize = 0, reject: usize = 0, either: usize = 0, wrong: usize = 0 };

/// Judges `outcome` for the corpus file `name`; logs and counts a wrong verdict.
fn judge(tally: *Tally, name: []const u8, outcome: Outcome) void {
    const kind = name[0];
    const right = switch (kind) {
        'y' => outcome.accepted,
        'n' => !outcome.accepted and outcome.line >= 1 and outcome.col >= 1 and
            outcome.message_len > 0,
        'i' => if (pinned_outcome(name)) |accepted| accepted == outcome.accepted else false,
        else => false,
    };
    switch (kind) {
        'y' => tally.accept += 1,
        'n' => tally.reject += 1,
        'i' => tally.either += 1,
        else => {},
    }
    if (right) return;
    tally.wrong += 1;
    std.log.err("{s}: accepted={} at {d}:{d} (message {d} bytes)", .{
        name, outcome.accepted, outcome.line, outcome.col, outcome.message_len,
    });
}

test "suite: every y_ parses, every n_ fails at a position, every i_ is pinned" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const names = try list_corpus(arena, io);
    var dir = try std.Io.Dir.cwd().openDir(io, corpus_path, .{});
    defer dir.close(io);

    var tally: Tally = .{};
    for (names) |name| {
        const input = try dir.readFileAlloc(io, name, arena, .limited(file_bytes_max));
        judge(&tally, name, try parse_outcome(std.testing.allocator, input));
    }
    try expectEqual(@as(usize, 0), tally.wrong);
    try expectEqual(accept_count, tally.accept);
    try expectEqual(reject_count, tally.reject);
    try expectEqual(either_count, tally.either);
    try expectEqual(names.len, accept_count + reject_count + either_count);
}

test "suite: every pinned i_ file exists in the corpus" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const names = try list_corpus(arena_state.allocator(), io);
    for (pinned_accepted ++ pinned_rejected) |pin| try expect(contains(names, pin));
    try expectEqual(either_count, pinned_accepted.len + pinned_rejected.len);
}

test "suite: the y_ duplicate-key files are rejected under the reject policy" {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, corpus_path, .{});
    defer dir.close(io);

    const gpa = std.testing.allocator;
    const files = [_][]const u8{
        "y_object_duplicated_key.json",
        "y_object_duplicated_key_and_value.json",
    };
    for (files) |name| {
        const input = try dir.readFileAlloc(io, name, gpa, .limited(file_bytes_max));
        defer gpa.free(input);

        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();

        var diag = Diagnostics.init(0, 0, "", null);
        const reject: dom.ParseOptions = .{ .depth_max = 128, .duplicate_key = .reject };
        try std.testing.expectError(error.DuplicateKey, dom.parse(&tree, input, reject, &diag));
        try expectEqual(@as(u32, 1), diag.line);
    }
}

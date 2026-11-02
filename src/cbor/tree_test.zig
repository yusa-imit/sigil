//! Tests for `cbor/tree.zig` `parse_value` (plan 007 item 6): every value form, definite and
//! indefinite items, the ADR 0006 key, duplicate, tag and simple-value rules, depth, bomb rule,
//! every tree-level error variant with its position, and an allocation-failure sweep.

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
const tree_mod = @import("tree.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ParseOptions = decoder.ParseOptions;
const ParseValueError = decoder.ParseValueError;
const Value = core.Value;
const ValueTree = core.ValueTree;

const options_reject: ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const options_last: ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .last,
};

const sentinel_line: u32 = 777;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Parses `input` into `tree`, checks every map, and asserts success left `diag` untouched.
fn parse_with(tree: *ValueTree, input: []const u8, options: ParseOptions) !Value {
    var diag = fresh_diag();
    const value = try decoder.parse_value(tree, input, options, &diag);
    try expectEqual(sentinel_line, diag.line);
    check_maps(value);
    return value;
}

fn parse_ok(tree: *ValueTree, input: []const u8) !Value {
    return parse_with(tree, input, options_reject);
}

/// Expects `err` at byte `offset` (line 1, col offset + 1, message "byte N: ...").
fn expect_fail_with(
    input: []const u8,
    options: ParseOptions,
    err: ParseValueError,
    offset: u32,
) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    try expectError(err, decoder.parse_value(&tree, input, options, &diag));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(offset + 1, diag.col);
    var buffer: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buffer, "byte {d}: ", .{offset});
    try expect(std.mem.startsWith(u8, diag.message(), prefix));
}

fn expect_fail(input: []const u8, err: ParseValueError, offset: u32) !void {
    try expect_fail_with(input, options_reject, err, offset);
}

/// `check_invariants` on every map reachable from `root`, iteratively (no recursion).
fn check_maps(root: Value) void {
    var stack: [512]Value = undefined;
    var depth: u32 = 1;
    stack[0] = root;
    for (0..4096) |_| {
        if (depth == 0) return;
        depth -= 1;
        switch (stack[depth]) {
            .map => |map| {
                map.check_invariants();
                for (map.items()) |entry| {
                    stack[depth] = entry.value;
                    depth += 1;
                }
            },
            .array => |items| {
                for (items) |item| {
                    stack[depth] = item;
                    depth += 1;
                }
            },
            else => {},
        }
    }
    unreachable; // proof: the test documents are far smaller than the step bound.
}

fn field(value: Value, name: []const u8) !Value {
    try expect(value == .map);
    const found = value.map.get(name) orelse return error.TestMissingKey;
    return found.*;
}

/// `count` copies of `unit` followed by `tail`.
fn repeated(comptime unit: u8, comptime count: u32, comptime tail: []const u8) []const u8 {
    const joined = [_]u8{unit} ** count ++ tail[0..tail.len].*;
    return &joined;
}

// ---- Scalars and the integer normal form. ----

test "tree: null, bools and small integers" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expect((try parse_ok(&tree, "\xf6")) == .null);
    try expectEqual(false, (try parse_ok(&tree, "\xf4")).bool);
    try expectEqual(true, (try parse_ok(&tree, "\xf5")).bool);
    try expectEqual(@as(i64, 0), (try parse_ok(&tree, "\x00")).int);
    try expectEqual(@as(i64, 24), (try parse_ok(&tree, "\x18\x18")).int);
    try expectEqual(@as(i64, -1), (try parse_ok(&tree, "\x20")).int);
    try expectEqual(@as(i64, -1000), (try parse_ok(&tree, "\x39\x03\xe7")).int);
}

test "tree: a non-shortest head still normalizes to int" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\x18\x05")).int);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\x1b\x00\x00\x00\x00\x00\x00\x00\x05")).int);
}

test "tree: maxInt(i64) is int, maxInt(i64) + 1 and maxInt(u64) are uint" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const top = try parse_ok(&tree, "\x1b\x7f\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(i64), top.int);
    const above = try parse_ok(&tree, "\x1b\x80\x00\x00\x00\x00\x00\x00\x00");
    try expectEqual(@as(u64, 1) << 63, above.uint);
    const biggest = try parse_ok(&tree, "\x1b\xff\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(u64), biggest.uint);
    const low = try parse_ok(&tree, "\x3b\x7f\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.minInt(i64), low.int);
}

test "tree: half, single and double floats" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(f64, 1.5), (try parse_ok(&tree, "\xf9\x3e\x00")).float);
    try expectEqual(@as(f64, 100000.0), (try parse_ok(&tree, "\xfa\x47\xc3\x50\x00")).float);
    const double = try parse_ok(&tree, "\xfb\x3f\xf1\x99\x99\x99\x99\x99\x9a");
    try expectEqual(@as(f64, 1.1), double.float);
    try expect(std.math.isNan((try parse_ok(&tree, "\xf9\x7e\x00")).float));
}

test "tree: strings and byte strings are copies" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var input = [_]u8{ 0x63, 'a', 'b', 'c' };
    const text = try parse_ok(&tree, &input);
    input[1] = 'X';
    try expectEqualStrings("abc", text.string);
    const empty = try parse_ok(&tree, "\x60");
    try expectEqual(@as(usize, 0), empty.string.len);
    const data = try parse_ok(&tree, "\x44\x01\x02\x03\x04");
    try expectEqualStrings("\x01\x02\x03\x04", data.bytes);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x40")).bytes.len);
}

// ---- Containers, definite and indefinite. ----

test "tree: nested definite arrays and maps" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const nested = try parse_ok(&tree, "\x83\x01\x82\x02\x03\x82\x04\x05");
    try expectEqual(@as(usize, 3), nested.array.len);
    try expectEqual(@as(i64, 3), nested.array[1].array[1].int);
    try expectEqual(@as(i64, 5), nested.array[2].array[1].int);

    const map = try parse_ok(&tree, "\xa2\x61a\x01\x61b\x82\x02\x03");
    try expectEqual(@as(i64, 1), (try field(map, "a")).int);
    try expectEqual(@as(i64, 3), (try field(map, "b")).array[1].int);

    const mixed = try parse_ok(&tree, "\x82\x61a\xa1\x61b\x61c");
    try expectEqualStrings("c", (try field(mixed.array[1], "b")).string);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x80")).array.len);
    try expectEqual(@as(u32, 0), (try parse_ok(&tree, "\xa0")).map.count);
}

test "tree: indefinite arrays and maps, empty and nested" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const flat = try parse_ok(&tree, "\x9f\x01\x02\x03\xff");
    try expectEqual(@as(usize, 3), flat.array.len);
    try expectEqual(@as(i64, 3), flat.array[2].int);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x9f\xff")).array.len);
    try expectEqual(@as(u32, 0), (try parse_ok(&tree, "\xbf\xff")).map.count);

    // Appendix A: (_ 1, [2, 3], [_ 4, 5]) and an indefinite map {"Fun": true, "Amt": -2}.
    const mixed = try parse_ok(&tree, "\x9f\x01\x82\x02\x03\x9f\x04\x05\xff\xff");
    try expectEqual(@as(usize, 3), mixed.array.len);
    try expectEqual(@as(i64, 5), mixed.array[2].array[1].int);
    const map = try parse_ok(&tree, "\xbf\x63Fun\xf5\x63Amt\x21\xff");
    try expectEqual(true, (try field(map, "Fun")).bool);
    try expectEqual(@as(i64, -2), (try field(map, "Amt")).int);
}

test "tree: indefinite counts are matched in open order" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    // [_ [_ 1], [_ 2, 3], [_], {_ "k": [_ 4, 5, 6]}]
    const input = "\x9f\x9f\x01\xff\x9f\x02\x03\xff\x9f\xff\xbf\x61k\x9f\x04\x05\x06\xff\xff\xff";
    const root = try parse_ok(&tree, input);
    try expectEqual(@as(usize, 4), root.array.len);
    try expectEqual(@as(usize, 1), root.array[0].array.len);
    try expectEqual(@as(usize, 2), root.array[1].array.len);
    try expectEqual(@as(usize, 0), root.array[2].array.len);
    try expectEqual(@as(usize, 3), (try field(root.array[3], "k")).array.len);
}

test "tree: indefinite byte and text strings concatenate their chunks" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const bytes = try parse_ok(&tree, "\x5f\x42\x01\x02\x43\x03\x04\x05\xff");
    try expectEqualStrings("\x01\x02\x03\x04\x05", bytes.bytes);
    const text = try parse_ok(&tree, "\x7f\x65strea\x64ming\xff");
    try expectEqualStrings("streaming", text.string);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x5f\xff")).bytes.len);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x7f\xff")).string.len);
    const in_array = try parse_ok(&tree, "\x82\x7f\x61a\x61b\xff\x5f\x41\x07\xff");
    try expectEqualStrings("ab", in_array.array[0].string);
    try expectEqualStrings("\x07", in_array.array[1].bytes);
}

test "tree: an indefinite text string is a valid map key" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const map = try parse_ok(&tree, "\xbf\x7f\x61a\x61b\xff\x01\xff");
    try expectEqual(@as(i64, 1), (try field(map, "ab")).int);
    const definite = try parse_ok(&tree, "\xa1\x7f\x61x\xff\x02");
    try expectEqual(@as(i64, 2), (try field(definite, "x")).int);
}

// ---- Tags. ----

/// `tag_head` followed by a definite text string holding `text` (at most 255 bytes).
fn tagged_text(comptime tag_head: []const u8, comptime text: []const u8) []const u8 {
    const head: []const u8 = if (text.len < 24) &.{0x60 + text.len} else &.{ 0x78, text.len };
    return tag_head ++ head ++ text;
}

test "tree: tag 0 keeps the written offset, at the +-23:59 extremes" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const utc = (try parse_ok(&tree, tagged_text("\xc0", "2013-03-21T20:04:00Z"))).timestamp;
    try expectEqual(core.Timestamp.Kind.instant, utc.kind);
    try expectEqual(@as(i64, 1363896240), utc.seconds);
    try expectEqual(@as(u32, 0), utc.nanoseconds);

    const east = tagged_text("\xc0", "1970-01-01T00:00:00+23:59");
    const east_stamp = (try parse_ok(&tree, east)).timestamp;
    try expectEqual(@as(?i16, 1439), east_stamp.offset_minutes);
    try expectEqual(@as(i64, -86340), east_stamp.seconds);

    const west = tagged_text("\xc0", "1970-01-01T00:00:00-23:59");
    const west_stamp = (try parse_ok(&tree, west)).timestamp;
    try expectEqual(@as(?i16, -1439), west_stamp.offset_minutes);
    try expectEqual(@as(i64, 86340), west_stamp.seconds);

    const fraction = tagged_text("\xc0", "2013-03-21T20:04:00.5Z");
    try expectEqual(@as(u32, 500_000_000), (try parse_ok(&tree, fraction)).timestamp.nanoseconds);
}

test "tree: tag 0 over an indefinite text string" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const chunks = "\xc0\x7f\x6b2013-03-21T\x6820:04:00\x61Z\xff";
    const stamp = (try parse_ok(&tree, chunks)).timestamp;
    try expectEqual(@as(i64, 1363896240), stamp.seconds);
}

test "tree: tag 0 refuses a local datetime, a bad calendar field and a non-text content" {
    try expect_fail(tagged_text("\xc0", "2013-03-21T20:04:00"), error.InvalidTimestamp, 0);
    try expect_fail(tagged_text("\xc0", "2013-02-30T20:04:00Z"), error.InvalidTimestamp, 0);
    try expect_fail(tagged_text("\xc0", "not a time"), error.InvalidTimestamp, 0);
    try expect_fail("\xc0\x01", error.InvalidTimestamp, 0);
    try expect_fail("\x81\xc0\x41\x01", error.InvalidTimestamp, 1);
    try expect_fail("\xc0\xf6", error.InvalidTimestamp, 0);
}

test "tree: tag 1 with an integer" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const stamp = (try parse_ok(&tree, "\xc1\x1a\x51\x4b\x67\xb0")).timestamp;
    try expectEqual(core.Timestamp.Kind.instant, stamp.kind);
    try expectEqual(@as(i64, 1363896240), stamp.seconds);
    try expectEqual(@as(u32, 0), stamp.nanoseconds);
    try expectEqual(@as(?i16, null), stamp.offset_minutes);
    try expectEqual(@as(i64, -1), (try parse_ok(&tree, "\xc1\x20")).timestamp.seconds);
}

test "tree: tag 1 with a float splits seconds and rounds nanoseconds half to even" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    // Appendix A: 1(1363896240.5).
    const half = (try parse_ok(&tree, "\xc1\xfb\x41\xd4\x52\xd9\xec\x20\x00\x00")).timestamp;
    try expectEqual(@as(i64, 1363896240), half.seconds);
    try expectEqual(@as(u32, 500_000_000), half.nanoseconds);
    // -1.5 is floor -2 plus 0.5.
    const negative = (try parse_ok(&tree, "\xc1\xf9\xbe\x00")).timestamp;
    try expectEqual(@as(i64, -2), negative.seconds);
    try expectEqual(@as(u32, 500_000_000), negative.nanoseconds);
    // A whole float has no fraction.
    const whole = (try parse_ok(&tree, "\xc1\xf9\x3c\x00")).timestamp;
    try expectEqual(@as(i64, 1), whole.seconds);
    try expectEqual(@as(u32, 0), whole.nanoseconds);
}

test "tree: float to timestamp rounding, carry and range" {
    const one_ns = try tree_mod.timestamp_from_float(1.000000001);
    try expectEqual(@as(i64, 1), one_ns.seconds);
    try expectEqual(@as(u32, 1), one_ns.nanoseconds);
    // 0.9999999999999999 rounds up to a full second: carry into seconds.
    const carried = try tree_mod.timestamp_from_float(0.9999999999999999);
    try expectEqual(@as(i64, 1), carried.seconds);
    try expectEqual(@as(u32, 0), carried.nanoseconds);
    // 1/1024 s is 976562.5 ns exactly and 3/1024 s is 2929687.5 ns: both tie, to the even one.
    const tie_down = try tree_mod.timestamp_from_float(1.0 + 1.0 / 1024.0);
    try expectEqual(@as(u32, 976_562), tie_down.nanoseconds);
    const tie_up = try tree_mod.timestamp_from_float(1.0 + 3.0 / 1024.0);
    try expectEqual(@as(u32, 2_929_688), tie_up.nanoseconds);
    const min = try tree_mod.timestamp_from_float(-9223372036854775808.0);
    try expectEqual(std.math.minInt(i64), min.seconds);
    try expectError(error.InvalidTimestamp, tree_mod.timestamp_from_float(9223372036854775808.0));
    try expectError(error.InvalidTimestamp, tree_mod.timestamp_from_float(std.math.inf(f64)));
    try expectError(error.InvalidTimestamp, tree_mod.timestamp_from_float(std.math.nan(f64)));
}

test "tree: tag 1 refuses non-finite, out of range, uint above i64 and wrong types" {
    try expect_fail("\xc1\xf9\x7c\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\xf9\xfc\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\xf9\x7e\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\xfb\x44\x15\xaf\x1d\x78\xb5\x8c\x40", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\x1b\xff\xff\xff\xff\xff\xff\xff\xff", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\x61a", error.InvalidTimestamp, 0);
    try expect_fail("\xc1\xf5", error.InvalidTimestamp, 0);
}

test "tree: tags 2 and 3 produce int or uint by the normal form" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const max = try parse_ok(&tree, "\xc2\x48\xff\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(u64), max.uint);
    const padded = try parse_ok(&tree, "\xc2\x4a\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(u64), padded.uint);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xc2\x41\x05")).int);
    try expectEqual(@as(i64, 0), (try parse_ok(&tree, "\xc2\x40")).int);
    try expectEqual(@as(i64, 258), (try parse_ok(&tree, "\xc2\x5f\x41\x01\x41\x02\xff")).int);
    const low = try parse_ok(&tree, "\xc3\x48\x7f\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.minInt(i64), low.int);
    try expectEqual(@as(i64, -1), (try parse_ok(&tree, "\xc3\x40")).int);
    try expectEqual(@as(i64, -257), (try parse_ok(&tree, "\xc3\x42\x01\x00")).int);
}

test "tree: bignums past 64 bits and below minInt(i64) are refused" {
    // 2^64 is nine bytes; -2^64 is tag 3 with n = 2^64 - 1; both beyond the supported range.
    try expect_fail("\xc2\x49\x01\x00\x00\x00\x00\x00\x00\x00\x00", error.IntegerAboveMax, 0);
    try expect_fail("\xc3\x49\x01\x00\x00\x00\x00\x00\x00\x00\x00", error.IntegerBelowMin, 0);
    try expect_fail("\xc3\x48\xff\xff\xff\xff\xff\xff\xff\xff", error.IntegerBelowMin, 0);
    try expect_fail("\xc3\x48\x80\x00\x00\x00\x00\x00\x00\x00", error.IntegerBelowMin, 0);
}

test "tree: tags 2 and 3 over a non byte string, and nested tags, are InvalidTag" {
    try expect_fail("\xc2\x01", error.InvalidTag, 0);
    try expect_fail("\xc3\x61a", error.InvalidTag, 0);
    try expect_fail("\xc2\x80", error.InvalidTag, 0);
    try expect_fail("\xc2\xc2\x41\x01", error.InvalidTag, 0);
    try expect_fail("\x82\x01\xc3\xf6", error.InvalidTag, 2);
}

test "tree: other tags are UnsupportedTag at the tag head, content undecoded" {
    try expect_fail("\xc4\x82\x21\x19\x6a\xb3", error.UnsupportedTag, 0);
    try expect_fail("\xd8\x64\x01", error.UnsupportedTag, 0);
    try expect_fail("\x82\x01\xc6\x01", error.UnsupportedTag, 2);
    try expect_fail("\xdb\xff\xff\xff\xff\xff\xff\xff\xff\x00", error.UnsupportedTag, 0);
}

test "tree: a tag is a level; 128 pass and 129 are TooDeep" {
    try expect_fail(repeated(0xc6, 128, "\x00"), error.UnsupportedTag, 0);
    try expect_fail(repeated(0xc6, 129, "\x00"), error.TooDeep, 128);
}

// ---- Simple values. ----

test "tree: undefined and other simple values are UnsupportedSimple" {
    try expect_fail("\xf7", error.UnsupportedSimple, 0);
    try expect_fail("\xf0", error.UnsupportedSimple, 0);
    try expect_fail("\xf8\x20", error.UnsupportedSimple, 0);
    try expect_fail("\xf8\xff", error.UnsupportedSimple, 0);
    try expect_fail("\x83\x01\x02\xf7", error.UnsupportedSimple, 3);
    try expect_fail("\xc0\xf7", error.UnsupportedSimple, 1);
}

// ---- Keys and duplicates. ----

test "tree: a non-string key is NonStringKey at the key's first byte" {
    try expect_fail("\xa1\x01\x01", error.NonStringKey, 1);
    try expect_fail("\xa1\x41a\x01", error.NonStringKey, 1);
    try expect_fail("\xa1\xc1\x01\x01", error.NonStringKey, 1);
    try expect_fail("\xa1\x80\x01", error.NonStringKey, 1);
    try expect_fail("\xa1\xf6\x01", error.NonStringKey, 1);
    try expect_fail("\xa1\x5f\x41a\xff\x01", error.NonStringKey, 1);
    try expect_fail("\xbf\x61a\x01\xa0\x01\xff", error.NonStringKey, 4);
}

test "tree: a duplicate key is rejected at the second key, or the last value wins" {
    try expect_fail("\xa2\x61a\x01\x61a\x02", error.DuplicateKey, 4);
    try expect_fail("\xbf\x61a\x01\x61a\x02\xff", error.DuplicateKey, 4);
    try expect_fail("\xa2\x61a\x01\x7f\x61a\xff\x02", error.DuplicateKey, 4);

    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const map = try parse_with(&tree, "\xa3\x61a\x01\x61b\x02\x61a\x03", options_last);
    try expectEqual(@as(u32, 2), map.map.count);
    try expectEqual(@as(i64, 3), (try field(map, "a")).int);
    try expectEqual(@as(i64, 2), (try field(map, "b")).int);
    try expectEqualStrings("a", map.map.items()[0].key);
    const indef = try parse_with(&tree, "\xbf\x61a\x01\x61a\x02\xff", options_last);
    try expectEqual(@as(u32, 1), indef.map.count);
    try expectEqual(@as(i64, 2), (try field(indef, "a")).int);
}

// ---- Depth, size, bomb rule and framing errors. ----

test "tree: 128 nested arrays pass and 129 are TooDeep at the head that opens level 129" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const ok = try parse_ok(&tree, repeated(0x81, 127, "\x80"));
    try expect(ok == .array);
    try expect_fail(repeated(0x81, 128, "\x80"), error.TooDeep, 128);
    try expect_fail(repeated(0x9f, 129, ""), error.TooDeep, 128);
}

test "tree: depth_max is honoured below the hard limit" {
    const shallow: ParseOptions = .{ .depth_max = 2, .bytes_max = 64, .duplicate_key = .reject };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try parse_with(&tree, "\x81\x80", shallow);
    try expect_fail_with("\x81\x81\x80", shallow, error.TooDeep, 2);
}

test "tree: input longer than bytes_max is InputTooLarge before any byte is read" {
    const small: ParseOptions = .{ .depth_max = 128, .bytes_max = 3, .duplicate_key = .reject };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const input = "\x83\x01\x02\x03";
    try expectError(error.InputTooLarge, decoder.parse_value(&tree, input, small, &diag));
    try expectEqual(core.diagnostics.position_none, diag.line);
    _ = try parse_with(&tree, "\x82\x01\x02", small);
}

test "tree: a huge declared count is refused before anything is allocated" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const bomb_array = "\x9b\x00\x00\x00\x00\xff\xff\xff\xff";
    const parsed_array = decoder.parse_value(&tree, bomb_array, options_reject, &diag);
    try expectError(error.UnexpectedEnd, parsed_array);
    try expectEqual(@as(usize, 0), tree.arena.queryCapacity());
    const bomb_map = "\xba\xff\xff\xff\xff\x01\x02";
    const parsed_map = decoder.parse_value(&tree, bomb_map, options_reject, &diag);
    try expectError(error.UnexpectedEnd, parsed_map);
    const bomb_text = "\x7b\xff\xff\xff\xff\xff\xff\xff\xffab";
    const parsed_text = decoder.parse_value(&tree, bomb_text, options_reject, &diag);
    try expectError(error.UnexpectedEnd, parsed_text);
    try expectEqual(@as(usize, 0), tree.arena.queryCapacity());
}

test "tree: empty input, trailing bytes and truncation" {
    try expect_fail("", error.UnexpectedEnd, 0);
    try expect_fail("\x01\x02", error.TrailingBytes, 1);
    try expect_fail("\x82\x01\x02\x03", error.TrailingBytes, 3);
    try expect_fail("\x9f\xff\xff", error.TrailingBytes, 2);
    try expect_fail("\x9f\x01", error.UnexpectedEnd, 0);
    try expect_fail("\x82\x01\x9f\x02", error.UnexpectedEnd, 2);
    try expect_fail("\xc0", error.UnexpectedEnd, 0);
    try expect_fail("\x5f\x41\x01", error.UnexpectedEnd, 0);
}

test "tree: reader errors reach the caller with their own positions" {
    try expect_fail("\x9f\x01\xa0\xff\xff", error.TrailingBytes, 4);
    try expect_fail("\x82\xff\x01", error.UnexpectedBreak, 1);
    try expect_fail("\xbf\x61a\xff", error.InvalidIndefinite, 3);
    try expect_fail("\x62\xc3\x28", error.InvalidUtf8, 0);
    try expect_fail("\x1c", error.NotWellFormed, 0);
    try expect_fail("\x3b\x80\x00\x00\x00\x00\x00\x00\x00", error.IntegerBelowMin, 0);
}

test "tree: every prefix of a mixed document is a typed error with an offset" {
    const document = "\xbf\x61a\x9f\x01\x02\xff\x61b\xc1\x1a\x51\x4b\x67\xb0\x61c\x7f\x61x\xff\xff";
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try parse_ok(&tree, document);
    for (0..document.len) |len| {
        var prefix_tree: ValueTree = undefined;
        prefix_tree.init(std.testing.allocator);
        defer prefix_tree.deinit();

        var diag = fresh_diag();
        const result = decoder.parse_value(&prefix_tree, document[0..len], options_reject, &diag);
        try expectError(error.UnexpectedEnd, result);
        try expectEqual(@as(u32, 1), diag.line);
    }
}

test "tree: the variant set is pinned at 17" {
    const variants = @typeInfo(ParseValueError).error_set.?;
    try expectEqual(@as(usize, 17), variants.len);
}

test "tree: one tree holds several documents" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try parse_ok(&tree, "\x9f\x01\xff");
    const second = try parse_ok(&tree, "\xbf\x61k\x02\xff");
    try expectEqual(@as(i64, 1), first.array[0].int);
    try expectEqual(@as(i64, 2), (try field(second, "k")).int);
    try expect(tree.root == .null);
}

test "tree: an allocation failure at every point is OutOfMemory and frees everything" {
    const document = "\xbf\x61a\x9f\x01\x7f\x61x\x61y\xff\xff\x61b\xc2\x42\x01\x02\xff";
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();

        var diag = fresh_diag();
        const result = decoder.parse_value(&tree, document, options_reject, &diag);
        if (result) |value| {
            check_maps(value);
            break;
        } else |err| {
            try expectEqual(error.OutOfMemory, err);
            try expectEqual(@as(u32, 1), diag.line);
        }
    } else return error.TestSweepTooShort;
}

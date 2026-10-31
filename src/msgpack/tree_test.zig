//! Tests for `msgpack/decoder.zig` `parse_value` (plan 007 item 3): every value form, the ADR
//! 0006 key, duplicate, ext and timestamp rules, depth, bomb rule, every error variant with its
//! position, prefix truncation, and an allocation-failure sweep.

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
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

// ---- Scalars and the integer normal form. ----

test "tree: nil, bools and fixints" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expect((try parse_ok(&tree, "\xc0")) == .null);
    try expectEqual(false, (try parse_ok(&tree, "\xc2")).bool);
    try expectEqual(true, (try parse_ok(&tree, "\xc3")).bool);
    try expectEqual(@as(i64, 0), (try parse_ok(&tree, "\x00")).int);
    try expectEqual(@as(i64, 127), (try parse_ok(&tree, "\x7f")).int);
    try expectEqual(@as(i64, -1), (try parse_ok(&tree, "\xff")).int);
    try expectEqual(@as(i64, -32), (try parse_ok(&tree, "\xe0")).int);
}

test "tree: the head width of a small unsigned integer is not kept" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xcc\x05")).int);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xcd\x00\x05")).int);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xce\x00\x00\x00\x05")).int);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xcf\x00\x00\x00\x00\x00\x00\x00\x05")).int);
    try expectEqual(@as(i64, 5), (try parse_ok(&tree, "\xd3\x00\x00\x00\x00\x00\x00\x00\x05")).int);
    try expectEqual(@as(i64, -5), (try parse_ok(&tree, "\xd0\xfb")).int);
}

test "tree: maxInt(i64) is int, maxInt(i64) + 1 and maxInt(u64) are uint" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const at_max = try parse_ok(&tree, "\xcf\x7f\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(i64), at_max.int);
    const above = try parse_ok(&tree, "\xcf\x80\x00\x00\x00\x00\x00\x00\x00");
    try expectEqual(@as(u64, 1) << 63, above.uint);
    const top = try parse_ok(&tree, "\xcf\xff\xff\xff\xff\xff\xff\xff\xff");
    try expectEqual(std.math.maxInt(u64), top.uint);
    const low = try parse_ok(&tree, "\xd3\x80\x00\x00\x00\x00\x00\x00\x00");
    try expectEqual(std.math.minInt(i64), low.int);
}

test "tree: floats keep their bits" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(f64, 1.5), (try parse_ok(&tree, "\xca\x3f\xc0\x00\x00")).float);
    const wide = try parse_ok(&tree, "\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00");
    try expectEqual(@as(f64, 1.5), wide.float);
    const negative_zero = try parse_ok(&tree, "\xca\x80\x00\x00\x00");
    try expectEqual(@as(u64, 1) << 63, @as(u64, @bitCast(negative_zero.float)));
}

// ---- Strings, bytes, containers. ----

test "tree: str and bin are copies, bin is bytes" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const input = try std.testing.allocator.dupe(u8, "\xa3abc");
    defer std.testing.allocator.free(input);
    const text = try parse_ok(&tree, input);
    @memset(input, 'z');
    try expectEqualStrings("abc", text.string);

    const data = try parse_ok(&tree, "\xc4\x03\x00\xff\x01");
    try expectEqualStrings("\x00\xff\x01", data.bytes);
    try expectEqualStrings("", (try parse_ok(&tree, "\xa0")).string);
    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\xc4\x00")).bytes.len);
}

test "tree: empty containers, nesting and wire order" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(@as(usize, 0), (try parse_ok(&tree, "\x90")).array.len);
    try expectEqual(@as(u32, 0), (try parse_ok(&tree, "\x80")).map.count);
    const nested = try parse_ok(&tree, "\x92\x90\x91\x80");
    try expectEqual(@as(usize, 2), nested.array.len);
    try expectEqual(@as(usize, 0), nested.array[0].array.len);
    try expectEqual(@as(u32, 0), nested.array[1].array[0].map.count);

    const doc = "\x83\xa1z\x01\xa1a\x92\x02\xc3\xa1m\xa1x";
    const map = try parse_ok(&tree, doc);
    try expectEqual(@as(u32, 3), map.map.count);
    const keys = [_][]const u8{ "z", "a", "m" };
    for (keys, map.map.items()) |key, entry| try expectEqualStrings(key, entry.key);
    try expectEqual(@as(i64, 1), (try field(map, "z")).int);
    try expectEqual(true, (try field(map, "a")).array[1].bool);
    try expectEqualStrings("x", (try field(map, "m")).string);
}

test "tree: array16, array32, map16 and str forms" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const array16 = try parse_ok(&tree, "\xdc\x00\x02\x01\x02");
    try expectEqual(@as(usize, 2), array16.array.len);
    const array32 = try parse_ok(&tree, "\xdd\x00\x00\x00\x01\xc0");
    try expect(array32.array[0] == .null);
    const map16 = try parse_ok(&tree, "\xde\x00\x01\xa1k\x07");
    try expectEqual(@as(i64, 7), (try field(map16, "k")).int);
    const str8 = try parse_ok(&tree, "\xd9\x02hi");
    try expectEqualStrings("hi", str8.string);
}

// ---- Duplicate keys. ----

test "tree: duplicate key under reject is DuplicateKey at the second key" {
    try expect_fail("\x82\xa1a\x01\xa1a\x02", error.DuplicateKey, 4);
    try expect_fail("\x81\xa1o\x82\xa1a\x01\xa1a\x02", error.DuplicateKey, 7);
}

test "tree: duplicate key under last overwrites the first slot" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const input = "\x83\xa1a\x01\xa1b\x02\xa1a\x93\x01\x02\x03";
    const map = try parse_with(&tree, input, options_last);
    try expectEqual(@as(u32, 2), map.map.count);
    try expectEqual(@as(usize, 3), map.map.entries.len);
    try expectEqualStrings("a", map.map.items()[0].key);
    try expectEqual(@as(usize, 3), (try field(map, "a")).array.len);
    try expectEqual(@as(i64, 2), (try field(map, "b")).int);
}

// ---- Non-string keys. ----

test "tree: a key that is not str is NonStringKey at its head" {
    try expect_fail("\x81\x01\x02", error.NonStringKey, 1);
    try expect_fail("\x81\xc0\xc0", error.NonStringKey, 1);
    try expect_fail("\x81\xc4\x01a\xc0", error.NonStringKey, 1);
    try expect_fail("\x81\x90\xc0", error.NonStringKey, 1);
    try expect_fail("\x81\x80\xc0", error.NonStringKey, 1);
    try expect_fail("\x81\xd6\xff\x00\x00\x00\x01\xc0", error.NonStringKey, 1);
    try expect_fail("\x82\xa1a\x01\x03\x04", error.NonStringKey, 4);
    try expect_fail("\x91\x81\xcb\x00\x00\x00\x00\x00\x00\x00\x00\xc0", error.NonStringKey, 2);
}

// ---- Timestamps. ----

fn expect_stamp(input: []const u8, seconds: i64, nanoseconds: u32) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const stamp = (try parse_ok(&tree, input)).timestamp;
    try expectEqual(core.Timestamp.Kind.instant, stamp.kind);
    try expectEqual(seconds, stamp.seconds);
    try expectEqual(nanoseconds, stamp.nanoseconds);
    try expect(stamp.offset_minutes == null);
}

test "tree: timestamp 32, 64 and 96 forms" {
    try expect_stamp("\xd6\xff\x00\x00\x00\x00", 0, 0);
    try expect_stamp("\xd6\xff\xff\xff\xff\xff", 4_294_967_295, 0);
    try expect_stamp("\xd6\xff\x00\x00\x00\x01", 1, 0);

    var wire: [10]u8 = undefined;
    wire[0] = 0xd7;
    wire[1] = 0xff;
    const bits = (@as(u64, 500_000_000) << 34) | 5;
    std.mem.writeInt(u64, wire[2..10], bits, .big);
    try expect_stamp(&wire, 5, 500_000_000);
    const max_bits = (@as(u64, 999_999_999) << 34) | ((@as(u64, 1) << 34) - 1);
    std.mem.writeInt(u64, wire[2..10], max_bits, .big);
    try expect_stamp(&wire, 17_179_869_183, 999_999_999);

    var long: [15]u8 = undefined;
    long[0] = 0xc7;
    long[1] = 0x0c;
    long[2] = 0xff;
    std.mem.writeInt(u32, long[3..7], 123_456_789, .big);
    std.mem.writeInt(i64, long[7..15], -1, .big);
    try expect_stamp(&long, -1, 123_456_789);
    std.mem.writeInt(i64, long[7..15], std.math.minInt(i64), .big);
    try expect_stamp(&long, std.math.minInt(i64), 123_456_789);
}

test "tree: a timestamp is a value anywhere" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const map = try parse_ok(&tree, "\x81\xa1t\xd6\xff\x00\x00\x00\x09");
    try expectEqual(@as(i64, 9), (try field(map, "t")).timestamp.seconds);
    const array = try parse_ok(&tree, "\x91\xd6\xff\x00\x00\x00\x09");
    try expectEqual(@as(i64, 9), array.array[0].timestamp.seconds);
}

test "tree: ext other than -1 is UnsupportedExt at its head" {
    try expect_fail("\xd4\x05\x00", error.UnsupportedExt, 0);
    try expect_fail("\xd4\x00\x00", error.UnsupportedExt, 0);
    try expect_fail("\xd4\x7f\x00", error.UnsupportedExt, 0);
    try expect_fail("\xd4\x80\x00", error.UnsupportedExt, 0);
    try expect_fail("\xc7\x00\x01", error.UnsupportedExt, 0);
    try expect_fail("\x92\x01\xd5\x02\x00\x00", error.UnsupportedExt, 2);
}

test "tree: a malformed timestamp is InvalidTimestamp at its head" {
    // Lengths 0, 1, 2, 3, 16 are not timestamp forms.
    try expect_fail("\xc7\x00\xff", error.InvalidTimestamp, 0);
    try expect_fail("\xd4\xff\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xd5\xff\x00\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xc7\x03\xff\x00\x00\x00", error.InvalidTimestamp, 0);
    try expect_fail("\xd8\xff" ++ "\x00" ** 16, error.InvalidTimestamp, 0);

    var wire: [10]u8 = undefined;
    wire[0] = 0xd7;
    wire[1] = 0xff;
    std.mem.writeInt(u64, wire[2..10], @as(u64, 1_000_000_000) << 34, .big);
    try expect_fail(&wire, error.InvalidTimestamp, 0);
    std.mem.writeInt(u64, wire[2..10], std.math.maxInt(u64), .big);
    try expect_fail(&wire, error.InvalidTimestamp, 0);

    var long: [15]u8 = undefined;
    long[0] = 0xc7;
    long[1] = 0x0c;
    long[2] = 0xff;
    std.mem.writeInt(u32, long[3..7], 1_000_000_000, .big);
    std.mem.writeInt(i64, long[7..15], 0, .big);
    try expect_fail(&long, error.InvalidTimestamp, 0);
    std.mem.writeInt(u32, long[3..7], 999_999_999, .big);
    try expect_stamp(&long, 0, 999_999_999);
}

// ---- Depth. ----

test "tree: depth 128 passes and 129 is TooDeep at the head that opens level 129" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const deep_ok = "\x91" ** 127 ++ "\x90";
    var value = try parse_ok(&tree, deep_ok);
    var levels: u32 = 1;
    while (value == .array and value.array.len == 1) : (levels += 1) value = value.array[0];
    try expectEqual(@as(u32, 128), levels);
    try expectEqual(@as(usize, 0), value.array.len);

    try expect_fail("\x91" ** 128 ++ "\x90", error.TooDeep, 128);
    try expect_fail("\x81\xa1k" ** 128 ++ "\x80", error.TooDeep, 384);
}

test "tree: depth_max bounds the levels, the root included" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const one: ParseOptions = .{ .depth_max = 1, .bytes_max = 64, .duplicate_key = .reject };
    try expect((try parse_with(&tree, "\xc0", one)) == .null);
    try expectEqual(@as(usize, 1), (try parse_with(&tree, "\x91\xc0", one)).array.len);
    try expect_fail_with("\x91\x90", one, error.TooDeep, 1);
    try expect_fail_with("\x91\x80", one, error.TooDeep, 1);
    const two: ParseOptions = .{ .depth_max = 2, .bytes_max = 64, .duplicate_key = .reject };
    try expect_fail_with("\x91\x91\x90", two, error.TooDeep, 2);
}

// ---- Truncation, trailing bytes, bomb rule, size limit. ----

test "tree: empty input and input ending inside a container are UnexpectedEnd" {
    try expect_fail("", error.UnexpectedEnd, 0);
    try expect_fail("\x92\x92\x01\x01", error.UnexpectedEnd, 0);
    try expect_fail("\x81\xa1a", error.UnexpectedEnd, 0);
    try expect_fail("\x92\x91\x01", error.UnexpectedEnd, 0);
    // The innermost open container names the failure: the `\x92` at offset 1.
    try expect_fail("\x93\x92\x91\x01", error.UnexpectedEnd, 1);
    // The bomb rule fires first when the count cannot fit: the head at offset 2.
    try expect_fail("\x92\x01\x92\x01", error.UnexpectedEnd, 2);
}

test "tree: every proper prefix of a document is UnexpectedEnd" {
    const doc = "\x85\xa1a\x93\x01\xcd\x01\x00\xa2hi\xa1b\xc4\x02\x00\x01" ++
        "\xa1c\xd6\xff\x00\x00\x00\x01" ++
        "\xa1d\x82\xa1x\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00\xa1y\x90\xa1e\xc3";
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    _ = try parse_ok(&tree, doc);

    for (0..doc.len) |len| {
        var scratch: ValueTree = undefined;
        scratch.init(std.testing.allocator);
        defer scratch.deinit();
        var diag = fresh_diag();
        const result = decoder.parse_value(&scratch, doc[0..len], options_reject, &diag);
        try expectError(error.UnexpectedEnd, result);
        try expectEqual(@as(u32, 1), diag.line);
    }
}

test "tree: bytes after the one item are TrailingBytes at the first extra byte" {
    try expect_fail("\xc0\xc0", error.TrailingBytes, 1);
    try expect_fail("\x01\xc1", error.TrailingBytes, 1);
    try expect_fail("\x92\x01\x02\x03", error.TrailingBytes, 3);
    try expect_fail("\x90\x90", error.TrailingBytes, 1);
    try expect_fail("\x80\x00", error.TrailingBytes, 1);
}

test "tree: reader errors keep their position" {
    try expect_fail("\xc1", error.ReservedByte, 0);
    try expect_fail("\x92\x01\xc1", error.ReservedByte, 2);
    try expect_fail("\xa1\xff", error.InvalidUtf8, 0);
    try expect_fail("\x91\xa2\xc3\x28", error.InvalidUtf8, 1);
    try expect_fail("\x81\xa1\xff\x01", error.InvalidUtf8, 1);
    try expect_fail("\xcd\x01", error.UnexpectedEnd, 0);
}

test "tree: a declared count larger than the bytes left allocates nothing" {
    const bombs = [_][]const u8{
        "\xdd\xff\xff\xff\xff\x00\x00\x00\x00",
        "\xdf\xff\xff\xff\xff\x00\x00\x00\x00",
        "\xdc\xff\xff\x00",
        "\xdb\xff\xff\xff\xff\x00",
        "\xc6\xff\xff\xff\xff\x00",
        "\x82\xa1a\x01",
    };
    for (bombs) |bomb| {
        const gpa = std.testing.allocator;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();
        var diag = fresh_diag();
        const result = decoder.parse_value(&tree, bomb, options_reject, &diag);
        try expectError(error.UnexpectedEnd, result);
        try expectEqual(@as(usize, 0), failing.allocated_bytes);
        try expectEqual(@as(u32, 1), diag.line);
    }
}

test "tree: bytes_max is inclusive and InputTooLarge has no position" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const exact: ParseOptions = .{ .depth_max = 8, .bytes_max = 3, .duplicate_key = .reject };
    try expectEqual(@as(usize, 2), (try parse_with(&tree, "\x92\x01\x02", exact)).array.len);

    const small: ParseOptions = .{ .depth_max = 8, .bytes_max = 2, .duplicate_key = .reject };
    var diag = fresh_diag();
    try expectError(error.InputTooLarge, decoder.parse_value(&tree, "\x92\x01\x02", small, &diag));
    try expectEqual(core.diagnostics.position_none, diag.line);
    try expectEqual(core.diagnostics.position_none, diag.col);
    try expect(diag.message().len > 0);
}

test "tree: ParseValueError has the 11 variants of ADR 0006" {
    const names = [_][]const u8{
        "InputTooLarge",    "UnexpectedEnd", "ReservedByte", "InvalidUtf8",
        "TooDeep",          "NonStringKey",  "DuplicateKey", "UnsupportedExt",
        "InvalidTimestamp", "TrailingBytes", "OutOfMemory",
    };
    const fields = @typeInfo(ParseValueError).error_set.?;
    try expectEqual(names.len, fields.len);
    inline for (names) |name| {
        var found = false;
        inline for (fields) |declared| found = found or std.mem.eql(u8, declared.name, name);
        try expect(found);
    }
}

// ---- Allocation failure. ----

fn parse_for_oom(gpa: std.mem.Allocator, input: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = fresh_diag();
    const value = decoder.parse_value(&tree, input, options_last, &diag) catch |err| {
        // Every allocation failure must have reported itself.
        try expect(diag.line != sentinel_line);
        try expect(diag.message().len > 0);
        return err;
    };
    try expectEqual(sentinel_line, diag.line);
    try expect(value != .null);
}

test "tree: every allocation failure is OutOfMemory and leaks nothing" {
    const doc = "\x85\xa1a\x93\x01\xa2hi\x92\xc4\x01\x00\x80\xa1b\x81\xa1c\xc3\xa1a\xa3new" ++
        "\xa1d\x90\xa1e\xd6\xff\x00\x00\x00\x01";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_for_oom, .{doc});
}

test "tree: OutOfMemory writes the diagnostic once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();

    var diag = fresh_diag();
    const result = decoder.parse_value(&tree, "\x91\x01", options_reject, &diag);
    try expectError(error.OutOfMemory, result);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 1), diag.col);
}

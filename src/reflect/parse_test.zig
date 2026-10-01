//! reflect/parse tests — scalar parse (ADR 0002 sections 2, 4, 5): every exact message, the
//! integer and float coercion edges, borrowing and zero allocation, `parse_value` under a
//! caller's `Context`, `write_fallback`, and a fuzz run against a plain model. Split from
//! `parse.zig` to keep both files under the tidy file-length limit.

const std = @import("std");
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const parse_mod = @import("parse.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Context = context_mod.Context;
const Path = context_mod.Path;
const ParseError = context_mod.ParseError;
const parse = parse_mod.parse;
const parse_value = parse_mod.parse_value;
const write_fallback = parse_mod.write_fallback;
const testing = std.testing;
const Map = core.Map;
const position_none = core.diagnostics.position_none;
const nesting_max = core.value.nesting_max;

const Color = enum { red, green, blue };

const Mode = enum {
    fast_path,
    slow,
    pub const sigil_options = .{ .rename = .{ .slow = "lazy" }, .rename_all = .kebab_case };
};

fn sentinel() Diagnostics {
    return Diagnostics.init(7, 9, "untouched", null);
}

fn expect_untouched(diag: *const Diagnostics) !void {
    try testing.expectEqual(@as(u32, 7), diag.line);
    try testing.expectEqual(@as(u32, 9), diag.col);
    try testing.expectEqualStrings("untouched", diag.message());
}

/// Parses `value` as `T` and expects `expected`; floats compare by bit pattern. Success must
/// leave the diagnostics untouched.
fn expect_parse(comptime T: type, value: Value, expected: T) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    const got = try parse(T, &tree, value, &diag);
    if (@typeInfo(T) == .float) {
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        try testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(got)));
    } else {
        try testing.expectEqual(expected, got);
    }
    try expect_untouched(&diag);
}

/// Expects `err` and a diagnostics of exactly `message` at `position_none`.
fn expect_failure(comptime T: type, value: Value, err: ParseError, message: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    try testing.expectError(err, parse(T, &tree, value, &diag));
    try testing.expectEqualStrings(message, diag.message());
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
    try testing.expect(diag.snippet_text() == null);
}

const int_types = .{ u8, i8, u16, i16, u32, i32, u64, i64, usize };

fn expect_int_case(comptime T: type, value: Value, comptime n: i128, comptime fits: bool) !void {
    if (fits) return expect_parse(T, value, @intCast(n));
    const message = std.fmt.comptimePrint("{d} is out of range for {s}", .{ n, @typeName(T) });
    try expect_failure(T, value, error.IntegerOutOfRange, message);
}

/// `n` as `.int` and as `.uint`, each only when `Value` can hold it.
fn expect_int_edge(comptime T: type, comptime n: i128) !void {
    const fits = n >= std.math.minInt(T) and n <= std.math.maxInt(T);
    if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) {
        try expect_int_case(T, .{ .int = @intCast(n) }, n, fits);
    }
    if (n >= 0 and n <= std.math.maxInt(u64)) {
        try expect_int_case(T, .{ .uint = @intCast(n) }, n, fits);
    }
}

fn expect_edges(comptime T: type) !void {
    const lo: i128 = std.math.minInt(T);
    const hi: i128 = std.math.maxInt(T);
    inline for (.{ lo, hi, lo - 1, hi + 1 }) |n| try expect_int_edge(T, n);
}

test "parse int: every width accepts its min and max and rejects one past, from int and uint" {
    inline for (int_types) |T| try expect_edges(T);
}

test "parse int: values around zero and a small uint into a signed type" {
    inline for (int_types) |T| {
        try expect_parse(T, .{ .int = 0 }, 0);
        try expect_parse(T, .{ .uint = 0 }, 0);
        try expect_parse(T, .{ .int = 1 }, 1);
        try expect_parse(T, .{ .uint = 100 }, 100);
    }
    try expect_parse(i8, .{ .uint = 127 }, 127);
    try expect_parse(i64, .{ .uint = std.math.maxInt(i64) }, std.math.maxInt(i64));
}

/// `value` into `T` is `IntegerOutOfRange` with the number `n` named in the message.
fn expect_range(comptime T: type, value: Value, comptime n: []const u8) !void {
    const message = n ++ " is out of range for " ++ @typeName(T);
    try expect_failure(T, value, error.IntegerOutOfRange, message);
}

/// `value` into `T` is `TypeMismatch`: "expected {kind}, found {tag}".
fn expect_mismatch(
    comptime T: type,
    value: Value,
    comptime kind: []const u8,
    tag: []const u8,
) !void {
    var buf: [96]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "expected {s}, found {s}", .{ kind, tag });
    try expect_failure(T, value, error.TypeMismatch, message);
}

test "parse int: a negative value into an unsigned type is out of range" {
    try expect_range(u8, .{ .int = -1 }, "-1");
    try expect_range(u16, .{ .int = -1 }, "-1");
    try expect_range(u32, .{ .int = -2 }, "-2");
    try expect_range(u64, .{ .int = -1 }, "-1");
    try expect_range(usize, .{ .int = -1 }, "-1");
    try expect_range(u64, .{ .int = std.math.minInt(i64) }, "-9223372036854775808");
}

test "parse int: i64 min parses and u64 max splits on the sign of the target" {
    try expect_parse(i64, .{ .int = std.math.minInt(i64) }, std.math.minInt(i64));
    try expect_parse(u64, .{ .uint = std.math.maxInt(u64) }, std.math.maxInt(u64));
    try expect_range(i64, .{ .uint = std.math.maxInt(u64) }, "18446744073709551615");
    try expect_range(i64, .{ .uint = 1 << 63 }, "9223372036854775808");
}

test "parse int: a float is a type mismatch even when it is integral" {
    try expect_mismatch(u8, .{ .float = 3.0 }, "integer", "float");
    try expect_mismatch(i64, .{ .float = -2.0 }, "integer", "float");
    try expect_mismatch(u64, .{ .float = 0.0 }, "integer", "float");
    try expect_mismatch(usize, .{ .float = 1.5 }, "integer", "float");
    try expect_failure(u8, .{ .float = 3.0 }, error.TypeMismatch, "expected integer, found float");
}

const Sample = struct { name: []const u8, value: Value };

fn samples(entries: []Map.Entry) [10]Sample {
    return .{
        .{ .name = "null", .value = .null },
        .{ .name = "bool", .value = .{ .bool = true } },
        .{ .name = "int", .value = .{ .int = 5 } },
        .{ .name = "uint", .value = .{ .uint = 5 } },
        .{ .name = "float", .value = .{ .float = 1.5 } },
        .{ .name = "string", .value = .{ .string = "s" } },
        .{ .name = "bytes", .value = .{ .bytes = "b" } },
        .{ .name = "timestamp", .value = .{ .timestamp = .{
            .seconds = 0,
            .nanoseconds = 0,
            .offset_minutes = null,
        } } },
        .{ .name = "array", .value = .{ .array = &.{} } },
        .{ .name = "map", .value = .{ .map = Map.init(entries) } },
    };
}

fn is_accepted(accepted: []const []const u8, name: []const u8) bool {
    for (accepted) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Every Value tag outside `accepted` must be `TypeMismatch` with the exact message.
fn expect_rejects_others(
    comptime T: type,
    comptime kind: []const u8,
    accepted: []const []const u8,
) !void {
    var no_entries: [0]Map.Entry = .{};
    var rejected: u32 = 0;
    for (samples(&no_entries)) |sample| {
        if (is_accepted(accepted, sample.name)) continue;
        try expect_mismatch(T, sample.value, kind, sample.name);
        rejected += 1;
    }
    try testing.expectEqual(@as(u32, 10) - @as(u32, @intCast(accepted.len)), rejected);
}

test "parse int: every non-integer tag is a type mismatch naming the tag" {
    inline for (.{ u8, i64, usize }) |T| {
        try expect_rejects_others(T, "integer", &.{ "int", "uint" });
    }
}

test "parse bool: accepts only a bool" {
    try expect_parse(bool, .{ .bool = true }, true);
    try expect_parse(bool, .{ .bool = false }, false);
    try expect_rejects_others(bool, "bool", &.{"bool"});
    try expect_mismatch(bool, .{ .string = "true" }, "bool", "string");
    try expect_mismatch(bool, .{ .uint = 0 }, "bool", "uint");
    try expect_failure(bool, .{ .int = 1 }, error.TypeMismatch, "expected bool, found int");
}

const two53: i64 = 1 << 53;
const two53_u: u64 = 1 << 53;
const two24: i64 = 1 << 24;

fn inexact(comptime n: i128, comptime T: type) []const u8 {
    return std.fmt.comptimePrint("{d} is not exactly representable as {s}", .{ n, @typeName(T) });
}

test "parse f64: integers up to 2^53 in magnitude are exact, from int and uint" {
    try expect_parse(f64, .{ .int = 0 }, 0.0);
    try expect_parse(f64, .{ .int = -1 }, -1.0);
    try expect_parse(f64, .{ .int = two53 }, 9007199254740992.0);
    try expect_parse(f64, .{ .uint = two53 }, 9007199254740992.0);
    try expect_parse(f64, .{ .int = -two53 }, -9007199254740992.0);
    try expect_parse(f64, .{ .int = two53 - 1 }, 9007199254740991.0);
}

test "parse f64: integers beyond 2^53 in magnitude are inexact" {
    const too_big = inexact(two53 + 1, f64);
    try expect_failure(f64, .{ .int = two53 + 1 }, error.InexactNumber, too_big);
    try expect_failure(f64, .{ .uint = two53 + 1 }, error.InexactNumber, too_big);
    const too_small = inexact(-two53 - 1, f64);
    try expect_failure(f64, .{ .int = -two53 - 1 }, error.InexactNumber, too_small);
    const min = inexact(std.math.minInt(i64), f64);
    try expect_failure(f64, .{ .int = std.math.minInt(i64) }, error.InexactNumber, min);
    const max = inexact(std.math.maxInt(u64), f64);
    try expect_failure(f64, .{ .uint = std.math.maxInt(u64) }, error.InexactNumber, max);
    // A range rule, not a representability rule: 2^54 is representable and still rejected.
    try expect_failure(f64, .{ .int = 1 << 54 }, error.InexactNumber, inexact(1 << 54, f64));
}

test "parse f64: a float keeps its exact bit pattern" {
    try expect_parse(f64, .{ .float = 0.1 }, 0.1);
    try expect_parse(f64, .{ .float = -0.0 }, -0.0);
    try expect_parse(f64, .{ .float = 0.0 }, 0.0);
    try expect_parse(f64, .{ .float = 1e308 }, 1e308);
    try expect_parse(f64, .{ .float = 5e-324 }, 5e-324);
    try expect_parse(f64, .{ .float = std.math.inf(f64) }, std.math.inf(f64));
    try expect_parse(f64, .{ .float = -std.math.inf(f64) }, -std.math.inf(f64));
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    const nan = try parse(f64, &tree, .{ .float = std.math.nan(f64) }, &diag);
    try testing.expect(std.math.isNan(nan));
    try expect_untouched(&diag);
}

test "parse f64: every non-number tag is a type mismatch naming the tag" {
    try expect_rejects_others(f64, "float", &.{ "int", "uint", "float" });
    try expect_rejects_others(f32, "float", &.{ "int", "uint", "float" });
}

test "parse f32: integers up to 2^24 in magnitude are exact, larger ones are inexact" {
    try expect_parse(f32, .{ .int = two24 }, 16777216.0);
    try expect_parse(f32, .{ .uint = two24 }, 16777216.0);
    try expect_parse(f32, .{ .int = -two24 }, -16777216.0);
    try expect_parse(f32, .{ .int = 0 }, 0.0);
    try expect_failure(f32, .{ .int = two24 + 1 }, error.InexactNumber, inexact(two24 + 1, f32));
    try expect_failure(f32, .{ .uint = two24 + 1 }, error.InexactNumber, inexact(two24 + 1, f32));
    try expect_failure(f32, .{ .int = -two24 - 1 }, error.InexactNumber, inexact(-two24 - 1, f32));
    try expect_failure(f32, .{ .int = two53 }, error.InexactNumber, inexact(two53, f32));
    const max = inexact(std.math.maxInt(u64), f32);
    try expect_failure(f32, .{ .uint = std.math.maxInt(u64) }, error.InexactNumber, max);
}

fn out_of_range_f32(comptime x: f64) []const u8 {
    return std.fmt.comptimePrint("{d} is out of range for f32", .{x});
}

test "parse f32: a float rounds to nearest and finite overflow is out of range" {
    try expect_parse(f32, .{ .float = 0.1 }, @as(f32, 0.1));
    try expect_parse(f32, .{ .float = 1.5 }, 1.5);
    try expect_parse(f32, .{ .float = -0.0 }, -0.0);
    try expect_parse(f32, .{ .float = @as(f64, std.math.floatMax(f32)) }, std.math.floatMax(f32));
    const over: f64 = 1e39;
    try expect_failure(f32, .{ .float = over }, error.FloatOutOfRange, out_of_range_f32(over));
    try expect_failure(f32, .{ .float = -over }, error.FloatOutOfRange, out_of_range_f32(-over));
}

test "parse f32: the rounding boundary between max and infinity" {
    // The midpoint of floatMax(f32) and 2^128 is (2^25 - 1) * 2^103; ties go to even, which is
    // infinity, so the midpoint is out of range and its f64 predecessor is not.
    const midpoint: f64 = ((1 << 25) - 1) * (1 << 103);
    const below = std.math.nextAfter(f64, midpoint, 0);
    try expect_parse(f32, .{ .float = below }, std.math.floatMax(f32));
    const message = out_of_range_f32(midpoint);
    try expect_failure(f32, .{ .float = midpoint }, error.FloatOutOfRange, message);
    const negative = out_of_range_f32(-midpoint);
    try expect_failure(f32, .{ .float = -midpoint }, error.FloatOutOfRange, negative);
}

test "parse f32: NaN and infinity pass through unchanged" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    const nan = try parse(f32, &tree, .{ .float = std.math.nan(f64) }, &diag);
    try testing.expect(std.math.isNan(nan));
    try expect_parse(f32, .{ .float = std.math.inf(f64) }, std.math.inf(f32));
    try expect_parse(f32, .{ .float = -std.math.inf(f64) }, -std.math.inf(f32));
    try expect_untouched(&diag);
}

test "parse string: borrows from the value without copying" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const source = try tree.dupe_string("hello");
    var diag = sentinel();
    const before = tree.arena.queryCapacity();
    const got = try parse([]const u8, &tree, source, &diag);
    try testing.expectEqualStrings("hello", got);
    try testing.expect(got.ptr == source.string.ptr);
    try testing.expectEqual(source.string.len, got.len);
    try testing.expectEqual(before, tree.arena.queryCapacity());
    try expect_untouched(&diag);
}

test "parse string: empty and non-utf8 strings are returned as they are" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    const empty = try parse([]const u8, &tree, .{ .string = "" }, &diag);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const odd = try parse([]const u8, &tree, .{ .string = "\xff\xfe" }, &diag);
    try testing.expectEqualStrings("\xff\xfe", odd);
    try expect_untouched(&diag);
}

test "parse string: bytes are a type mismatch, and so is every other tag" {
    try expect_mismatch([]const u8, .{ .bytes = "" }, "string", "bytes");
    try expect_rejects_others([]const u8, "string", &.{"string"});
}

/// A string naming no member of enum `T` is `UnknownEnumValue` with `unknown {T} "{text}"`.
fn expect_unknown(comptime T: type, comptime text: []const u8) !void {
    const message = std.fmt.comptimePrint("unknown {s} \"{s}\"", .{ @typeName(T), text });
    try expect_failure(T, .{ .string = text }, error.UnknownEnumValue, message);
}

test "parse enum: a plain enum is read by tag name" {
    try expect_parse(Color, .{ .string = "red" }, .red);
    try expect_parse(Color, .{ .string = "green" }, .green);
    try expect_parse(Color, .{ .string = "blue" }, .blue);
}

test "parse enum: an unknown or differently cased name is UnknownEnumValue" {
    try expect_unknown(Color, "mauve");
    try expect_unknown(Color, "Red");
    try expect_unknown(Color, "");
    try expect_unknown(Color, "red ");
}

test "parse enum: rename and rename_all decide the wire names, not the Zig names" {
    try expect_parse(Mode, .{ .string = "fast-path" }, .fast_path);
    try expect_parse(Mode, .{ .string = "lazy" }, .slow);
    try expect_unknown(Mode, "fast_path");
    try expect_unknown(Mode, "slow");
}

test "parse enum: an integer or any other non-string tag is a type mismatch" {
    const kind = "enum " ++ @typeName(Color);
    const expected = "expected " ++ kind ++ ", found ";
    try expect_failure(Color, .{ .int = 1 }, error.TypeMismatch, expected ++ "int");
    try expect_failure(Color, .{ .uint = 0 }, error.TypeMismatch, expected ++ "uint");
    try expect_rejects_others(Color, kind, &.{"string"});
}

test "parse enum: a very long unknown name is cut so the message stays within 128 bytes" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const long = try tree.dupe_string("a" ** 300);
    var diag = sentinel();
    try testing.expectError(error.UnknownEnumValue, parse(Color, &tree, long, &diag));
    const message = diag.message();
    try testing.expectEqual(@as(usize, 128), message.len);
    try testing.expect(std.mem.startsWith(u8, message, "unknown " ++ @typeName(Color) ++ " \"aaa"));
    try testing.expect(std.mem.endsWith(u8, message, "..."));
}

test "parse optional: null gives null and a present value parses as the child type" {
    try expect_parse(?u8, .null, null);
    try expect_parse(?u8, .{ .int = 7 }, 7);
    try expect_parse(?bool, .{ .bool = false }, false);
    try expect_parse(?bool, .null, null);
    try expect_parse(?Color, .{ .string = "blue" }, .blue);
    try expect_parse(?f64, .{ .int = 2 }, 2.0);
    try expect_parse(?i64, .{ .int = std.math.minInt(i64) }, std.math.minInt(i64));
}

test "parse optional: child errors read as the child type, with no extra path segment" {
    try expect_failure(?u8, .{ .int = 300 }, error.IntegerOutOfRange, "300 is out of range for u8");
    try expect_failure(?u8, .{ .int = -1 }, error.IntegerOutOfRange, "-1 is out of range for u8");
    try expect_failure(?u8, .{ .float = 1.0 }, error.TypeMismatch, "expected integer, found float");
    try expect_failure(?f32, .{ .int = two24 + 1 }, error.InexactNumber, inexact(two24 + 1, f32));
    try expect_rejects_others(?u8, "integer", &.{ "null", "int", "uint" });
}

test "parse optional: an optional string borrows the same bytes" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const source = try tree.dupe_string("abc");
    var diag = sentinel();
    const got = (try parse(?[]const u8, &tree, source, &diag)).?;
    try testing.expect(got.ptr == source.string.ptr);
    try testing.expectEqual(@as(?[]const u8, null), try parse(?[]const u8, &tree, .null, &diag));
    try expect_untouched(&diag);
}

test "parse timestamp: accepts only a timestamp and returns it field for field" {
    const Stamp = core.Timestamp;
    const stamp: Stamp = .{ .seconds = 1_700_000_000, .nanoseconds = 123, .offset_minutes = -60 };
    try expect_parse(Stamp, .{ .timestamp = stamp }, stamp);
    const local: Stamp = .{ .seconds = -1, .nanoseconds = 999_999_999, .offset_minutes = null };
    try expect_parse(Stamp, .{ .timestamp = local }, local);
    try expect_rejects_others(Stamp, "timestamp", &.{"timestamp"});
    try expect_mismatch(Stamp, .{ .string = "2020-01-01" }, "timestamp", "string");
}

test "parse Value: every tag is returned as it is, sharing its memory" {
    var no_entries: [0]Map.Entry = .{};
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    for (samples(&no_entries)) |sample| {
        const got = try parse(Value, &tree, sample.value, &diag);
        try testing.expectEqualStrings(@tagName(sample.value), @tagName(got));
        try testing.expect(try core.value.eql(sample.value, got));
    }
    const text = try tree.dupe_string("shared");
    const got = try parse(Value, &tree, text, &diag);
    try testing.expect(got.string.ptr == text.string.ptr);
    try expect_untouched(&diag);
}

fn expect_no_alloc(comptime T: type, value: Value) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    _ = try parse(T, &tree, value, &diag);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(usize, 0), tree.arena.queryCapacity());
    try expect_untouched(&diag);
}

test "parse: no scalar kind allocates, so a failing allocator never matters" {
    try expect_no_alloc(bool, .{ .bool = true });
    try expect_no_alloc(u8, .{ .int = 1 });
    try expect_no_alloc(i64, .{ .uint = 1 });
    try expect_no_alloc(u64, .{ .uint = std.math.maxInt(u64) });
    try expect_no_alloc(f64, .{ .float = 1.5 });
    try expect_no_alloc(f64, .{ .int = 1 });
    try expect_no_alloc(f32, .{ .float = 1.5 });
    try expect_no_alloc([]const u8, .{ .string = "abc" });
    try expect_no_alloc(Color, .{ .string = "red" });
    try expect_no_alloc(?u8, .null);
    try expect_no_alloc(?u8, .{ .int = 1 });
    try expect_no_alloc(core.Timestamp, .{ .timestamp = .{
        .seconds = 0,
        .nanoseconds = 0,
        .offset_minutes = null,
    } });
    try expect_no_alloc(Value, .{ .string = "x" });
}

test "parse: a failing scalar parse allocates nothing either" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    try testing.expectError(error.IntegerOutOfRange, parse(u8, &tree, .{ .int = 300 }, &diag));
    try testing.expectEqualStrings("300 is out of range for u8", diag.message());
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

const Rig = struct {
    tree: ValueTree,
    diag: Diagnostics,
    path: Path,
    context: Context,

    fn begin(rig: *Rig) void {
        rig.tree.init(testing.allocator);
        rig.diag = sentinel();
        rig.path.init();
        rig.context.init(&rig.tree, &rig.diag, &rig.path);
    }
};

test "parse_value: parses under the caller's path and depth and leaves both alone" {
    var rig: Rig = undefined;
    rig.begin();
    defer rig.tree.deinit();
    rig.path.push(.{ .key = "a" });
    rig.context.depth = 1;
    try testing.expectEqual(@as(u8, 4), try parse_value(u8, &rig.context, .{ .int = 4 }));
    try expect_untouched(&rig.diag);
    try testing.expect(!rig.context.diag_written);
    const failed = parse_value(u8, &rig.context, .{ .int = 300 });
    try testing.expectError(error.IntegerOutOfRange, failed);
    try testing.expectEqualStrings("a: 300 is out of range for u8", rig.diag.message());
    try testing.expectEqual(position_none, rig.diag.line);
    try testing.expect(rig.context.diag_written);
    try testing.expectEqual(@as(u32, 1), rig.path.count);
    try testing.expectEqual(@as(u32, 1), rig.context.depth);
}

test "write_fallback: names the path, the type and the error" {
    var rig: Rig = undefined;
    rig.begin();
    defer rig.tree.deinit();
    write_fallback(u8, &rig.context, error.OutOfMemory);
    try testing.expectEqualStrings("parse of u8 failed: OutOfMemory", rig.diag.message());
    try testing.expectEqual(position_none, rig.diag.line);
    try testing.expectEqual(position_none, rig.diag.col);
    try testing.expect(rig.context.diag_written);

    rig.diag = sentinel();
    rig.context.diag_written = false;
    rig.path.push(.{ .key = "servers" });
    rig.path.push(.{ .index = 2 });
    rig.context.depth = 2;
    write_fallback(Color, &rig.context, error.InvalidValue);
    const expected = "servers[2]: parse of " ++ @typeName(Color) ++ " failed: InvalidValue";
    try testing.expectEqualStrings(expected, rig.diag.message());
    try testing.expect(rig.context.diag_written);
}

// ---------------------------------------------------------------------------------------------
// Fuzz (std.testing.fuzz, Zig 0.16): a random Value is parsed as each scalar type. The invariant
// is the contract: success leaves the diagnostics alone, failure is one of the five scalar
// errors with a position-less message, and the integer and f64 rules agree with a plain model.
// ---------------------------------------------------------------------------------------------

fn fuzz_value(smith: *testing.Smith, text: []u8) Value {
    const len = smith.slice(text);
    return switch (smith.value(u8) % 9) {
        0 => .null,
        1 => .{ .bool = smith.value(bool) },
        2 => .{ .int = smith.value(i64) },
        3 => .{ .uint = smith.value(u64) },
        4 => .{ .float = smith.value(f64) },
        5 => .{ .string = text[0..len] },
        6 => .{ .bytes = text[0..len] },
        7 => .{ .int = @as(i64, smith.value(i8)) },
        else => .{ .float = std.math.nan(f64) },
    };
}

fn model_int(comptime T: type, value: Value) ParseError!T {
    return switch (value) {
        .int => |n| std.math.cast(T, n) orelse error.IntegerOutOfRange,
        .uint => |n| std.math.cast(T, n) orelse error.IntegerOutOfRange,
        else => error.TypeMismatch,
    };
}

fn model_f64(value: Value) ParseError!f64 {
    return switch (value) {
        .float => |x| x,
        .int => |n| if (@abs(n) <= two53_u) @as(f64, @floatFromInt(n)) else error.InexactNumber,
        .uint => |n| if (n <= two53_u) @as(f64, @floatFromInt(n)) else error.InexactNumber,
        else => error.TypeMismatch,
    };
}

fn check_total(comptime T: type, value: Value) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    if (parse(T, &tree, value, &diag)) |_| {
        try expect_untouched(&diag);
        return;
    } else |err| {
        const allowed = [_][]const u8{
            "TypeMismatch",     "IntegerOutOfRange", "InexactNumber", "FloatOutOfRange",
            "UnknownEnumValue",
        };
        try testing.expect(is_accepted(&allowed, @errorName(err)));
    }
    try testing.expectEqual(position_none, diag.line);
    try testing.expectEqual(position_none, diag.col);
    try testing.expect(diag.message().len > 0);
    try testing.expect(!std.mem.eql(u8, diag.message(), "untouched"));
}

fn check_model(comptime T: type, value: Value) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = sentinel();
    const expected = if (T == f64) model_f64(value) else model_int(T, value);
    if (expected) |want| {
        try testing.expectEqual(want, try parse(T, &tree, value, &diag));
    } else |err| {
        try testing.expectError(err, parse(T, &tree, value, &diag));
    }
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var text: [24]u8 = undefined;
    const value = fuzz_value(smith, &text);
    inline for (.{ bool, u8, i16, u64, i64, f32, f64, []const u8, Color, ?i8 }) |T| {
        try check_total(T, value);
    }
    if (value == .float and std.math.isNan(value.float)) return;
    inline for (.{ u8, i16, u64, i64, f64 }) |T| try check_model(T, value);
}

const fuzz_corpus = [_][]const u8{
    &.{},
    &([_]u8{0} ** 40),
    &([_]u8{0xff} ** 40),
    &([_]u8{ 2, 0x80 } ++ [_]u8{0} ** 40),
    &([_]u8{ 3, 0xff } ++ [_]u8{0xff} ** 40),
    &([_]u8{ 4, 0x7f } ++ [_]u8{0xf0} ** 40),
    &([_]u8{ 5, 0x03 } ++ "red".* ++ [_]u8{0} ** 40),
};

test "parse: fuzz every scalar type against its model and the diagnostics contract" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

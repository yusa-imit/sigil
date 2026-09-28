//! core/number — decimal literal text -> `Value` (`.int`/`.uint`/`.float`), exact, no silent
//! int -> float coercion (REALM.md "Numeric exactness"). Not a lexer: input is one token
//! already matching `is_decimal_literal`. Canonical integer form: `.int` when the value fits
//! i64, `.uint` only when it exceeds maxInt(i64). Allocation: none. Cost: O(text.len).

const std = @import("std");
const assert = std.debug.assert;
const value = @import("value.zig");
const Value = value.Value;

pub const Shape = enum { integer, float };

/// Positive literal > maxInt(u64) (18446744073709551615): IntegerAboveMax.
/// Negative literal < minInt(i64) (-9223372036854775808): IntegerBelowMin.
pub const IntegerError = error{ IntegerAboveMax, IntegerBelowMin };
/// A finite literal whose magnitude rounds to infinity in f64 (> ~1.7976931348623158e308).
pub const FloatError = error{FloatOutOfRange};
pub const Error = IntegerError || FloatError;

/// The number of leading ASCII digits ('0'..'9') in `s`, `0` if `s` starts with a non-digit
/// or is empty. Total: any bytes in, never asserts. Helper for `is_decimal_literal`'s scanner
/// (kept separate to hold that function under the line budget).
fn digit_run_len(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    return i;
}

/// True iff `text` matches `-? DIGIT+ ( "." DIGIT+ )? ( [eE] [+-]? DIGIT+ )?` (ASCII digits
/// only; no leading `+`, no `_`, no radix prefix, no `inf`/`nan`). Total: any bytes in, never
/// asserts, never panics — this is the boundary function callers use to gate every other
/// function in this file, so it cannot itself have a precondition to assert.
pub fn is_decimal_literal(text: []const u8) bool {
    var i: usize = 0;
    if (text.len > 0 and text[0] == '-') i += 1;
    assert(i <= text.len);

    const integer_digits = digit_run_len(text[i..]);
    if (integer_digits == 0) return false;
    i += integer_digits;

    if (i < text.len and text[i] == '.') {
        i += 1;
        const fraction_digits = digit_run_len(text[i..]);
        if (fraction_digits == 0) return false;
        i += fraction_digits;
    }

    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const exponent_digits = digit_run_len(text[i..]);
        if (exponent_digits == 0) return false;
        i += exponent_digits;
    }

    assert(i <= text.len);
    return i == text.len;
}

/// `.float` iff `text` contains '.', 'e' or 'E'; otherwise `.integer`.
/// Precondition: is_decimal_literal(text).
pub fn classify(text: []const u8) Shape {
    assert(text.len > 0);
    assert(is_decimal_literal(text));

    for (text) |c| {
        if (c == '.' or c == 'e' or c == 'E') return .float;
    }
    return .integer;
}

/// Precondition: is_decimal_literal(text) and classify(text) == .integer.
/// Non-negative: .int if <= maxInt(i64), else .uint if <= maxInt(u64), else IntegerAboveMax.
/// Negative: .int if >= minInt(i64), else IntegerBelowMin. "-0" -> .int = 0.
pub fn parse_integer(text: []const u8) IntegerError!Value {
    assert(is_decimal_literal(text));
    assert(classify(text) == .integer);

    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;
    assert(digits.len > 0);

    // proof: parseUnsigned's error set is exhaustively {Overflow, InvalidCharacter}, both handled.
    const magnitude = std.fmt.parseUnsigned(u64, digits, 10) catch |err| switch (err) {
        // proof: is_decimal_literal guarantees digits-only, no `_`/`+`, checked above.
        error.InvalidCharacter => unreachable,
        error.Overflow => return if (negative) error.IntegerBelowMin else error.IntegerAboveMax,
    };

    if (!negative) {
        if (magnitude <= @as(u64, std.math.maxInt(i64))) {
            const result: Value = .{ .int = @intCast(magnitude) };
            assert(result.int >= 0);
            return result;
        }
        // magnitude is already a valid u64 (parseUnsigned succeeded), so it always fits
        // `.uint`; there is no further "past u64 max" case to check here.
        const result: Value = .{ .uint = magnitude };
        assert(result.uint > @as(u64, std.math.maxInt(i64)));
        return result;
    }

    const magnitude_max: u64 = @as(u64, 1) << 63;
    if (magnitude > magnitude_max) return error.IntegerBelowMin;
    // Wrapping negation on the bit-cast magnitude is exact for every value in [0, 2^63],
    // including exactly 2^63, which bit-casts to minInt(i64) and wrapping-negates to itself.
    const result: Value = .{ .int = -%@as(i64, @bitCast(magnitude)) };
    assert(result.int <= 0);
    return result;
}

/// Precondition: is_decimal_literal(text) and classify(text) == .float.
/// Round-to-nearest-even f64; sign kept on zero ("-0.0" -> sign bit set); underflow to
/// (signed) zero is accepted; a result of +-inf is FloatOutOfRange. Never returns NaN.
pub fn parse_float(text: []const u8) FloatError!f64 {
    assert(is_decimal_literal(text));
    assert(classify(text) == .float);

    // is_decimal_literal's grammar is a strict subset of parseFloat's accepted grammar.
    // proof: parseFloat cannot fail on text that already passed our precondition.
    const f = std.fmt.parseFloat(f64, text) catch unreachable;
    assert(!std.math.isNan(f));

    if (std.math.isInf(f)) return error.FloatOutOfRange;
    assert(std.math.isFinite(f));
    return f;
}

/// classify, then parse_integer or `.{ .float = try parse_float(text) }`.
/// Precondition: is_decimal_literal(text).
pub fn parse_decimal(text: []const u8) Error!Value {
    assert(text.len > 0);
    assert(is_decimal_literal(text));

    switch (classify(text)) {
        .integer => {
            const result = try parse_integer(text);
            assert(std.meta.activeTag(result) == .int or std.meta.activeTag(result) == .uint);
            return result;
        },
        .float => {
            const result: Value = .{ .float = try parse_float(text) };
            assert(std.meta.activeTag(result) == .float);
            return result;
        },
    }
}

test "is_decimal_literal: accepts well-formed decimal literals" {
    const valids = [_][]const u8{ "0", "-0", "007", "1.5", "-1.5e-3", "1e10", "1E+2", "0.0e0" };
    for (valids) |text| {
        try std.testing.expect(is_decimal_literal(text));
    }
}

test "is_decimal_literal: rejects malformed, ambiguous, and non-decimal text" {
    const invalids = [_][]const u8{
        "",      "-",     "+1",    "1.",   ".5",  "1e",   "1e+", "--1",
        "1.2.3", "1e5e5", "1_000", "0x10", "inf", "-inf", "nan", " 1",
        "1 ",    "1a",
    };
    for (invalids) |text| {
        try std.testing.expect(!is_decimal_literal(text));
    }
}

test "classify: distinguishes integer and float shapes" {
    try std.testing.expectEqual(Shape.integer, classify("1"));
    try std.testing.expectEqual(Shape.integer, classify("-0"));
    try std.testing.expectEqual(Shape.float, classify("1.0"));
    try std.testing.expectEqual(Shape.float, classify("1e10"));
    try std.testing.expectEqual(Shape.float, classify("1E10"));
    try std.testing.expectEqual(Shape.float, classify("-0.0"));
}

test "parse_integer: i64 max and min literals map to .int exactly at the boundary" {
    const max = try parse_integer("9223372036854775807");
    try std.testing.expect(try value.eql(max, .{ .int = std.math.maxInt(i64) }));
    const min = try parse_integer("-9223372036854775808");
    try std.testing.expect(try value.eql(min, .{ .int = std.math.minInt(i64) }));
}

test "parse_integer: one past i64 max becomes .uint, not an error, and is not eql to any .int" {
    const parsed = try parse_integer("9223372036854775808");
    try std.testing.expect(std.meta.activeTag(parsed) == .uint);
    try std.testing.expect(try value.eql(parsed, .{ .uint = @as(u64, 1) << 63 }));
    try std.testing.expect(!try value.eql(parsed, .{ .int = std.math.maxInt(i64) }));
}

test "parse_integer: u64 max literal maps to .uint exactly at the boundary" {
    const parsed = try parse_integer("18446744073709551615");
    try std.testing.expect(std.meta.activeTag(parsed) == .uint);
    try std.testing.expect(try value.eql(parsed, .{ .uint = std.math.maxInt(u64) }));
}

test "parse_integer: positive literals past u64 max return IntegerAboveMax" {
    try std.testing.expectError(error.IntegerAboveMax, parse_integer("18446744073709551616"));
    try std.testing.expectError(error.IntegerAboveMax, parse_integer("99999999999999999999999"));
}

test "parse_integer: negative literals past i64 min return IntegerBelowMin" {
    try std.testing.expectError(error.IntegerBelowMin, parse_integer("-9223372036854775809"));
    try std.testing.expectError(error.IntegerBelowMin, parse_integer("-18446744073709551616"));
    try std.testing.expectError(error.IntegerBelowMin, parse_integer("-99999999999999999999999"));
}

test "parse_integer: leading zeros do not count toward overflow" {
    const parsed = try parse_integer("00000000000000000000000001");
    try std.testing.expect(try value.eql(parsed, .{ .int = 1 }));
}

test "parse_integer: negative zero and positive zero are the same signless .int, never .uint" {
    const neg = try parse_integer("-0");
    const pos = try parse_integer("0");
    try std.testing.expect(try value.eql(neg, .{ .int = 0 }));
    try std.testing.expect(try value.eql(neg, pos));
    try std.testing.expect(std.meta.activeTag(neg) != .uint);
    try std.testing.expect(std.meta.activeTag(pos) != .uint);
}

test "parse_float: negative zero keeps its sign bit, distinct from positive zero" {
    const neg_dot = try parse_float("-0.0");
    const neg_exp = try parse_float("-0e0");
    const pos = try parse_float("0.0");
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(neg_dot)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(neg_exp)));
    try std.testing.expectEqual(@as(u64, 0x0), @as(u64, @bitCast(pos)));
    try std.testing.expect(!try value.eql(.{ .float = neg_dot }, .{ .float = pos }));
}

test "parse_decimal: exponent-only literal is classified and parsed as .float, not .int" {
    const parsed = try parse_decimal("1e10");
    try std.testing.expect(std.meta.activeTag(parsed) == .float);
    try std.testing.expect(try value.eql(parsed, .{ .float = 1e10 }));
}

test "parse_float: f64 max magnitude rounds in range; past it is FloatOutOfRange" {
    const at_repr = try parse_float("1.7976931348623157e308");
    const at_next = try parse_float("1.7976931348623158e308");
    try std.testing.expectEqual(@as(u64, 0x7fefffffffffffff), @as(u64, @bitCast(at_repr)));
    try std.testing.expectEqual(@as(u64, 0x7fefffffffffffff), @as(u64, @bitCast(at_next)));
    try std.testing.expectError(error.FloatOutOfRange, parse_float("1.7976931348623159e308"));
    try std.testing.expectError(error.FloatOutOfRange, parse_float("1e400"));
    try std.testing.expectError(error.FloatOutOfRange, parse_float("-1e400"));
    try std.testing.expectError(error.FloatOutOfRange, parse_float("1e99999999999999999999"));
}

test "parse_float: subnormal underflow rounds to signed zero instead of erroring" {
    try std.testing.expectEqual(@as(u64, 0x0), @as(u64, @bitCast(try parse_float("1e-400"))));
    try std.testing.expectEqual(
        @as(u64, 0x8000000000000000),
        @as(u64, @bitCast(try parse_float("-1e-400"))),
    );
    try std.testing.expectEqual(@as(u64, 0x1), @as(u64, @bitCast(try parse_float("3e-324"))));
    try std.testing.expectEqual(@as(u64, 0x0), @as(u64, @bitCast(try parse_float("2e-324"))));
    try std.testing.expectEqual(
        @as(u64, 0x0),
        @as(u64, @bitCast(try parse_float("0e99999999999999999999"))),
    );
}

test "parse_float: ties round to nearest-even instead of erroring or truncating" {
    const parsed = try parse_float("9007199254740993.0");
    try std.testing.expectEqual(@as(u64, 0x4340000000000000), @as(u64, @bitCast(parsed)));
}

test "parse_decimal: round-trips 1000 random u64 and 1000 random i64 values through text" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        const n = random.int(u64);
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{n});
        const parsed = try parse_decimal(text);
        if (n > @as(u64, std.math.maxInt(i64))) {
            try std.testing.expect(std.meta.activeTag(parsed) == .uint);
            try std.testing.expectEqual(n, parsed.uint);
        } else {
            try std.testing.expect(std.meta.activeTag(parsed) == .int);
            try std.testing.expectEqual(@as(i64, @intCast(n)), parsed.int);
        }
    }

    iteration = 0;
    while (iteration < 1000) : (iteration += 1) {
        const n = random.int(i64);
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{n});
        const parsed = try parse_decimal(text);
        try std.testing.expect(std.meta.activeTag(parsed) == .int);
        try std.testing.expectEqual(n, parsed.int);
    }
}

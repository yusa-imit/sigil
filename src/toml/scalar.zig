//! toml/scalar — classifies one `.scalar` run of the lexer into a `Value` (ADR 0005 section 5).
//!
//! `parse` takes the whole run (the lexer already joined `1979-05-27 07:32:00` into one) and
//! returns `.bool`, `.int`, `.float` or `.timestamp`; never `.uint`, TOML integers are `i64`.
//! Decimal integers and floats go through `core.number` after `+` and `_` are removed; `0x`,
//! `0o` and `0b` are decoded here with an overflow check against `maxInt(i64)`; datetimes go
//! through `core.timestamp`. Every NaN becomes the one positive quiet NaN so that
//! parse -> write -> parse is `eql`; `-0.0` keeps its sign.
//!
//! Errors carry no position: the parser owns `Diagnostics` and reports the token offset.
//! Allocation: none; underscores are stripped into a stack buffer of `number_text_max` bytes.
//! A literal with underscores and more than that many bytes is `InvalidNumber` (ADR 0005
//! section 5), a literal without underscores is parsed in place at any length.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const number = core.number;
const timestamp = core.timestamp;
const Value = core.Value;

/// Longest number text that may contain underscores.
pub const number_text_max: u32 = 512;

/// Every variant is a literal fault; the parser adds the token position.
pub const Error = error{
    /// A word that is not a boolean, `inf` or `nan`, and does not start like a number or date.
    UnexpectedToken,
    /// Leading zero, a misplaced `_`, `1.`, `.5`, a bad radix digit, `+0x1`, trailing junk.
    InvalidNumber,
    /// A date or time shape with a calendar or clock field out of range, or `:60`.
    InvalidDatetime,
    /// Above `maxInt(i64)`, in any radix.
    IntegerAboveMax,
    /// Below `minInt(i64)`.
    IntegerBelowMin,
    /// A finite decimal float whose magnitude rounds past `f64`.
    FloatOutOfRange,
};

const nan_bits: u64 = 0x7ff8000000000000;

/// Classifies `text`, one lexer scalar run. Precondition: `text` is not empty.
pub fn parse(text: []const u8) Error!Value {
    assert(text.len > 0);
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    if (special_float(text)) |float| return .{ .float = float };
    if (is_datetime_shape(text)) {
        return .{ .timestamp = try timestamp.parse(text) };
    }
    if (text.len > 2 and text[0] == '0') {
        if (radix_of(text[1])) |radix| return parse_radix(text[2..], radix);
    }
    switch (text[0]) {
        '0'...'9', '+', '-', '.', '_' => {
            const result = try parse_decimal(text);
            assert(result == .int or result == .float);
            return result;
        },
        else => return error.UnexpectedToken,
    }
}

/// `inf`, `+inf`, `-inf`, `nan`, `+nan`, `-nan`; null for anything else.
fn special_float(text: []const u8) ?f64 {
    const signed = text.len > 0 and (text[0] == '+' or text[0] == '-');
    const word = if (signed) text[1..] else text;
    const negative = signed and text[0] == '-';
    if (std.mem.eql(u8, word, "inf")) {
        const inf = std.math.inf(f64);
        return if (negative) -inf else inf;
    }
    if (std.mem.eql(u8, word, "nan")) return @bitCast(nan_bits);
    return null;
}

/// True for `dddd-` and for `dd:`, the starts of a date and of a time; `timestamp.parse`
/// then decides whether the rest is well formed.
fn is_datetime_shape(text: []const u8) bool {
    assert(text.len > 0);
    if (text.len >= 3 and text[2] == ':' and is_digit(text[0]) and is_digit(text[1])) return true;
    if (text.len < 5 or text[4] != '-') return false;
    return is_digit(text[0]) and is_digit(text[1]) and is_digit(text[2]) and is_digit(text[3]);
}

fn is_digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn radix_of(byte: u8) ?u8 {
    return switch (byte) {
        'x' => 16,
        'o' => 8,
        'b' => 2,
        else => null,
    };
}

/// `digits` is the text after `0x`, `0o` or `0b`: digits of that radix with single `_`
/// between them, value at most `maxInt(i64)`.
fn parse_radix(digits: []const u8, radix: u8) Error!Value {
    assert(radix == 16 or radix == 8 or radix == 2);
    assert(digits.len > 0);
    var result: u64 = 0;
    var above_max = false;
    var previous_digit = false;
    for (digits) |byte| {
        if (byte == '_') {
            if (!previous_digit) return error.InvalidNumber;
            previous_digit = false;
            continue;
        }
        const digit = std.fmt.charToDigit(byte, radix) catch return error.InvalidNumber;
        previous_digit = true;
        if (above_max) continue;
        // `result` is at most 2^63 - 1, so the u128 product cannot wrap.
        const next = @as(u128, result) * radix + digit;
        above_max = next > std.math.maxInt(i64);
        if (!above_max) result = @intCast(next);
    }
    // A bad digit anywhere wins over overflow: the literal is malformed, not merely large.
    if (!previous_digit) return error.InvalidNumber;
    if (above_max) return error.IntegerAboveMax;
    assert(result <= std.math.maxInt(i64));
    return .{ .int = @intCast(result) };
}

/// A decimal integer or float: optional sign, no leading zero, `_` only between digits.
fn parse_decimal(text: []const u8) Error!Value {
    assert(text.len > 0);
    var scratch: [number_text_max]u8 = undefined;
    const cleaned = try clean_decimal(text, &scratch);
    if (!number.is_decimal_literal(cleaned)) return error.InvalidNumber;
    if (has_leading_zero(cleaned)) return error.InvalidNumber;
    const result = try number.parse_decimal(cleaned);
    return switch (result) {
        .int, .float => result,
        .uint => error.IntegerAboveMax,
        // proof: `parse_decimal` returns `.int`, `.uint` or `.float` only.
        else => unreachable,
    };
}

/// Drops a leading `+` and every `_`, which must sit between two digits. Returns `text`
/// itself (minus the `+`) when it holds no underscore, else a prefix of `scratch`.
fn clean_decimal(text: []const u8, scratch: *[number_text_max]u8) Error![]const u8 {
    assert(text.len > 0);
    const body = if (text[0] == '+') text[1..] else text;
    if (body.len > 0 and body[0] == '-' and text[0] == '+') return error.InvalidNumber;
    if (std.mem.findScalar(u8, body, '_') == null) return body;
    if (body.len > number_text_max) return error.InvalidNumber;
    var len: usize = 0;
    for (body, 0..) |byte, index| {
        if (byte != '_') {
            scratch[len] = byte;
            len += 1;
            continue;
        }
        const between = index > 0 and index + 1 < body.len and
            is_digit(body[index - 1]) and is_digit(body[index + 1]);
        if (!between) return error.InvalidNumber;
    }
    assert(len < body.len);
    return scratch[0..len];
}

/// `0`, `-0`, `0.5` and `0e1` pass; `01`, `-01`, `00.5` do not.
fn has_leading_zero(cleaned: []const u8) bool {
    const digits = if (cleaned[0] == '-') cleaned[1..] else cleaned;
    assert(digits.len > 0);
    return digits.len > 1 and digits[0] == '0' and is_digit(digits[1]);
}

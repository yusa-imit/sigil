//! Tests for `toml/scalar.zig` and the lexer's date-time rejoin (plan 006 item 4).

const std = @import("std");
const core = @import("../core.zig");
const lexer_module = @import("lexer.zig");
const scalar = @import("scalar.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Value = core.Value;

fn expect_int(text: []const u8, want: i64) !void {
    const got = try scalar.parse(text);
    try expectEqual(want, got.int);
}

fn expect_float(text: []const u8, want: f64) !void {
    const got = try scalar.parse(text);
    try expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got.float)));
}

fn expect_failure(text: []const u8, err: scalar.Error) !void {
    try expectError(err, scalar.parse(text));
}

test "scalar: booleans" {
    try expect((try scalar.parse("true")).bool);
    try expect(!(try scalar.parse("false")).bool);
    try expect_failure("True", error.UnexpectedToken);
    try expect_failure("tru", error.UnexpectedToken);
    try expect_failure("falsey", error.UnexpectedToken);
}

test "scalar: spec decimal integers" {
    try expect_int("+99", 99);
    try expect_int("42", 42);
    try expect_int("0", 0);
    try expect_int("-17", -17);
    try expect_int("+0", 0);
    try expect_int("-0", 0);
    try expect_int("1_000", 1000);
    try expect_int("5_349_221", 5349221);
    try expect_int("53_49_221", 5349221);
    try expect_int("1_2_3_4_5", 12345);
}

test "scalar: spec radix integers" {
    try expect_int("0xDEADBEEF", 0xDEADBEEF);
    try expect_int("0xdeadbeef", 0xdeadbeef);
    try expect_int("0xdead_beef", 0xdeadbeef);
    try expect_int("0x00987", 0x987);
    try expect_int("0o01234567", 0o1234567);
    try expect_int("0o755", 493);
    try expect_int("0b11010110", 0b11010110);
    try expect_int("0b1_0", 2);
    try expect_int("0x0", 0);
}

test "scalar: i64 boundaries are exact and one past is a typed error" {
    try expect_int("9223372036854775807", std.math.maxInt(i64));
    try expect_int("-9223372036854775808", std.math.minInt(i64));
    try expect_failure("9223372036854775808", error.IntegerAboveMax);
    try expect_failure("18446744073709551615", error.IntegerAboveMax);
    try expect_failure("18446744073709551616", error.IntegerAboveMax);
    try expect_failure("-9223372036854775809", error.IntegerBelowMin);
    try expect_int("0x7FFFFFFFFFFFFFFF", std.math.maxInt(i64));
    try expect_failure("0x8000000000000000", error.IntegerAboveMax);
    try expect_failure("0xFFFFFFFFFFFFFFFFF", error.IntegerAboveMax);
    try expect_int("0o777777777777777777777", std.math.maxInt(i64));
    try expect_failure("0o1000000000000000000000", error.IntegerAboveMax);
    try expect_failure("0b1" ++ "0" ** 63, error.IntegerAboveMax);
    try expect_int("0b" ++ "1" ** 63, std.math.maxInt(i64));
}

test "scalar: malformed integers are InvalidNumber" {
    const bad = [_][]const u8{
        "1__0", "_1",     "1_",     "01",    "00",      "-01",   "+01",
        "0x_1", "0x1_",   "0x",     "0o",    "0b",      "0b2",   "0o8",
        "0xg",  "+0x1",   "-0x1",   "0X1",   "0B1",     "0O1",   "0x1__2",
        "1_.5", "1._5",   "1.5_",   "1e_5",  "1e5_",    "-",     "+",
        "1x",   "12abc",  "0_1",    "1-2",   "12345-1", "1.",    ".5",
        "1.e5", "1e",     "1e+",    "1.5.5", "1e5e5",   "0x1.5", "--1",
        "++1",  "+-1",    "0e",     "00.5",  "01.5",    "0b1_",  "0_",
        "1_e5", "0.5_e1", "5e1_0_", "1,5",   "0x1g",    "1\\5",  "1+5",
    };
    for (bad) |text| {
        expectError(error.InvalidNumber, scalar.parse(text)) catch |err| {
            std.log.err("scalar `{s}`: want InvalidNumber", .{text});
            return err;
        };
    }
}

test "scalar: spec floats" {
    try expect_float("+1.0", 1.0);
    try expect_float("3.1415", 3.1415);
    try expect_float("-0.01", -0.01);
    try expect_float("5e+22", 5e22);
    try expect_float("1e06", 1e6);
    try expect_float("-2E-2", -2e-2);
    try expect_float("6.626e-34", 6.626e-34);
    try expect_float("224_617.445_991_228", 224617.445991228);
    try expect_float("0.0", 0.0);
    try expect_float("-0.0", -0.0);
    try expect_float("+0.0", 0.0);
    try expect_float("0e0", 0.0);
    try expect_float("1_0e1_0", 1e11);
    try expect_float("9007199254740993.0", 9007199254740992.0);
}

test "scalar: inf and nan" {
    try expect_float("inf", std.math.inf(f64));
    try expect_float("+inf", std.math.inf(f64));
    try expect_float("-inf", -std.math.inf(f64));
    const nan_bits: u64 = 0x7ff8000000000000;
    try expectEqual(nan_bits, @as(u64, @bitCast((try scalar.parse("nan")).float)));
    try expectEqual(nan_bits, @as(u64, @bitCast((try scalar.parse("+nan")).float)));
    try expectEqual(nan_bits, @as(u64, @bitCast((try scalar.parse("-nan")).float)));
    try expect_failure("Inf", error.UnexpectedToken);
    try expect_failure("NaN", error.UnexpectedToken);
    try expect_failure("infinity", error.UnexpectedToken);
    try expect_failure("+nana", error.InvalidNumber);
    try expect_failure("+", error.InvalidNumber);
    try expect_failure("+abc", error.InvalidNumber);
}

test "scalar: a float past f64 is FloatOutOfRange, never inf" {
    try expect_failure("1e400", error.FloatOutOfRange);
    try expect_failure("-1e400", error.FloatOutOfRange);
    try expect_float("1e-400", 0.0);
    try expect_float("1.7976931348623157e308", std.math.floatMax(f64));
}

test "scalar: a float is never an integer and an integer never a float" {
    try expect(std.meta.activeTag(try scalar.parse("1")) == .int);
    try expect(std.meta.activeTag(try scalar.parse("1.0")) == .float);
    try expect(std.meta.activeTag(try scalar.parse("1e0")) == .float);
    try expect(std.meta.activeTag(try scalar.parse("0x1")) == .int);
}

test "scalar: a bad radix digit wins over overflow" {
    try expect_failure("0xFFFFFFFFFFFFFFFFFg", error.InvalidNumber);
    try expect_failure("0x8000000000000000_", error.InvalidNumber);
    try expect_failure("0x8000000000000000__1", error.InvalidNumber);
    try expect_failure("0b1" ++ "0" ** 70 ++ "2", error.InvalidNumber);
    try expect_failure("+_1", error.InvalidNumber);
    try expect_failure("1e+_5", error.InvalidNumber);
}

test "scalar: the underscore buffer edge is exactly number_text_max" {
    const edge = "0." ++ "0_" ** 254 ++ "01";
    try expectEqual(@as(usize, scalar.number_text_max), edge.len);
    try expect_float(edge, 1e-256);
    try expect_failure(edge ++ "0", error.InvalidNumber);
}

test "scalar: text longer than the underscore buffer" {
    const digits = "1_" ++ "0_" ** 300 ++ "1";
    try expect(digits.len > scalar.number_text_max);
    try expect_failure(digits, error.InvalidNumber);
    // Without underscores no copy is needed, so a long float is fine.
    const long_float = "0." ++ "0" ** 600 ++ "1";
    try expect_float(long_float, 0.0);
}

fn expect_stamp(text: []const u8, kind: core.Timestamp.Kind, seconds: i64, nanos: u32) !void {
    const got = (try scalar.parse(text)).timestamp;
    got.check_invariants();
    try expectEqual(kind, got.kind);
    try expectEqual(seconds, got.seconds);
    try expectEqual(nanos, got.nanoseconds);
}

test "scalar: spec datetimes, all four kinds" {
    try expect_stamp("1979-05-27T07:32:00Z", .instant, 296638320, 0);
    try expect_stamp("1979-05-27T00:32:00-07:00", .instant, 296638320, 0);
    try expect_stamp("1979-05-27T00:32:00.999999-07:00", .instant, 296638320, 999999000);
    try expect_stamp("1979-05-27 07:32:00Z", .instant, 296638320, 0);
    try expect_stamp("1979-05-27T07:32:00", .local_datetime, 296638320, 0);
    try expect_stamp("1979-05-27T00:32:00.999999", .local_datetime, 296613120, 999999000);
    try expect_stamp("1979-05-27", .local_date, 296611200, 0);
    try expect_stamp("07:32:00", .local_time, 27120, 0);
    try expect_stamp("00:32:00.999999", .local_time, 1920, 999999000);
}

test "scalar: datetime faults are InvalidDatetime" {
    const bad = [_][]const u8{
        "2023-02-29",                "1979-13-01", "1979-05-32",  "1979-05-27T25:00:00",
        "1979-05-27T07:60:00",       "07:32:60",   "1979-05-27T", "1979-5-27",
        "1979-05-27T07:32:00+24:00", "24:00:00",   "07:32",       "1979-05-27T07:32:00Zx",
    };
    for (bad) |text| {
        expectError(error.InvalidDatetime, scalar.parse(text)) catch |err| {
            std.log.err("scalar `{s}`: want InvalidDatetime", .{text});
            return err;
        };
    }
}

fn first_scalar(input: []const u8) ![]const u8 {
    var lexer: lexer_module.Lexer = undefined;
    try lexer.init(input);
    var diag = core.Diagnostics.init(0, 0, "untouched", null);
    const token = try lexer.next(&diag, .value);
    try expect(token.kind == .scalar);
    return token.raw;
}

test "lexer: a date, one space and a time are one scalar" {
    try expectEqualStrings("1979-05-27 07:32:00", try first_scalar("1979-05-27 07:32:00"));
    try expectEqualStrings("1979-05-27 07:32:00Z", try first_scalar("1979-05-27 07:32:00Z # c"));
    const offset_text = "1979-05-27 07:32:00-07:00";
    try expectEqualStrings(offset_text, try first_scalar(offset_text ++ ","));
    try expectEqualStrings("1979-05-27 00:32:00.5", try first_scalar("1979-05-27 00:32:00.5]"));
}

test "lexer: a date alone stays a scalar of its own" {
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27 # 07:32:00"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27 x"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27  07:32:00"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27\t07:32:00"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27 7:32:00"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27 07"));
    try expectEqualStrings("1979-05-27 07:", try first_scalar("1979-05-27 07:"));
    try expectEqualStrings("1979-05-27", try first_scalar("1979-05-27 \n07:32:00"));
}

test "lexer: the rejoin keeps the scalar checks on the time part" {
    var lexer: lexer_module.Lexer = undefined;
    try lexer.init("1979-05-27 07:32:00\x01");
    var diag = core.Diagnostics.init(0, 0, "untouched", null);
    try expectError(error.UnexpectedToken, lexer.next(&diag, .value));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 20), diag.col);
}

test "lexer then scalar: a document line classifies end to end" {
    const raw = try first_scalar("1979-05-27 07:32:00Z");
    const got = try scalar.parse(raw);
    try expectEqual(core.Timestamp.Kind.instant, got.timestamp.kind);
    try expectEqual(@as(i64, 296638320), got.timestamp.seconds);
}

test "scalar: parse never fails outside its error set on any short byte string" {
    var prng = std.Random.DefaultPrng.init(0x7011_0004);
    const random = prng.random();
    const alphabet = "0123456789+-_.eE xXoObBaAfFtTnNiI:Zz";
    var tally: u32 = 0;
    for (0..2000) |_| {
        var buf: [24]u8 = undefined;
        const len = random.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..len]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const text = buf[0..len];
        // proof: `Error` is the exhaustive set; a new variant must be listed here.
        _ = scalar.parse(text) catch |err| switch (err) {
            error.UnexpectedToken,
            error.InvalidNumber,
            error.InvalidDatetime,
            error.IntegerAboveMax,
            error.IntegerBelowMin,
            error.FloatOutOfRange,
            => {
                tally += 1;
                continue;
            },
        };
    }
    try expect(tally > 0);
    try expect(tally < 2000);
}

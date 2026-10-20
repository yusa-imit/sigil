//! core/timestamp — proleptic Gregorian civil date <-> days, and RFC 3339 / TOML datetime text
//! <-> `Timestamp` (ADR 0005 section 2). Shared by every format that writes a datetime
//! (TOML now, CBOR tag 0 later); format modules may not import each other, so it lives here.
//!
//! Invariants: years are `0000..9999`; a parsed `Timestamp` satisfies `check_invariants`;
//! `format(parse(text))` is the canonical spelling, and `parse(format(stamp))` returns `stamp`
//! except for an `instant` with no offset (CBOR tag 1), which is spelled `Z` and reads back
//! with `offset_minutes == 0`.
//! Allocation: none. Parsing is O(text.len); formatting writes at most `text_max` bytes into a
//! caller buffer. Cost per call: a handful of integer divisions, no tables.

const std = @import("std");
const assert = std.debug.assert;
const value = @import("value.zig");
const Timestamp = value.Timestamp;

/// Text that is not a datetime of the kinds in ADR 0005, or names an impossible calendar field
/// (`2023-02-29`, hour 24, a `:60` leap second); also `format` given a `Timestamp` whose civil
/// year falls outside `0000..9999` (a value from a caller, not text) and has no spelling.
pub const Error = error{InvalidDatetime};

/// Longest text `format` writes: `9999-12-31T23:59:59.999999999+23:59`.
pub const text_max: u32 = 35;
/// Days from 1970-01-01 to 0000-01-01 (negative) and to 9999-12-31.
pub const days_min: i64 = -719_528;
pub const days_max: i64 = 2_932_896;

/// Documents a condition that is legitimately sometimes true (Tiger Style 1.6).
fn maybe(ok: bool) void {
    _ = ok;
}

const seconds_per_day: i64 = 86_400;
const fraction_digits_max: u32 = 9;

pub const Civil = struct {
    /// `0..9999`.
    year: u16,
    /// `1..12`.
    month: u8,
    /// `1..days_in_month`.
    day: u8,
};

/// Leap years: divisible by 4, except centuries not divisible by 400 (2000 yes, 1900 no).
pub fn is_leap_year(year: u16) bool {
    assert(year <= 9999);
    const leap = if (year % 400 == 0) true else if (year % 100 == 0) false else year % 4 == 0;
    if (year % 4 != 0) assert(!leap);
    if (year % 400 == 0) assert(leap);
    return leap;
}

/// Precondition: `month` in `1..12`.
pub fn days_in_month(year: u16, month: u8) u8 {
    assert(month >= 1);
    assert(month <= 12);
    const lengths = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and is_leap_year(year)) return 29;
    return lengths[month - 1];
}

/// Days since 1970-01-01 of a civil date (negative before it). Hinnant's era algorithm.
/// Precondition: the date exists (`day` in `1..days_in_month`, `year <= 9999`).
pub fn days_from_civil(civil: Civil) i64 {
    assert(civil.month >= 1);
    assert(civil.month <= 12);
    assert(civil.day >= 1);
    assert(civil.day <= days_in_month(civil.year, civil.month));

    const shifted_year: i64 = @as(i64, civil.year) - @intFromBool(civil.month <= 2);
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_index: i64 = @mod(@as(i64, civil.month) + 9, 12);
    const day_of_year = @divFloor(153 * month_index + 2, 5) + civil.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146_097 + day_of_era - 719_468;
    assert(days >= days_min);
    assert(days <= days_max);
    return days;
}

/// Inverse of `days_from_civil`.
/// Precondition: `days_min <= days <= days_max`.
pub fn civil_from_days(days: i64) Civil {
    assert(days >= days_min);
    assert(days <= days_max);

    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) +
        @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);

    const civil: Civil = .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    };
    assert(civil.day <= days_in_month(civil.year, civil.month));
    return civil;
}

/// Parses one complete datetime token. The kind follows the shape: `YYYY-MM-DD` is
/// `local_date`, `HH:MM:SS[.f+]` is `local_time`, a date and time joined by `T`, `t` or one
/// space is `local_datetime`, and with a trailing `Z`, `z` or `+HH:MM`/`-HH:MM` it is
/// `instant`. Fraction digits past nine are truncated. The result satisfies `check_invariants`.
pub fn parse(text: []const u8) Error!Timestamp {
    if (text.len < 8) return error.InvalidDatetime;

    const stamp = if (text[2] == ':') try parse_time_only(text) else try parse_dated(text);
    stamp.check_invariants();
    assert((stamp.kind == .instant) == (stamp.offset_minutes != null));
    assert(stamp.nanoseconds < 1_000_000_000);
    return stamp;
}

fn parse_time_only(text: []const u8) Error!Timestamp {
    assert(text.len >= 8);
    assert(text[2] == ':');
    const time = try parse_time(text);
    if (time.len != text.len) return error.InvalidDatetime;
    return .{
        .kind = .local_time,
        .seconds = time.second_of_day,
        .nanoseconds = time.nanoseconds,
        .offset_minutes = null,
    };
}

fn parse_dated(text: []const u8) Error!Timestamp {
    assert(text.len >= 8);
    assert(text[2] != ':');
    const civil = try parse_date(text);
    const midnight = days_from_civil(civil) * seconds_per_day;
    if (text.len == 10) {
        return .{
            .kind = .local_date,
            .seconds = midnight,
            .nanoseconds = 0,
            .offset_minutes = null,
        };
    }

    switch (text[10]) {
        'T', 't', ' ' => {},
        else => return error.InvalidDatetime,
    }
    const time = try parse_time(text[11..]);
    const rest = text[11 + time.len ..];
    const seconds = midnight + time.second_of_day;
    if (rest.len == 0) {
        return .{
            .kind = .local_datetime,
            .seconds = seconds,
            .nanoseconds = time.nanoseconds,
            .offset_minutes = null,
        };
    }

    const offset = try parse_offset(rest);
    return .{
        .kind = .instant,
        .seconds = seconds - @as(i64, offset) * 60,
        .nanoseconds = time.nanoseconds,
        .offset_minutes = offset,
    };
}

fn parse_date(text: []const u8) Error!Civil {
    assert(text.len >= 8);
    if (text.len < 10) return error.InvalidDatetime;
    if (text[4] != '-') return error.InvalidDatetime;
    if (text[7] != '-') return error.InvalidDatetime;

    const year = try parse_digits(text[0..4]);
    const month = try parse_digits(text[5..7]);
    const day = try parse_digits(text[8..10]);
    if (month < 1) return error.InvalidDatetime;
    if (month > 12) return error.InvalidDatetime;
    if (day < 1) return error.InvalidDatetime;
    if (day > days_in_month(@intCast(year), @intCast(month))) return error.InvalidDatetime;
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

const Time = struct {
    second_of_day: u32,
    nanoseconds: u32,
    /// Bytes consumed, so the caller can find the offset after the time.
    len: usize,
};

fn parse_time(text: []const u8) Error!Time {
    maybe(text.len == 0);
    if (text.len < 8) return error.InvalidDatetime;
    if (text[2] != ':') return error.InvalidDatetime;
    if (text[5] != ':') return error.InvalidDatetime;

    const hour = try parse_digits(text[0..2]);
    const minute = try parse_digits(text[3..5]);
    const second = try parse_digits(text[6..8]);
    if (hour > 23) return error.InvalidDatetime;
    if (minute > 59) return error.InvalidDatetime;
    if (second > 59) return error.InvalidDatetime;

    var len: usize = 8;
    assert(len <= text.len);
    var nanoseconds: u32 = 0;
    if (len < text.len and text[len] == '.') {
        const fraction = try parse_fraction(text[len + 1 ..]);
        nanoseconds = fraction.nanoseconds;
        len += 1 + fraction.len;
    }
    return .{
        .second_of_day = hour * 3600 + minute * 60 + second,
        .nanoseconds = nanoseconds,
        .len = len,
    };
}

/// The digits right after the '.': at least one, all counted, the first nine kept.
fn parse_fraction(text: []const u8) Error!struct { nanoseconds: u32, len: usize } {
    var digit_count: usize = 0;
    var nanoseconds: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') break;
        if (digit_count < fraction_digits_max) nanoseconds = nanoseconds * 10 + (c - '0');
        digit_count += 1;
    }
    if (digit_count == 0) return error.InvalidDatetime;

    // Scale a short fraction up to nanoseconds: ".5" is 500_000_000.
    const kept: u32 = @intCast(@min(digit_count, fraction_digits_max));
    var scaled = nanoseconds;
    for (kept..fraction_digits_max) |_| scaled *= 10;
    assert(scaled < 1_000_000_000);
    return .{ .nanoseconds = scaled, .len = digit_count };
}

/// `Z`, `z`, `+HH:MM` or `-HH:MM` and nothing after it. `-00:00` equals `+00:00`.
fn parse_offset(text: []const u8) Error!i16 {
    assert(text.len > 0);
    if (text.len == 1) {
        if (text[0] == 'Z' or text[0] == 'z') return 0;
        return error.InvalidDatetime;
    }
    if (text.len != 6) return error.InvalidDatetime;
    if (text[3] != ':') return error.InvalidDatetime;

    const hour = try parse_digits(text[1..3]);
    const minute = try parse_digits(text[4..6]);
    if (hour > 23) return error.InvalidDatetime;
    if (minute > 59) return error.InvalidDatetime;
    const magnitude: i16 = @intCast(hour * 60 + minute);
    switch (text[0]) {
        '+' => return magnitude,
        '-' => return -magnitude,
        else => return error.InvalidDatetime,
    }
}

/// An unsigned decimal number of exactly `digits.len` ASCII digits (at most 4).
fn parse_digits(digits: []const u8) Error!u32 {
    assert(digits.len >= 1);
    assert(digits.len <= 4);
    var result: u32 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.InvalidDatetime;
        result = result * 10 + (c - '0');
    }
    return result;
}

/// Writes the canonical spelling into `out` and returns the used prefix: the shortest fraction
/// (none when zero), `Z` for an offset of zero or an `instant` without one, `+HH:MM` otherwise.
/// Precondition: `stamp.check_invariants()`. Returns `InvalidDatetime` when the civil date has
/// no four-digit year.
pub fn format(stamp: Timestamp, out: *[text_max]u8) Error![]const u8 {
    stamp.check_invariants();
    assert(out.len == text_max);
    if (stamp.kind == .local_time) return out[0..format_time(stamp, out)];

    const offset_seconds = @as(i64, stamp.offset_minutes orelse 0) * 60;
    const local_seconds = std.math.add(i64, stamp.seconds, offset_seconds) catch
        return error.InvalidDatetime;
    const days = @divFloor(local_seconds, seconds_per_day);
    if (days < days_min or days > days_max) return error.InvalidDatetime;

    const civil = civil_from_days(days);
    put_digits(out[0..4], civil.year);
    out[4] = '-';
    put_digits(out[5..7], civil.month);
    out[7] = '-';
    put_digits(out[8..10], civil.day);
    if (stamp.kind == .local_date) return out[0..10];

    out[10] = 'T';
    var used: usize = 11;
    var clock = stamp;
    clock.seconds = @mod(local_seconds, seconds_per_day);
    used += format_time(clock, out[11..]);
    if (stamp.kind == .local_datetime) return out[0..used];
    used += format_offset(stamp.offset_minutes orelse 0, out[used..]);
    assert(used <= text_max);
    return out[0..used];
}

/// Writes `HH:MM:SS[.f]` from `stamp.seconds` (seconds since midnight) and returns its length.
fn format_time(stamp: Timestamp, out: []u8) usize {
    assert(stamp.seconds >= 0);
    assert(stamp.seconds < seconds_per_day);
    assert(out.len >= 18);
    const second_of_day: u32 = @intCast(stamp.seconds);
    put_digits(out[0..2], @divFloor(second_of_day, 3600));
    out[2] = ':';
    put_digits(out[3..5], @divFloor(@mod(second_of_day, 3600), 60));
    out[5] = ':';
    put_digits(out[6..8], @mod(second_of_day, 60));
    if (stamp.nanoseconds == 0) return 8;

    out[8] = '.';
    put_digits(out[9..18], stamp.nanoseconds);
    var len: usize = 18;
    assert(out[len - 1] != 0);
    for (0..fraction_digits_max) |_| {
        if (out[len - 1] != '0') break;
        len -= 1;
    }
    assert(len > 9);
    return len;
}

/// Writes `Z` or `+HH:MM`/`-HH:MM` and returns its length.
fn format_offset(offset_minutes: i16, out: []u8) usize {
    assert(out.len >= 6);
    assert(offset_minutes >= -1439);
    assert(offset_minutes <= 1439);
    if (offset_minutes == 0) {
        out[0] = 'Z';
        return 1;
    }
    const magnitude: u32 = @abs(offset_minutes);
    out[0] = if (offset_minutes < 0) '-' else '+';
    put_digits(out[1..3], @divFloor(magnitude, 60));
    out[3] = ':';
    put_digits(out[4..6], @mod(magnitude, 60));
    return 6;
}

/// Writes `number` zero-padded into all of `out`. Precondition: it fits.
fn put_digits(out: []u8, number: u32) void {
    var rest = number;
    var index = out.len;
    for (0..out.len) |_| {
        index -= 1;
        out[index] = '0' + @as(u8, @intCast(@mod(rest, 10)));
        rest = @divFloor(rest, 10);
    }
    assert(rest == 0);
}

const testing = std.testing;

fn expect_text(expected: []const u8, stamp: Timestamp) !void {
    var buffer: [text_max]u8 = undefined;
    try testing.expectEqualStrings(expected, try format(stamp, &buffer));
}

fn expect_parse_format(text: []const u8, expected: Timestamp, canonical: []const u8) !void {
    const stamp = try parse(text);
    try testing.expectEqual(expected, stamp);
    try expect_text(canonical, stamp);
}

test "timestamp: the epoch and the extremes of the day range" {
    try testing.expectEqual(@as(i64, 0), days_from_civil(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(days_min, days_from_civil(.{ .year = 0, .month = 1, .day = 1 }));
    try testing.expectEqual(days_max, days_from_civil(.{ .year = 9999, .month = 12, .day = 31 }));
    try testing.expectEqual(
        Civil{ .year = 1, .month = 1, .day = 1 },
        civil_from_days(-719_162),
    );
    try testing.expectEqual(
        Civil{ .year = 9999, .month = 12, .day = 31 },
        civil_from_days(days_max),
    );
}

test "timestamp: leap years, Feb 29 in 2000 versus 1900" {
    try testing.expect(is_leap_year(2000));
    try testing.expect(!is_leap_year(1900));
    try testing.expect(is_leap_year(2024));
    try testing.expect(!is_leap_year(2023));
    try testing.expect(is_leap_year(0));
    try testing.expectEqual(@as(u8, 29), days_in_month(2000, 2));
    try testing.expectEqual(@as(u8, 28), days_in_month(1900, 2));
    _ = try parse("2000-02-29");
    try testing.expectError(error.InvalidDatetime, parse("1900-02-29"));
    try testing.expectError(error.InvalidDatetime, parse("2023-02-29"));
    try testing.expectError(error.InvalidDatetime, parse("2023-04-31"));
}

test "timestamp: every kind parses and formats back to its canonical text" {
    try expect_parse_format("1979-05-27", .{
        .kind = .local_date,
        .seconds = 296_611_200,
        .nanoseconds = 0,
        .offset_minutes = null,
    }, "1979-05-27");
    try expect_parse_format("07:32:00.5", .{
        .kind = .local_time,
        .seconds = 27_120,
        .nanoseconds = 500_000_000,
        .offset_minutes = null,
    }, "07:32:00.5");
    try expect_parse_format("1979-05-27t07:32:00", .{
        .kind = .local_datetime,
        .seconds = 296_638_320,
        .nanoseconds = 0,
        .offset_minutes = null,
    }, "1979-05-27T07:32:00");
    try expect_parse_format("1979-05-27 00:32:00.999999z", .{
        .kind = .instant,
        .seconds = 296_613_120,
        .nanoseconds = 999_999_000,
        .offset_minutes = 0,
    }, "1979-05-27T00:32:00.999999Z");
    try expect_parse_format("1979-05-27T00:32:00-07:00", .{
        .kind = .instant,
        .seconds = 296_638_320,
        .nanoseconds = 0,
        .offset_minutes = -420,
    }, "1979-05-27T00:32:00-07:00");
}

test "timestamp: offsets at the limits, and -00:00 equals +00:00" {
    const east = try parse("2000-01-01T00:00:00+23:59");
    try testing.expectEqual(@as(?i16, 1439), east.offset_minutes);
    try testing.expectEqual(@as(i64, 946_684_800 - 1439 * 60), east.seconds);
    const west = try parse("2000-01-01T00:00:00-23:59");
    try testing.expectEqual(@as(?i16, -1439), west.offset_minutes);
    try testing.expectEqual(@as(i64, 946_684_800 + 1439 * 60), west.seconds);
    const plus = try parse("2000-01-01T00:00:00+00:00");
    try testing.expectEqual(plus, try parse("2000-01-01T00:00:00-00:00"));
    try expect_text("2000-01-01T00:00:00+23:59", east);
    try expect_text("2000-01-01T00:00:00-23:59", west);
}

test "timestamp: nine fraction digits kept, more truncated, trailing zeros dropped" {
    const exact = try parse("12:00:00.123456789");
    try testing.expectEqual(@as(u32, 123_456_789), exact.nanoseconds);
    const longer = try parse("12:00:00.1234567899999");
    try testing.expectEqual(@as(u32, 123_456_789), longer.nanoseconds);
    const short = try parse("12:00:00.000000001");
    try testing.expectEqual(@as(u32, 1), short.nanoseconds);
    try expect_text("12:00:00.000000001", short);
    const zeros = try parse("12:00:00.500");
    try expect_text("12:00:00.5", zeros);
    try expect_text("12:00:00", try parse("12:00:00.000"));
}

test "timestamp: the first and last representable instants round-trip" {
    var buffer: [text_max]u8 = undefined;
    const first = try parse("0000-01-01T00:00:00Z");
    try testing.expectEqual(days_min * seconds_per_day, first.seconds);
    try testing.expectEqualStrings("0000-01-01T00:00:00Z", try format(first, &buffer));
    const last = try parse("9999-12-31T23:59:59.999999999Z");
    try testing.expectEqual(days_max * seconds_per_day + 86_399, last.seconds);
    const text = try format(last, &buffer);
    try testing.expectEqualStrings("9999-12-31T23:59:59.999999999Z", text);
    try testing.expectEqual(@as(usize, text_max - 5), text.len);
    const widest = try parse("9999-12-31T23:59:59.999999999+23:59");
    try testing.expectEqual(@as(usize, text_max), (try format(widest, &buffer)).len);
}

test "timestamp: malformed and impossible text is InvalidDatetime" {
    const bad = [_][]const u8{
        "",
        "1979-05-2",
        "1979-5-27",
        "1979-05-27x",
        "1979-05-27T",
        "1979-05-27T07:32",
        "1979-05-27T07:32:00.",
        "1979-05-27T07:32:00.Z",
        "1979-05-27T24:00:00",
        "1979-05-27T07:60:00",
        "1979-05-27T07:32:60",
        "1979-13-01",
        "1979-00-01",
        "1979-01-00",
        "1979-01-32",
        "1979-05-27T07:32:00+24:00",
        "1979-05-27T07:32:00+07:60",
        "1979-05-27T07:32:00+0700",
        "1979-05-27T07:32:00 Z",
        "1979-05-27T07:32:00ZZ",
        "1979-05-27_07:32:00",
        "197a-05-27",
        "+979-05-27",
        "07:32:00Z",
        "07:32:00+01:00",
        "07-32-00",
        "7:32:00.5",
    };
    for (bad) |text| {
        testing.expectError(error.InvalidDatetime, parse(text)) catch |err| {
            std.log.err("accepted: {s}", .{text});
            return err;
        };
    }
}

test "timestamp: format rejects a civil year outside 0000..9999" {
    var buffer: [text_max]u8 = undefined;
    const beyond: Timestamp = .{
        .kind = .instant,
        .seconds = (days_max + 1) * seconds_per_day,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    try testing.expectError(error.InvalidDatetime, format(beyond, &buffer));
    const before: Timestamp = .{
        .kind = .instant,
        .seconds = days_min * seconds_per_day - 1,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    try testing.expectError(error.InvalidDatetime, format(before, &buffer));
    const extreme: Timestamp = .{
        .kind = .instant,
        .seconds = std.math.maxInt(i64),
        .nanoseconds = 0,
        .offset_minutes = 1,
    };
    try testing.expectError(error.InvalidDatetime, format(extreme, &buffer));
    // The offset moves the civil date: 9999-12-31T23:59:59-00:01 is a year-10000 UTC instant
    // whose local spelling still has four digits.
    const edge = try parse("9999-12-31T23:59:59-00:01");
    try expect_text("9999-12-31T23:59:59-00:01", edge);
}

test "timestamp: an instant without an offset is spelled Z and reads back as offset 0" {
    const none: Timestamp = .{
        .kind = .instant,
        .seconds = 86_400,
        .nanoseconds = 0,
        .offset_minutes = null,
    };
    try expect_text("1970-01-02T00:00:00Z", none);
    const back = try parse("1970-01-02T00:00:00Z");
    try testing.expectEqual(@as(?i16, 0), back.offset_minutes);
    try testing.expectEqual(none.seconds, back.seconds);
}

test "timestamp: check_invariants accepts a parsed value of every kind" {
    const texts = [_][]const u8{
        "2020-02-29",
        "23:59:59.9",
        "2020-02-29T01:02:03",
        "2020-02-29T01:02:03Z",
    };
    for (texts) |text| (try parse(text)).check_invariants();
}

/// Reference day counter: walks whole years and months from 1970, no closed-form arithmetic.
fn naive_days(civil: Civil) i64 {
    var days: i64 = 0;
    if (civil.year >= 1970) {
        var year: u16 = 1970;
        while (year < civil.year) : (year += 1) days += if (is_leap_year(year)) 366 else 365;
    } else {
        var year: u16 = civil.year;
        while (year < 1970) : (year += 1) days -= if (is_leap_year(year)) 366 else 365;
    }
    var month: u8 = 1;
    while (month < civil.month) : (month += 1) days += days_in_month(civil.year, month);
    return days + civil.day - 1;
}

test "timestamp: model test against a naive day counter, 1,000 seeds" {
    var buffer: [text_max]u8 = undefined;
    for (0..1000) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const days = rng.intRangeAtMost(i64, days_min, days_max);
        const civil = civil_from_days(days);
        testing.expectEqual(days, naive_days(civil)) catch |err| {
            std.log.err("seed {d}: days {d}", .{ seed, days });
            return err;
        };
        try testing.expectEqual(days, days_from_civil(civil));

        const kind = rng.enumValue(Timestamp.Kind);
        const offset: i16 = rng.intRangeAtMost(i16, -1439, 1439);
        const stamp: Timestamp = switch (kind) {
            .instant => .{
                .kind = kind,
                .seconds = days * seconds_per_day + rng.uintLessThan(u32, 86_400) -
                    @as(i64, offset) * 60,
                .nanoseconds = if (rng.boolean()) rng.uintLessThan(u32, 1_000_000_000) else 0,
                .offset_minutes = offset,
            },
            .local_datetime => .{
                .kind = kind,
                .seconds = days * seconds_per_day + rng.uintLessThan(u32, 86_400),
                .nanoseconds = rng.uintLessThan(u32, 1_000_000_000),
                .offset_minutes = null,
            },
            .local_date => .{
                .kind = kind,
                .seconds = days * seconds_per_day,
                .nanoseconds = 0,
                .offset_minutes = null,
            },
            .local_time => .{
                .kind = kind,
                .seconds = rng.uintLessThan(u32, 86_400),
                .nanoseconds = rng.uintLessThan(u32, 1_000_000_000),
                .offset_minutes = null,
            },
        };
        // The local civil date is `days` for every kind, so the year is always in range.
        const text = try format(stamp, &buffer);
        const again = try parse(text);
        testing.expectEqual(stamp, again) catch |err| {
            std.log.err("seed {d}: {s}", .{ seed, text });
            return err;
        };
    }
}

//! core/unicode — strict UTF-8 validation with a byte offset and a reason, so a parser can fill
//! `Diagnostics.col` (plan 003 item 1). Strict means Unicode Table 3-7 ("Well-Formed UTF-8 Byte
//! Sequences"): no overlong forms, no surrogates (U+D800..U+DFFF), nothing above U+10FFFF.
//! Noncharacters (U+FFFE, U+FFFF, ...) and U+0000 are well-formed and accepted. Allocation:
//! none. Cost: O(bytes.len).
//!
//! Reason semantics (every choice the spec leaves open is pinned here and by tests):
//!   * `offset` is always the byte offset of the FIRST byte of the first invalid sequence.
//!   * The lead byte is judged first, then the second byte against the Table 3-7 range of that
//!     lead, then the remaining continuation bytes. The first failing check names the reason.
//!   * `overlong`: lead C0 or C1; or E0 followed by 80..9F; or F0 followed by 80..8F.
//!   * `surrogate`: ED followed by A0..BF.
//!   * `above_max`: F4 followed by 90..BF; or lead F5..FF.
//!   * `stray_continuation`: 80..BF where a lead byte was expected.
//!   * `truncated`: a lead in C2..F4 whose sequence is not completed by continuation bytes, be
//!     it because the input ended or because a non-continuation byte came first (that byte is
//!     NOT part of the invalid sequence; the offset stays at the lead). A second byte outside
//!     80..BF never yields overlong/surrogate/above_max: those need a continuation byte that is
//!     merely out of the lead's Table 3-7 range (`E0 80` is overlong, `E0 41` is truncated).
//!   * A second byte in the lead's legal range followed by input end is `truncated`; a second
//!     byte out of range is judged before the input end, so `E0 80` alone is `overlong`.

const std = @import("std");
const assert = std.debug.assert;

pub const InvalidReason = enum { overlong, surrogate, above_max, truncated, stray_continuation };

/// Where and why `find_invalid` rejected the input. `offset` is a `u32`, which is why longer
/// inputs are refused up front (`Error.InputTooLarge`).
pub const Invalid = struct { offset: u32, reason: InvalidReason };

/// `InputTooLarge`: the input is longer than maxInt(u32) bytes, so an offset could not be
/// reported. It is data (a caller can hand us a 5 GiB mapping), not a contract violation.
pub const Error = error{InputTooLarge};

/// The length gate behind `find_invalid`, split out so the `InputTooLarge` variant can be
/// provoked without a 4 GiB allocation. Takes `u64` so the seam is total on 32-bit targets too.
/// Returns `len` as `u32` when `len <= maxInt(u32)`, else `error.InputTooLarge`.
pub fn check_len(len: u64) Error!u32 {
    if (len > std.math.maxInt(u32)) {
        return error.InputTooLarge;
    }
    assert(len <= std.math.maxInt(u32));
    const len_u32: u32 = @intCast(len);
    assert(len_u32 == len);
    return len_u32;
}

/// Returns null if `bytes` is valid UTF-8 (Unicode Table 3-7, strict), else the byte offset of
/// the first byte of the first invalid sequence and why. `error.InputTooLarge` iff
/// `bytes.len > maxInt(u32)`; checked before any byte is read. Total on every other input.
pub fn find_invalid(bytes: []const u8) Error!?Invalid {
    const len = try check_len(bytes.len);

    var index: u32 = 0;
    while (index < len) {
        if (bytes[index] < 0x80) {
            index += 1;
            continue;
        }
        switch (check_sequence(bytes, index)) {
            .ok => |sequence_len| {
                assert(sequence_len >= 2);
                assert(sequence_len <= 4);
                assert(@as(u64, index) + sequence_len <= len);
                index += sequence_len;
            },
            .invalid => |reason| return .{ .offset = index, .reason = reason },
        }
    }
    assert(index == len);
    return null;
}

const Sequence = union(enum) {
    ok: u32,
    invalid: InvalidReason,
};

/// What Table 3-7 says about a lead byte: how many continuation bytes follow, the legal range of
/// the first one, and the reason if that first one is a continuation but out of range.
const Lead = struct {
    continuation_count: u32,
    second_lo: u8,
    second_hi: u8,
    below_reason: InvalidReason,
    above_reason: InvalidReason,
};

const LeadClass = union(enum) { valid: Lead, invalid: InvalidReason };

/// Table 3-7 classification of a non-ASCII lead byte. Precondition: `lead >= 0x80`.
fn lead_classify(lead: u8) LeadClass {
    assert(lead >= 0x80);
    const continuation_lo: u8 = 0x80;
    const continuation_hi: u8 = 0xBF;
    return switch (lead) {
        0x80...0xBF => .{ .invalid = .stray_continuation },
        0xC0, 0xC1 => .{ .invalid = .overlong },
        0xF5...0xFF => .{ .invalid = .above_max },
        0xC2...0xDF => .{ .valid = .{
            .continuation_count = 1,
            .second_lo = continuation_lo,
            .second_hi = continuation_hi,
            .below_reason = .truncated,
            .above_reason = .truncated,
        } },
        0xE0 => .{ .valid = .{
            .continuation_count = 2,
            .second_lo = 0xA0,
            .second_hi = continuation_hi,
            .below_reason = .overlong,
            .above_reason = .truncated,
        } },
        0xED => .{ .valid = .{
            .continuation_count = 2,
            .second_lo = continuation_lo,
            .second_hi = 0x9F,
            .below_reason = .truncated,
            .above_reason = .surrogate,
        } },
        0xF0 => .{ .valid = .{
            .continuation_count = 3,
            .second_lo = 0x90,
            .second_hi = continuation_hi,
            .below_reason = .overlong,
            .above_reason = .truncated,
        } },
        0xF4 => .{ .valid = .{
            .continuation_count = 3,
            .second_lo = continuation_lo,
            .second_hi = 0x8F,
            .below_reason = .truncated,
            .above_reason = .above_max,
        } },
        0xE1...0xEC, 0xEE, 0xEF, 0xF1...0xF3 => .{ .valid = .{
            .continuation_count = if (lead >= 0xF1) 3 else 2,
            .second_lo = continuation_lo,
            .second_hi = continuation_hi,
            .below_reason = .truncated,
            .above_reason = .truncated,
        } },
        // Unreachable after the precondition assert: every 0x80..0xFF lead is an arm above.
        0x00...0x7F => unreachable,
    };
}

fn is_continuation_byte(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

/// Judges the multi-byte sequence starting at `bytes[index]`.
/// Precondition: `index < bytes.len` and `bytes[index] >= 0x80` (ASCII is the caller's fast path).
fn check_sequence(bytes: []const u8, index: u32) Sequence {
    assert(index < bytes.len);
    assert(bytes[index] >= 0x80);

    const lead = switch (lead_classify(bytes[index])) {
        .invalid => |reason| return .{ .invalid = reason },
        .valid => |lead| lead,
    };
    assert(lead.continuation_count >= 1);
    assert(lead.continuation_count <= 3);

    const second_index = @as(usize, index) + 1;
    if (second_index >= bytes.len) return .{ .invalid = .truncated };
    const second = bytes[second_index];
    if (!is_continuation_byte(second)) return .{ .invalid = .truncated };
    if (second < lead.second_lo) return .{ .invalid = lead.below_reason };
    if (second > lead.second_hi) return .{ .invalid = lead.above_reason };

    var position: u32 = 2;
    while (position <= lead.continuation_count) : (position += 1) {
        const next_index = @as(usize, index) + position;
        if (next_index >= bytes.len) return .{ .invalid = .truncated };
        if (!is_continuation_byte(bytes[next_index])) return .{ .invalid = .truncated };
    }
    return .{ .ok = lead.continuation_count + 1 };
}

// ---------------------------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn expect_valid(bytes: []const u8) !void {
    // Guard the test data itself: a typo in a hand-encoded fixture must not pass silently.
    try expect(std.unicode.utf8ValidateSlice(bytes));
    try expectEqual(@as(?Invalid, null), try find_invalid(bytes));
}

fn expect_invalid(bytes: []const u8, offset: u32, reason: InvalidReason) !void {
    try expect(!std.unicode.utf8ValidateSlice(bytes));
    const found = (try find_invalid(bytes)) orelse return error.TestExpectedInvalid;
    try expectEqual(offset, found.offset);
    try expectEqual(reason, found.reason);
}

/// The reasons a given lead byte may legally produce (from the header table).
fn reason_fits_lead(lead: u8, reason: InvalidReason) bool {
    return switch (lead) {
        0x00...0x7F => false, // ASCII is never the start of an invalid sequence
        0x80...0xBF => reason == .stray_continuation,
        0xC0, 0xC1 => reason == .overlong,
        0xF5...0xFF => reason == .above_max,
        0xE0, 0xF0 => reason == .overlong or reason == .truncated,
        0xED => reason == .surrogate or reason == .truncated,
        0xF4 => reason == .above_max or reason == .truncated,
        else => reason == .truncated, // C2..DF, E1..EC, EE, EF, F1..F3
    };
}

/// The differential oracle: `find_invalid` agrees with std on validity, and any reported
/// offset is the start of a sequence that is really not a well-formed character, preceded by a
/// well-formed prefix, with a reason that its lead byte allows.
fn check_agreement(bytes: []const u8) !void {
    const found = try find_invalid(bytes);
    const std_valid = std.unicode.utf8ValidateSlice(bytes);
    try expectEqual(std_valid, found == null);
    const invalid = found orelse return;

    try expect(invalid.offset < bytes.len);
    const offset: usize = invalid.offset;
    try expect(std.unicode.utf8ValidateSlice(bytes[0..offset]));
    try expect(reason_fits_lead(bytes[offset], invalid.reason));

    const seq_len = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch 1;
    const complete = offset + seq_len <= bytes.len;
    const well_formed = complete and std.unicode.utf8ValidateSlice(bytes[offset..][0..seq_len]);
    try expect(!well_formed);
}

/// Each case is checked alone (offset 0), after a 3-byte valid prefix "a" + U+00E9 (offset 3),
/// and with a valid ASCII suffix that must neither move the offset nor change the reason.
fn expect_invalid_in_context(seq: []const u8, reason: InvalidReason) !void {
    const prefix = "a\xC3\xA9";
    var buf: [16]u8 = undefined;
    assert(prefix.len + seq.len + 1 <= buf.len);

    try expect_invalid(seq, 0, reason);

    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..seq.len], seq);
    const with_prefix = buf[0 .. prefix.len + seq.len];
    try expect_invalid(with_prefix, prefix.len, reason);

    buf[with_prefix.len] = 'z';
    try expect_invalid(buf[0 .. with_prefix.len + 1], prefix.len, reason);
}

// ---------------------------------------------------------------------------------------------
// Positive contract
// ---------------------------------------------------------------------------------------------

test "find_invalid: empty input is valid" {
    try expectEqual(@as(?Invalid, null), try find_invalid(""));
}

test "find_invalid: every single ASCII byte is valid" {
    var byte: u8 = 0;
    while (byte < 0x80) : (byte += 1) try expect_valid(&.{byte});
}

const Boundary = struct { cp: u21, bytes: []const u8 };

/// Both edges of each Table 3-7 row, encoded by hand (not by calling an encoder).
const valid_boundaries = [_]Boundary{
    .{ .cp = 0x0000, .bytes = "\x00" },
    .{ .cp = 0x007F, .bytes = "\x7F" },
    .{ .cp = 0x0080, .bytes = "\xC2\x80" },
    .{ .cp = 0x07FF, .bytes = "\xDF\xBF" },
    .{ .cp = 0x0800, .bytes = "\xE0\xA0\x80" },
    .{ .cp = 0xD7FF, .bytes = "\xED\x9F\xBF" },
    .{ .cp = 0xE000, .bytes = "\xEE\x80\x80" },
    .{ .cp = 0xFFFD, .bytes = "\xEF\xBF\xBD" },
    .{ .cp = 0xFFFE, .bytes = "\xEF\xBF\xBE" }, // noncharacter: well-formed
    .{ .cp = 0xFFFF, .bytes = "\xEF\xBF\xBF" },
    .{ .cp = 0x10000, .bytes = "\xF0\x90\x80\x80" },
    .{ .cp = 0x3FFFF, .bytes = "\xF0\xBF\xBF\xBF" },
    .{ .cp = 0x40000, .bytes = "\xF1\x80\x80\x80" },
    .{ .cp = 0xFFFFF, .bytes = "\xF3\xBF\xBF\xBF" },
    .{ .cp = 0x100000, .bytes = "\xF4\x80\x80\x80" },
    .{ .cp = 0x10FFFF, .bytes = "\xF4\x8F\xBF\xBF" },
};

test "test data: hand-encoded boundary bytes match std.unicode.utf8Encode" {
    for (valid_boundaries) |b| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(b.cp, &buf);
        try std.testing.expectEqualSlices(u8, b.bytes, buf[0..n]);
    }
}

test "find_invalid: every Table 3-7 boundary codepoint is valid alone, prefixed, suffixed" {
    for (valid_boundaries) |b| {
        try expect_valid(b.bytes);
        var buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "a{s}z", .{b.bytes});
        try expect_valid(text);
    }
}

test "find_invalid: mixed 1-, 2-, 3- and 4-byte text is valid" {
    try expect_valid("plain ascii, then \xC3\xA9 (e-acute), \xE2\x82\xAC (euro), \xF0\x9F\x98\x80");
    try expect_valid("\xF0\x9F\x98\x80\xE2\x82\xAC\xC3\xA9a"); // longest first, shortest last
    try expect_valid("\xEF\xBB\xBF"); // BOM is an ordinary U+FEFF
}

// ---------------------------------------------------------------------------------------------
// Negative space: each reason, boundary, valid-becoming-invalid
// ---------------------------------------------------------------------------------------------

test "find_invalid: every lone byte 0x80..0xFF is invalid with the reason its class implies" {
    var byte: u16 = 0x80;
    while (byte <= 0xFF) : (byte += 1) {
        const b: u8 = @intCast(byte);
        const expected: InvalidReason = switch (b) {
            0x80...0xBF => .stray_continuation,
            0xC0, 0xC1 => .overlong,
            0xC2...0xF4 => .truncated,
            0xF5...0xFF => .above_max,
            else => unreachable,
        };
        try expect_invalid(&.{b}, 0, expected);
    }
}

test "find_invalid: surrogate edges D800, DBFF, DC00, DFFF are surrogate; D7FF and E000 valid" {
    try expect_invalid_in_context("\xED\xA0\x80", .surrogate); // U+D800
    try expect_invalid_in_context("\xED\xAF\xBF", .surrogate); // U+DBFF
    try expect_invalid_in_context("\xED\xB0\x80", .surrogate); // U+DC00
    try expect_invalid_in_context("\xED\xBF\xBF", .surrogate); // U+DFFF
    try expect_valid("\xED\x9F\xBF"); // U+D7FF
    try expect_valid("\xEE\x80\x80"); // U+E000
}

test "find_invalid: a CESU-8 style surrogate pair is rejected at its first half" {
    // U+1F600 as two 3-byte surrogates (D83D DE00): the classic non-UTF-8 producer.
    try expect_invalid("\xED\xA0\xBD\xED\xB8\x80", 0, .surrogate);
    try expect_invalid("ab\xED\xA0\xBD\xED\xB8\x80", 2, .surrogate);
}

test "find_invalid: above U+10FFFF is above_max for F4 90.. and every lead F5..FF" {
    try expect_invalid_in_context("\xF4\x90\x80\x80", .above_max); // U+110000
    try expect_invalid_in_context("\xF4\xBF\xBF\xBF", .above_max); // U+13FFFF
    try expect_invalid_in_context("\xF5\x80\x80\x80", .above_max);
    try expect_invalid_in_context("\xF7\xBF\xBF\xBF", .above_max); // U+1FFFFF
    try expect_invalid_in_context("\xF8\x88\x80\x80\x80", .above_max); // old 5-byte form
    try expect_invalid_in_context("\xFC\x84\x80\x80\x80\x80", .above_max); // old 6-byte form
    try expect_invalid_in_context("\xFE", .above_max);
    try expect_invalid_in_context("\xFF", .above_max);
}

test "find_invalid: overlong encodings are overlong at every length" {
    try expect_invalid_in_context("\xC0\x80", .overlong); // NUL in 2 bytes
    try expect_invalid_in_context("\xC0\xAF", .overlong); // '/' in 2 bytes
    try expect_invalid_in_context("\xC1\xBF", .overlong); // U+007F in 2 bytes
    try expect_invalid_in_context("\xE0\x80\x80", .overlong);
    try expect_invalid_in_context("\xE0\x9F\xBF", .overlong); // U+07FF in 3 bytes
    try expect_invalid_in_context("\xF0\x80\x80\x80", .overlong);
    try expect_invalid_in_context("\xF0\x8F\xBF\xBF", .overlong); // U+FFFF in 4 bytes
    try expect_valid("\xC2\x80"); // the shortest legal 2-byte form is next to C1 BF
    try expect_valid("\xE0\xA0\x80");
    try expect_valid("\xF0\x90\x80\x80");
}

test "find_invalid: C0 and C1 leads are overlong at input end or before a non-continuation" {
    try expect_invalid("\xC0", 0, .overlong);
    try expect_invalid("\xC1", 0, .overlong);
    try expect_invalid("\xC0A", 0, .overlong);
    try expect_invalid("x\xC1", 1, .overlong);
}

test "find_invalid: stray continuation bytes where a lead was expected" {
    try expect_invalid_in_context("\x80", .stray_continuation);
    try expect_invalid_in_context("\xBF", .stray_continuation);
    try expect_invalid("\xC3\xA9\x80", 2, .stray_continuation); // extra byte after a full char
    try expect_invalid("\xF0\x9F\x98\x80\xA0", 4, .stray_continuation);
    try expect_invalid("\x80\x80", 0, .stray_continuation); // first one wins
}

test "find_invalid: truncated at end of input reports the lead byte offset" {
    try expect_invalid_in_context("\xC3", .truncated); // context adds a suffix: non-continuation
    try expect_invalid("\xC3", 0, .truncated);
    try expect_invalid("ab\xE2\x82", 2, .truncated); // euro missing its last byte
    try expect_invalid("ab\xE2", 2, .truncated);
    try expect_invalid("ab\xF0\x9F\x98", 2, .truncated);
    try expect_invalid("ab\xF0\x9F", 2, .truncated);
    try expect_invalid("ab\xF0", 2, .truncated);
}

test "find_invalid: every proper prefix of a multi-byte character is truncated at its lead" {
    const chars = [_][]const u8{ "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80" };
    for (chars) |ch| {
        var len: usize = 1;
        while (len < ch.len) : (len += 1) {
            var buf: [8]u8 = undefined;
            @memcpy(buf[0..2], "ab");
            @memcpy(buf[2..][0..len], ch[0..len]);
            try expect_invalid(buf[0 .. 2 + len], 2, .truncated); // ends the input
            buf[2 + len] = 'z';
            try expect_invalid(buf[0 .. 3 + len], 2, .truncated); // non-continuation follows
            buf[2 + len] = 0xC3;
            try expect_invalid(buf[0 .. 3 + len], 2, .truncated); // a new lead follows
        }
    }
}

test "find_invalid: lead followed by a non-continuation is truncated, the byte is not consumed" {
    try expect_invalid("\xC3\x41", 0, .truncated);
    try expect_invalid("\xE2\x82\x41", 0, .truncated); // third byte bad
    try expect_invalid("\xE2\x41\x82", 0, .truncated); // second byte bad
    try expect_invalid("\xF0\x9F\x98\x41", 0, .truncated);
    try expect_invalid("\xC3\xC3\xA9", 0, .truncated); // the second C3 starts a valid char
    try expect_invalid("\xC3\xFF", 0, .truncated);
    try expect_invalid("\xE0\xA0\x41", 0, .truncated); // legal second byte, bad third
    try expect_invalid("\xED\x9F\x41", 0, .truncated);
    try expect_invalid("\xF4\x8F\xBF\x41", 0, .truncated);
}

test "find_invalid: second byte is judged against the lead's range before the input end" {
    try expect_invalid("\xE0\x80", 0, .overlong); // out of range, though input is short
    try expect_invalid("\xE0\x9F", 0, .overlong);
    try expect_invalid("\xE0\xA0", 0, .truncated); // in range, input ends
    try expect_invalid("\xE0\x41", 0, .truncated); // not a continuation at all
    try expect_invalid("\xE0\xC0", 0, .truncated);
    try expect_invalid("\xED\xA0", 0, .surrogate);
    try expect_invalid("\xED\x9F", 0, .truncated);
    try expect_invalid("\xED\xC2", 0, .truncated);
    try expect_invalid("\xF0\x8F", 0, .overlong);
    try expect_invalid("\xF0\x90", 0, .truncated);
    try expect_invalid("\xF4\x90", 0, .above_max);
    try expect_invalid("\xF4\x8F", 0, .truncated);
    try expect_invalid("\xF4\xC0", 0, .truncated);
    try expect_invalid("\xE0\x80\x41", 0, .overlong); // range failure wins over the bad third
}

test "find_invalid: second-byte sweep matches Table 3-7 for the four restricted leads" {
    const Row = struct { lead: u8, lo: u8, hi: u8, out_of_range: InvalidReason };
    const rows = [_]Row{
        .{ .lead = 0xE0, .lo = 0xA0, .hi = 0xBF, .out_of_range = .overlong },
        .{ .lead = 0xED, .lo = 0x80, .hi = 0x9F, .out_of_range = .surrogate },
        .{ .lead = 0xF0, .lo = 0x90, .hi = 0xBF, .out_of_range = .overlong },
        .{ .lead = 0xF4, .lo = 0x80, .hi = 0x8F, .out_of_range = .above_max },
    };
    for (rows) |row| {
        var second: u16 = 0;
        while (second <= 0xFF) : (second += 1) {
            const b: u8 = @intCast(second);
            const is_continuation = b >= 0x80 and b <= 0xBF;
            const in_range = b >= row.lo and b <= row.hi;
            const expected: InvalidReason = if (is_continuation and !in_range)
                row.out_of_range
            else
                .truncated;
            try expect_invalid(&.{ row.lead, b }, 0, expected);
        }
    }
}

test "find_invalid: unrestricted leads accept the full 80..BF second byte, reject the rest" {
    const leads = [_]u8{ 0xC2, 0xDF, 0xE1, 0xEC, 0xEE, 0xEF, 0xF1, 0xF3 };
    for (leads) |lead| {
        var second: u16 = 0x80;
        while (second <= 0xBF) : (second += 1) {
            const b: u8 = @intCast(second);
            // Complete the sequence with maximal-legal continuation bytes.
            const seq = [_]u8{ lead, b, 0x80, 0x80 };
            const n = try std.unicode.utf8ByteSequenceLength(lead);
            try expect_valid(seq[0..n]);
            try expect_invalid(seq[0 .. n - 1], 0, .truncated);
        }
        try expect_invalid(&.{ lead, 0x7F }, 0, .truncated);
        try expect_invalid(&.{ lead, 0xC0 }, 0, .truncated);
    }
}

test "find_invalid: only the first invalid sequence is reported" {
    try expect_invalid("ok\x80\xC0\xFF", 2, .stray_continuation);
    try expect_invalid("ok\xC0\x80\xFF", 2, .overlong);
    try expect_invalid("\xC3\xA9\xED\xA0\x80\xF4\x90\x80\x80", 2, .surrogate);
    try expect_invalid("\xF5\xC3", 0, .above_max);
}

test "find_invalid: valid text becomes invalid by corrupting one byte at each position" {
    const text = "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80z"; // 1+2+3+4+1 = 11 bytes
    try expect_valid(text);
    const Case = struct { at: usize, with: u8, offset: u32, reason: InvalidReason };
    const cases = [_]Case{
        .{ .at = 1, .with = 0xC0, .offset = 1, .reason = .overlong }, // lead of e-acute
        .{ .at = 2, .with = 'x', .offset = 1, .reason = .truncated }, // its continuation
        .{ .at = 3, .with = 0x80, .offset = 3, .reason = .stray_continuation }, // euro lead
        .{ .at = 4, .with = 0x41, .offset = 3, .reason = .truncated }, // euro middle
        .{ .at = 5, .with = 'x', .offset = 3, .reason = .truncated }, // euro last
        .{ .at = 6, .with = 0xF8, .offset = 6, .reason = .above_max }, // emoji lead
        .{ .at = 7, .with = 0x41, .offset = 6, .reason = .truncated }, // emoji second
        .{ .at = 10, .with = 0x80, .offset = 10, .reason = .stray_continuation }, // trailing z
    };
    for (cases) |c| {
        var mutated: [11]u8 = undefined;
        @memcpy(&mutated, text);
        mutated[c.at] = c.with;
        try expect_invalid(&mutated, c.offset, c.reason);
    }
    // Two-byte edit: E2 82 AC -> ED A0 AC turns the euro into a surrogate.
    var mutated: [11]u8 = undefined;
    @memcpy(&mutated, text);
    mutated[3] = 0xED;
    mutated[4] = 0xA0;
    try expect_invalid(&mutated, 3, .surrogate);
}

// ---------------------------------------------------------------------------------------------
// Error variants and resource behaviour
// ---------------------------------------------------------------------------------------------

test "check_len: at maxInt(u32) is accepted, one above and far above are InputTooLarge" {
    const max = std.math.maxInt(u32);
    try expectEqual(@as(u32, 0), try check_len(0));
    try expectEqual(@as(u32, 1), try check_len(1));
    try expectEqual(@as(u32, max), try check_len(max));
    try expectError(error.InputTooLarge, check_len(@as(u64, max) + 1));
    try expectError(error.InputTooLarge, check_len(std.math.maxInt(u64)));
}

test "find_invalid: a slice longer than maxInt(u32) is InputTooLarge before any scan" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    // Only the first byte is backed by memory. It is invalid (0xFF) so an implementation that
    // wrongly scans reports Invalid{0, above_max} instead of walking off the end of the array.
    const backing: [1]u8 = .{0xFF};
    const oversized = @as([*]const u8, &backing)[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try expectError(error.InputTooLarge, find_invalid(oversized));
}

test "find_invalid: offsets past 65535 are exact and heap input leaks nothing" {
    const len: usize = 200_000;
    const buf = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(buf);

    var i: usize = 0;
    while (i + 2 <= len) : (i += 2) @memcpy(buf[i..][0..2], "\xC3\xA9");
    try expectEqual(@as(?Invalid, null), try find_invalid(buf));

    buf[len - 1] = 0x41; // last char becomes C3 41: truncated at its lead
    try expectEqual(
        @as(?Invalid, .{ .offset = len - 2, .reason = .truncated }),
        try find_invalid(buf),
    );
    buf[len - 1] = 0xA9;
    buf[100_001] = 0xA9; // 100_000 is a lead; 100_001 was already a continuation
    buf[100_000] = 0x80; // stray continuation in place of a lead
    try expectEqual(
        @as(?Invalid, .{ .offset = 100_000, .reason = .stray_continuation }),
        try find_invalid(buf),
    );
}

test "find_invalid: does not read past the slice it was given" {
    // A slice of a longer buffer whose next byte would change the verdict.
    const backing = "\xE2\x82\xAC\x80"; // valid euro, then a stray byte outside the slice
    try expectEqual(@as(?Invalid, null), try find_invalid(backing[0..3]));
    const cut = "\xE2\x82\xAC";
    try expect_invalid(cut[0..2], 0, .truncated); // the AC lies outside the slice
    try expect_invalid(backing[0..4], 3, .stray_continuation);
}

// ---------------------------------------------------------------------------------------------
// Differential tests against std.unicode.utf8ValidateSlice
// ---------------------------------------------------------------------------------------------

test "find_invalid: agrees with std for all 256 one-byte and all 65536 two-byte inputs" {
    var a: u16 = 0;
    while (a <= 0xFF) : (a += 1) {
        try check_agreement(&.{@as(u8, @intCast(a))});
        var b: u16 = 0;
        while (b <= 0xFF) : (b += 1) {
            try check_agreement(&.{ @as(u8, @intCast(a)), @as(u8, @intCast(b)) });
        }
    }
}

/// Bytes that sit on every Table 3-7 range edge and class edge.
const representatives = [_]u8{
    0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xF4, 0xF5, 0xFF,
};

test "find_invalid: agrees with std for all 3-byte inputs with an edge-class third byte" {
    var a: u16 = 0;
    while (a <= 0xFF) : (a += 1) {
        var b: u16 = 0;
        while (b <= 0xFF) : (b += 1) {
            for (representatives) |c| {
                try check_agreement(&.{ @as(u8, @intCast(a)), @as(u8, @intCast(b)), c });
            }
        }
    }
}

test "find_invalid: agrees with std for 4-byte inputs led by F0..F7 with edge-class tails" {
    var a: u16 = 0xF0;
    while (a <= 0xF7) : (a += 1) {
        var b: u16 = 0;
        while (b <= 0xFF) : (b += 1) {
            for (representatives) |c| {
                for (representatives) |d| {
                    try check_agreement(&.{ @as(u8, @intCast(a)), @as(u8, @intCast(b)), c, d });
                }
            }
        }
    }
}

test "find_invalid: every proper prefix of every boundary character is truncated" {
    // Every proper prefix of every valid boundary character is invalid and truncated.
    for (valid_boundaries) |bd| {
        try check_agreement(bd.bytes);
        var len: usize = 1;
        while (len < bd.bytes.len) : (len += 1) {
            try check_agreement(bd.bytes[0..len]);
            try expect_invalid(bd.bytes[0..len], 0, .truncated);
        }
    }
}

fn random_bytes(random: std.Random, out: []u8) void {
    // Weighted toward the bytes that matter: leads, continuations, ASCII, and rare junk.
    for (out) |*byte| {
        byte.* = switch (random.uintLessThan(u8, 8)) {
            0, 1 => random.intRangeAtMost(u8, 0x80, 0xBF),
            2, 3 => random.intRangeAtMost(u8, 0xC0, 0xF4),
            4, 5 => random.intRangeAtMost(u8, 0x00, 0x7F),
            6 => representatives[random.uintLessThan(usize, representatives.len)],
            else => random.int(u8),
        };
    }
}

test "find_invalid: seeded random inputs agree with std and never leak" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var iteration: usize = 0;
    while (iteration < 20_000) : (iteration += 1) {
        const len = random.uintLessThan(usize, 24);
        const buf = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(buf);
        random_bytes(random, buf);
        try check_agreement(buf);
    }
}

test "find_invalid: random valid text is valid and any single-byte corruption agrees with std" {
    var prng = std.Random.DefaultPrng.init(0xc0de_c0de);
    const random = prng.random();
    var buf: [64]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 5_000) : (iteration += 1) {
        var len: usize = 0;
        while (len + 4 <= buf.len and random.uintLessThan(u8, 10) != 0) {
            const cp: u21 = switch (random.uintLessThan(u8, 4)) {
                0 => random.intRangeAtMost(u21, 0, 0x7F),
                1 => random.intRangeAtMost(u21, 0x80, 0x7FF),
                2 => random.intRangeAtMost(u21, 0x800, 0xFFFF),
                else => random.intRangeAtMost(u21, 0x10000, 0x10FFFF),
            };
            if (cp >= 0xD800 and cp <= 0xDFFF) continue;
            len += try std.unicode.utf8Encode(cp, buf[len..]);
        }
        try expectEqual(@as(?Invalid, null), try find_invalid(buf[0..len]));
        if (len == 0) continue;
        buf[random.uintLessThan(usize, len)] = random.int(u8);
        try check_agreement(buf[0..len]);
    }
}

// ---------------------------------------------------------------------------------------------
// Fuzz (std.testing.fuzz, Zig 0.16): the seed corpus below runs in `zig build test`; under
// `zig build test --fuzz` the same target is mutated coverage-guided.
// ---------------------------------------------------------------------------------------------

/// Byte weights keep all 256 values reachable (baseline) and boost the structural ones.
/// Bytes outside the weights would be silently replaced by Smith, so the baseline is required.
const fuzz_byte_weights = blk: {
    const Weight = std.testing.Smith.Weight;
    break :blk std.testing.Smith.baselineWeights(u8) ++ [_]Weight{
        Weight.rangeAtMost(u8, 0x80, 0xBF, 6),
        Weight.rangeAtMost(u8, 0xC0, 0xF4, 6),
        Weight.rangeAtMost(u8, 0x00, 0x7F, 3),
    };
};

fn fuzz_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [48]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, fuzz_byte_weights);
    // Exact-size heap copy: leak checked by std.testing.allocator, no slack bytes to hide reads.
    const copy = try std.testing.allocator.dupe(u8, buf[0..len]);
    defer std.testing.allocator.free(copy);
    try check_agreement(copy);
}

/// One corpus entry in Smith's `slice` wire format: u32 little-endian length, then the bytes.
fn seed(comptime bytes: []const u8) [4 + bytes.len]u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes[0..bytes.len].*;
}

const fuzz_corpus = [_][]const u8{
    &seed(""),
    &seed("a"),
    &seed("\x80"),
    &seed("\xC0\x80"),
    &seed("\xC1\xBF"),
    &seed("\xC2\x80"),
    &seed("\xDF\xBF"),
    &seed("\xE0\x80\x80"),
    &seed("\xE0\xA0\x80"),
    &seed("\xED\x9F\xBF"),
    &seed("\xED\xA0\x80"),
    &seed("\xED\xBF\xBF"),
    &seed("\xEE\x80\x80"),
    &seed("\xEF\xBF\xBF"),
    &seed("\xF0\x80\x80\x80"),
    &seed("\xF0\x90\x80\x80"),
    &seed("\xF4\x8F\xBF\xBF"),
    &seed("\xF4\x90\x80\x80"),
    &seed("\xF5\x80\x80\x80"),
    &seed("\xFF"),
    &seed("\xE2\x82"),
    &seed("\xF0\x9F\x98"),
    &seed("\xC3\x41"),
    &seed("\xC3\xC3\xA9"),
    &seed("ab\xE2\x82\xAC\x80"),
    &seed("a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80"),
    &seed("\xED\xA0\xBD\xED\xB8\x80"),
};

test "find_invalid: fuzz differential against std.unicode.utf8ValidateSlice" {
    try std.testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

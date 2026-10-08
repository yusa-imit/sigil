//! core/diagnostics — `Diagnostics{line, col, message, snippet}`, the position-carrying
//! failure report every sigil parser fills on a parse error (REALM.md: "Diagnostics are
//! first-class ... No position-less parse errors anywhere in the format modules").
//!
//! Invariants: message/snippet are stored in fixed inline buffers sized from a comptime
//! `Limits` (Tiger Style: "a limit on everything", no allocation, ever). Input at or under
//! the limit round-trips unchanged; input over the limit is truncated to exactly `limit`
//! bytes — a head prefix followed by `truncation_marker`, never silently dropped, never
//! overflowed. `snippet_text()` returns `null` only when `init` was given `snippet = null`,
//! never as a stand-in for an empty string. `format()` renders exactly
//! `"{line}:{col}: {message}"`. Allocation contract: none — every `DiagnosticsType(limits)`
//! is plain inline data, safe to copy and to drop without a `deinit`.

const std = @import("std");
const assert = std.debug.assert;

/// Fixed capacities backing one `DiagnosticsType`. Both fields must be at least
/// `truncation_marker.len`, or the marker itself would not fit — checked at comptime in
/// `DiagnosticsType`.
pub const Limits = struct {
    message_len_max: u32,
    snippet_len_max: u32,
};

/// The capacities most callers use.
pub const default_limits: Limits = .{ .message_len_max = 256, .snippet_len_max = 80 };

/// Appended in place of the dropped tail when input exceeds a limit.
pub const truncation_marker = "...";

/// `line = col = position_none` means "no source position": the diagnostic came from a layer
/// that sees a `Value` and not source text (`reflect`), and its message carries the key path.
/// Format parsers keep positions 1-based, so 0 is never a real position (ADR 0002 section 3).
pub const position_none: u32 = 0;

/// Copies `input` into `buffer`, truncating with `truncation_marker` when `input` does not
/// fit. Returns the live length, always `<= buffer.len`.
/// Precondition: `buffer.len >= truncation_marker.len` (checked by `DiagnosticsType`'s
/// comptime wall, not re-checked per call here since `buffer.len` is fixed at comptime).
fn copy_truncated(buffer: []u8, input: []const u8) u32 {
    assert(buffer.len >= truncation_marker.len);
    assert(buffer.len <= std.math.maxInt(u32));

    if (input.len <= buffer.len) {
        @memcpy(buffer[0..input.len], input);
        const len: u32 = @intCast(input.len);
        assert(len <= buffer.len);
        return len;
    }

    const prefix_len = buffer.len - truncation_marker.len;
    @memcpy(buffer[0..prefix_len], input[0..prefix_len]);
    @memcpy(buffer[prefix_len..][0..truncation_marker.len], truncation_marker);
    const len: u32 = @intCast(buffer.len);
    assert(len == buffer.len);
    assert(std.mem.endsWith(u8, buffer[0..len], truncation_marker));
    return len;
}

/// Shared body of every `DiagnosticsType(...).init`, factored out to keep the generic
/// function's own line count under the `DiagnosticsType` type function itself (whose body
/// includes the whole returned struct). `Record` is always a `DiagnosticsType(...)` instance.
fn init_record(
    comptime Record: type,
    line: u32,
    col: u32,
    message_text: []const u8,
    snippet: ?[]const u8,
) Record {
    assert(message_text.len <= std.math.maxInt(u32));
    assert(if (snippet) |text| text.len <= std.math.maxInt(u32) else true);

    var self: Record = .{
        .line = line,
        .col = col,
        .message_buffer = undefined,
        .message_len = 0,
        .snippet_buffer = undefined,
        .snippet_len = 0,
        .has_snippet = snippet != null,
    };
    self.message_len = copy_truncated(&self.message_buffer, message_text);
    if (snippet) |text| self.snippet_len = copy_truncated(&self.snippet_buffer, text);

    assert(self.message_len <= self.message_buffer.len);
    assert(self.has_snippet == (snippet != null));
    return self;
}

/// A position-carrying parse diagnostic with fixed inline buffers sized from a comptime
/// `Limits` — no allocation, ever (Tiger Style: "allocate at init", "a limit on everything").
/// `has_snippet` distinguishes "no snippet" (`init` given `null`) from an empty one.
pub fn DiagnosticsType(comptime limits: Limits) type {
    comptime assert(limits.message_len_max >= truncation_marker.len);
    comptime assert(limits.snippet_len_max >= truncation_marker.len);

    return struct {
        // Named `DiagnosticsRecord`, not `Diagnostics`: the module also exports `pub const
        // Diagnostics = DiagnosticsType(default_limits)` at file scope, and the same name
        // here would make every unqualified reference inside this struct ambiguous.
        const DiagnosticsRecord = @This();

        line: u32,
        col: u32,
        message_buffer: [limits.message_len_max]u8,
        message_len: u32,
        snippet_buffer: [limits.snippet_len_max]u8,
        snippet_len: u32,
        has_snippet: bool,

        /// Copies `message_text`/`snippet` into inline buffers, truncating either that
        /// overruns its limit. `snippet = null` means "no snippet", kept distinct from "".
        pub fn init(
            line: u32,
            col: u32,
            message_text: []const u8,
            snippet: ?[]const u8,
        ) DiagnosticsRecord {
            const self = init_record(DiagnosticsRecord, line, col, message_text, snippet);
            assert(self.message_len <= limits.message_len_max);
            assert(self.has_snippet == (snippet != null));
            return self;
        }

        /// The live message slice, truncated if `init`'s input was over the limit.
        pub fn message(self: *const DiagnosticsRecord) []const u8 {
            assert(self.message_len <= self.message_buffer.len);
            const slice = self.message_buffer[0..self.message_len];
            assert(slice.len == self.message_len);
            return slice;
        }

        /// The live snippet, or `null` only when `init` was given `snippet = null`.
        pub fn snippet_text(self: *const DiagnosticsRecord) ?[]const u8 {
            assert(self.snippet_len <= self.snippet_buffer.len);
            if (!self.has_snippet) {
                assert(self.snippet_len == 0);
                return null;
            }
            const slice = self.snippet_buffer[0..self.snippet_len];
            assert(slice.len == self.snippet_len);
            return slice;
        }

        /// Writes exactly `"{line}:{col}: {message}"`; the snippet is not rendered.
        pub fn format(self: *const DiagnosticsRecord, w: *std.Io.Writer) std.Io.Writer.Error!void {
            assert(self.message_len <= limits.message_len_max);
            const text = self.message();
            assert(text.len == self.message_len);
            try w.print("{d}:{d}: {s}", .{ self.line, self.col, text });
        }
    };
}

/// The `DiagnosticsType` most callers use; format modules fill this on every parse failure.
pub const Diagnostics = DiagnosticsType(default_limits);

/// A 1-based source position. `col` counts bytes, not codepoints, so it is defined on invalid
/// UTF-8 too (ADR 0003 section 2).
pub const Position = struct { line: u32, col: u32 };

/// Line and column of byte `offset` in `input`, computed on demand: parsers track no line in
/// their hot loop and pay this O(offset) scan once, on failure. `\n` ends a line; a lone `\r`
/// does not, and `\r\n` counts once because only the `\n` counts.
/// Precondition: `input.len <= maxInt(u32)` and `offset <= input.len` (one past the last byte
/// is the position of an unexpected end).
pub fn position_of(input: []const u8, offset: u32) Position {
    assert(input.len <= std.math.maxInt(u32));
    assert(offset <= input.len);

    const head = input[0..offset];
    const line_start: u32 = if (std.mem.findScalarLast(u8, head, '\n')) |index|
        @intCast(index + 1)
    else
        0;
    const line_count: u32 = @intCast(std.mem.count(u8, head, "\n"));
    // Saturating: an input of exactly `maxInt(u32)` bytes that is one line, or all newlines,
    // reports its end at `maxInt(u32) + 1`, and an error path must never overflow-panic.
    const position: Position = .{ .line = 1 +| line_count, .col = 1 +| (offset - line_start) };
    assert(position.line >= 1);
    assert(position.col >= 1);
    return position;
}

/// The failing line around `offset`, for `Diagnostics.init`: from the later of the line start
/// and `snippet_len_max / 2` bytes before `offset`, up to (excluding) the next `\n`.
/// `Diagnostics.init` cuts what is still too long. Borrows `input`.
/// Precondition: `input.len <= maxInt(u32)` and `offset <= input.len`.
pub fn snippet_of(input: []const u8, offset: u32) []const u8 {
    assert(input.len <= std.math.maxInt(u32));
    assert(offset <= input.len);

    const half = default_limits.snippet_len_max / 2;
    const line_start: u32 = if (std.mem.findScalarLast(u8, input[0..offset], '\n')) |index|
        @intCast(index + 1)
    else
        0;
    const start = @max(line_start, offset -| half);
    const stop = std.mem.findScalarPos(u8, input, offset, '\n') orelse input.len;
    const snippet = input[start..stop];
    assert(snippet.len == stop - start);
    assert(std.mem.findScalar(u8, snippet, '\n') == null);
    return snippet;
}

test "diagnostics: short message and snippet round-trip unchanged" {
    const diag = Diagnostics.init(1, 1, "unexpected token", "he");
    try std.testing.expectEqualStrings("unexpected token", diag.message());
    try std.testing.expectEqualStrings("he", diag.snippet_text().?);
    // Prove no truncation marker was appended: the round-tripped text is shorter than the
    // limit, not merely equal to it by coincidence.
    try std.testing.expect(diag.message().len < default_limits.message_len_max);
    try std.testing.expect(diag.snippet_text().?.len < default_limits.snippet_len_max);
}

test "diagnostics: message exactly at message_len_max is not truncated" {
    const input = "a" ** default_limits.message_len_max;
    const diag = Diagnostics.init(2, 2, input, null);
    try std.testing.expectEqual(@as(usize, default_limits.message_len_max), diag.message().len);
    try std.testing.expectEqualStrings(input, diag.message());
    // The boundary itself is not "longer than": no marker should appear at the tail.
    try std.testing.expect(!std.mem.endsWith(u8, diag.message(), truncation_marker));
}

test "diagnostics: message one byte over message_len_max is truncated with marker" {
    const limit = default_limits.message_len_max;
    const input = "a" ** (limit + 1);
    const diag = Diagnostics.init(3, 4, input, null);

    try std.testing.expectEqual(@as(usize, limit), diag.message().len);
    try std.testing.expect(std.mem.endsWith(u8, diag.message(), truncation_marker));

    const prefix_len = limit - truncation_marker.len;
    try std.testing.expectEqualStrings(
        input[0..prefix_len],
        diag.message()[0..prefix_len],
    );
}

test "diagnostics: snippet one byte over snippet_len_max is truncated; null snippet stays null" {
    const limit = default_limits.snippet_len_max;
    const input = "s" ** (limit + 1);
    const diag = Diagnostics.init(5, 6, "msg", input);

    const snippet = diag.snippet_text().?;
    try std.testing.expectEqual(@as(usize, limit), snippet.len);
    try std.testing.expect(std.mem.endsWith(u8, snippet, truncation_marker));

    const prefix_len = limit - truncation_marker.len;
    try std.testing.expectEqualStrings(input[0..prefix_len], snippet[0..prefix_len]);

    const no_snippet = Diagnostics.init(5, 6, "msg", null);
    try std.testing.expect(no_snippet.snippet_text() == null);
}

test "diagnostics: format renders exactly line:col: message" {
    const diag = Diagnostics.init(42, 7, "bad token", "irrelevant for format");

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try diag.format(&writer);

    try std.testing.expectEqualStrings("42:7: bad token", writer.buffered());
}

test "diagnostics: position_none is zero and format renders it as 0:0" {
    try std.testing.expectEqual(@as(u32, 0), position_none);
    const diag = Diagnostics.init(position_none, position_none, "x", null);
    try std.testing.expectEqual(@as(u32, 0), diag.line);
    try std.testing.expectEqual(@as(u32, 0), diag.col);

    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try diag.format(&writer);
    try std.testing.expectEqualStrings("0:0: x", writer.buffered());
}

test "diagnostics: format dispatches through the {f} writer specifier" {
    const diag = Diagnostics.init(3, 1, "eof", null);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{diag});

    try std.testing.expectEqualStrings("3:1: eof", writer.buffered());
}

test "diagnostics: a smaller Limits truncates independently of default_limits" {
    const small_limits: Limits = .{ .message_len_max = 8, .snippet_len_max = 8 };
    const Small = DiagnosticsType(small_limits);

    // Longer than the small limit but well under default_limits: proves the buffer size
    // actually comes from the comptime parameter, not a global constant.
    const input = "a" ** 20;
    try std.testing.expect(input.len < default_limits.message_len_max);

    const diag = Small.init(1, 1, input, input);
    try std.testing.expectEqual(@as(usize, 8), diag.message().len);
    try std.testing.expect(std.mem.endsWith(u8, diag.message(), truncation_marker));
    try std.testing.expectEqual(@as(usize, 8), diag.snippet_text().?.len);
    try std.testing.expect(std.mem.endsWith(u8, diag.snippet_text().?, truncation_marker));

    // The same over-limit input under default_limits is untouched: same input, different
    // comptime Limits, different result.
    const big_diag = Diagnostics.init(1, 1, input, input);
    try std.testing.expectEqualStrings(input, big_diag.message());
    try std.testing.expectEqualStrings(input, big_diag.snippet_text().?);
}

test "position_of: offset 0 is 1:1, also on empty input" {
    try std.testing.expectEqual(Position{ .line = 1, .col = 1 }, position_of("", 0));
    try std.testing.expectEqual(Position{ .line = 1, .col = 1 }, position_of("abc", 0));
}

test "position_of: columns count bytes and are 1-based" {
    try std.testing.expectEqual(Position{ .line = 1, .col = 3 }, position_of("abc", 2));
    // One past the last byte is a valid position (UnexpectedEnd points there).
    try std.testing.expectEqual(Position{ .line = 1, .col = 4 }, position_of("abc", 3));
    // A two-byte codepoint counts as two columns: columns are bytes, not codepoints.
    try std.testing.expectEqual(Position{ .line = 1, .col = 4 }, position_of("\xc3\xa9x", 3));
}

test "position_of: a newline starts the next line at col 1" {
    const input = "ab\ncd\n\nef";
    try std.testing.expectEqual(Position{ .line = 1, .col = 3 }, position_of(input, 2));
    try std.testing.expectEqual(Position{ .line = 2, .col = 1 }, position_of(input, 3));
    try std.testing.expectEqual(Position{ .line = 2, .col = 3 }, position_of(input, 5));
    try std.testing.expectEqual(Position{ .line = 3, .col = 1 }, position_of(input, 6));
    try std.testing.expectEqual(Position{ .line = 4, .col = 3 }, position_of(input, 9));
}

test "position_of: CR alone is not a line break, CRLF counts once" {
    try std.testing.expectEqual(Position{ .line = 1, .col = 4 }, position_of("a\rb", 3));
    try std.testing.expectEqual(Position{ .line = 2, .col = 1 }, position_of("a\r\nb", 3));
}

test "snippet_of: the whole line when it is short" {
    const input = "{\n  \"a\": 1,\n  \"b\": ]\n}";
    try std.testing.expectEqualStrings("  \"b\": ]", snippet_of(input, 18));
    try std.testing.expectEqualStrings("{", snippet_of(input, 0));
    try std.testing.expectEqualStrings("}", snippet_of(input, input.len));
}

test "snippet_of: empty line and empty input give an empty snippet" {
    try std.testing.expectEqualStrings("", snippet_of("", 0));
    try std.testing.expectEqualStrings("", snippet_of("a\n\nb", 2));
}

test "snippet_of: a long line starts snippet_len_max / 2 before the offset" {
    const half = default_limits.snippet_len_max / 2;
    const input = "x" ** 200 ++ "Y" ++ "z" ** 200 ++ "\nnext";
    const snippet = snippet_of(input, 200);
    try std.testing.expectEqual(@as(usize, half + 1 + 200), snippet.len);
    try std.testing.expectEqual(@as(u8, 'Y'), snippet[half]);
    // Near the line start the window clamps to the line start, never into the previous line.
    try std.testing.expectEqualStrings("xxY", snippet_of("ab\nxxY", 5));
}

test "diagnostics: message_len_max at the minimum legal wall (truncation_marker.len) still works" {
    const wall_limits: Limits = .{
        .message_len_max = truncation_marker.len,
        .snippet_len_max = truncation_marker.len,
    };
    const Wall = DiagnosticsType(wall_limits);

    const input = "hello world, this is longer than the marker";
    const diag = Wall.init(9, 9, input, input);

    // At the wall, the entire result is the marker itself: zero-length prefix, no crash.
    try std.testing.expectEqual(@as(usize, truncation_marker.len), diag.message().len);
    try std.testing.expectEqualStrings(truncation_marker, diag.message());
    try std.testing.expectEqual(@as(usize, truncation_marker.len), diag.snippet_text().?.len);
    try std.testing.expectEqualStrings(truncation_marker, diag.snippet_text().?);
}

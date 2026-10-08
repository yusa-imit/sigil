//! json/scanner — a pull tokenizer over one complete input slice (ADR 0003 section 1).
//!
//! `next` yields object/array begin and end, keys, strings, numbers and the three literals,
//! then `.end` exactly once. It validates structure, separators, literal spelling and the RFC
//! 8259 section 6 number grammar. Number text is grammar-checked, not range-checked: range is
//! the consumer's business.
//!
//! A `.key`/`.string` token is validated whole before it is returned: strict UTF-8
//! (`core.unicode.find_invalid`), no raw byte below 0x20, escape syntax, and surrogate pairing
//! (`core.unicode_escape`). The earliest fault wins. Such a token is always decodable, so
//! `decode_string` has no error set.
//!
//! Invariants: `offset <= input.len <= maxInt(u32)`; `depth <= depth_max <= nesting_max`; bit
//! `d` of `containers` is set iff open container number `d` is an object. Every `raw` is a
//! sub-slice of `input`. A `Scanner` holds no pointer except `input`, so a copy is a snapshot.
//! Calling `next` after `.end` or after an error is a contract violation (asserted).
//!
//! Allocation: none, ever. Cost: O(1) state, one pass, no line tracking; line:col are
//! computed from the offset only when an error is reported. Every error writes `diag` once;
//! success never writes it.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;

pub const Options = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
};

pub const Kind = enum(u8) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    key,
    string,
    number,
    literal_true,
    literal_false,
    literal_null,
    end,
};

pub const Token = struct {
    kind: Kind,
    /// `.key`/`.string` only: `raw` holds at least one backslash.
    has_escapes: bool,
    /// First byte of the token; the opening quote of a `.key`/`.string`; `input.len` for `.end`.
    offset: u32,
    /// Sub-slice of the input: between the quotes, or the token text. Empty for `.end`.
    raw: []const u8,
};

pub const ScanError = error{
    /// The input ends inside a value, or holds only whitespace.
    UnexpectedEnd,
    /// A byte the grammar forbids here: BOM, comment, `'`, `,]`, a misspelt literal.
    UnexpectedToken,
    /// Non-whitespace after the root value.
    TrailingData,
    /// A number run outside the RFC 8259 grammar.
    InvalidNumber,
    /// Container number `depth_max + 1`.
    TooDeep,
    /// `\` followed by a byte outside `"\/bfnrtu`, or a `\u` without four hex digits.
    InvalidEscape,
    /// A `\uD800`..`\uDFFF` escape without its partner: unpaired, or a lone low surrogate.
    LoneSurrogate,
    /// A raw byte below 0x20 inside a string.
    ControlCharacter,
    /// A string holds bytes that are not strict UTF-8.
    InvalidUtf8,
};

pub const Scanner = struct {
    input: []const u8,
    offset: u32,
    depth: u16,
    depth_max: u16,
    containers: std.bit_set.IntegerBitSet(core.value.nesting_max),
    expect: Expect,

    pub const InitError = error{InputTooLarge};

    /// What the grammar allows at the next token.
    const Expect = enum {
        value,
        value_or_array_end,
        key,
        key_or_object_end,
        comma_or_end,
        end,
        finished,
        failed,
    };

    comptime {
        assert(core.value.nesting_max <= std.math.maxInt(u16));
        assert(@sizeOf(Scanner) <= 64);
    }

    /// Starts scanning `input`. `InputTooLarge` when it is longer than `maxInt(u32)`.
    /// Precondition: `1 <= options.depth_max <= core.value.nesting_max`.
    pub fn init(scanner: *Scanner, input: []const u8, options: Options) InitError!void {
        assert(options.depth_max >= 1);
        assert(options.depth_max <= core.value.nesting_max);

        _ = try core.unicode.check_len(input.len);
        scanner.* = .{
            .input = input,
            .offset = 0,
            .depth = 0,
            .depth_max = options.depth_max,
            .containers = .initEmpty(),
            .expect = .value,
        };
        assert(scanner.expect == .value);
        assert(scanner.depth == 0);
    }

    /// The next token. On error `diag` is written once and the scanner is finished: calling
    /// `next` again is a contract violation. `raw` borrows the input.
    pub fn next(scanner: *Scanner, diag: *Diagnostics) ScanError!Token {
        assert(scanner.expect != .finished);
        assert(scanner.expect != .failed);
        errdefer assert(scanner.expect == .failed);

        scanner.skip_whitespace();
        if (scanner.expect == .end) return scanner.next_end(diag);
        if (scanner.expect == .comma_or_end) {
            if (try scanner.next_separator(diag)) |token| return token;
        }
        return scanner.next_value(diag);
    }

    fn next_end(scanner: *Scanner, diag: *Diagnostics) ScanError!Token {
        assert(scanner.expect == .end);
        assert(scanner.depth == 0);
        if (scanner.offset < scanner.input.len) {
            return scanner.fail(diag, error.TrailingData, scanner.offset);
        }
        scanner.expect = .finished;
        return .{ .kind = .end, .has_escapes = false, .offset = scanner.offset, .raw = "" };
    }

    /// After a value inside a container: a closer ends it (returned as a token), a comma
    /// moves on to the next key or value (null), anything else is an error.
    fn next_separator(scanner: *Scanner, diag: *Diagnostics) ScanError!?Token {
        assert(scanner.expect == .comma_or_end);
        assert(scanner.depth > 0);
        if (scanner.offset == scanner.input.len) {
            return scanner.fail(diag, error.UnexpectedEnd, scanner.offset);
        }
        const in_object = scanner.containers.isSet(scanner.depth - 1);
        const byte = scanner.input[scanner.offset];
        if (byte == ',') {
            scanner.offset += 1;
            scanner.expect = if (in_object) .key else .value;
            scanner.skip_whitespace();
            return null;
        }
        if (in_object and byte == '}') return scanner.close(.object_end);
        if (!in_object and byte == ']') return scanner.close(.array_end);
        return scanner.fail(diag, error.UnexpectedToken, scanner.offset);
    }

    fn next_value(scanner: *Scanner, diag: *Diagnostics) ScanError!Token {
        assert(scanner.expect != .end);
        assert(scanner.expect != .comma_or_end);
        if (scanner.offset == scanner.input.len) {
            return scanner.fail(diag, error.UnexpectedEnd, scanner.offset);
        }
        const byte = scanner.input[scanner.offset];
        switch (scanner.expect) {
            .key, .key_or_object_end => {
                if (byte == '}' and scanner.expect == .key_or_object_end) {
                    return scanner.close(.object_end);
                }
                if (byte != '"') return scanner.fail(diag, error.UnexpectedToken, scanner.offset);
                return scanner.scan_key(diag);
            },
            .value, .value_or_array_end => {
                if (byte == ']' and scanner.expect == .value_or_array_end) {
                    return scanner.close(.array_end);
                }
                return scanner.next_value_start(diag, byte);
            },
            .comma_or_end, .end, .finished, .failed => unreachable, // proof: asserted above.
        }
    }

    fn next_value_start(scanner: *Scanner, diag: *Diagnostics, byte: u8) ScanError!Token {
        switch (byte) {
            '{' => return scanner.open(diag, .object_begin),
            '[' => return scanner.open(diag, .array_begin),
            '"' => {
                const token = try scanner.scan_string(diag, .string);
                scanner.after_value();
                return token;
            },
            't' => return scanner.scan_literal(diag, "true", .literal_true),
            'f' => return scanner.scan_literal(diag, "false", .literal_false),
            'n' => return scanner.scan_literal(diag, "null", .literal_null),
            // `+` and `.` cannot start a number, but `+1` and `.5` are number runs the
            // grammar rejects, and ADR 0003 names them `InvalidNumber`.
            '-', '+', '.', '0'...'9' => return scanner.scan_number(diag),
            else => return scanner.fail(diag, error.UnexpectedToken, scanner.offset),
        }
    }

    fn open(scanner: *Scanner, diag: *Diagnostics, kind: Kind) ScanError!Token {
        assert(kind == .object_begin or kind == .array_begin);
        if (scanner.depth == scanner.depth_max) {
            return scanner.fail(diag, error.TooDeep, scanner.offset);
        }
        const is_object = kind == .object_begin;
        if (is_object) {
            scanner.containers.set(scanner.depth);
        } else {
            scanner.containers.unset(scanner.depth);
        }
        scanner.depth += 1;
        scanner.expect = if (is_object) .key_or_object_end else .value_or_array_end;
        return scanner.take(kind, 1);
    }

    fn close(scanner: *Scanner, kind: Kind) Token {
        assert(kind == .object_end or kind == .array_end);
        assert(scanner.depth > 0);
        assert(scanner.containers.isSet(scanner.depth - 1) == (kind == .object_end));
        scanner.depth -= 1;
        scanner.after_value();
        return scanner.take(kind, 1);
    }

    /// A key, then the colon that must follow it; the value comes on the next call.
    fn scan_key(scanner: *Scanner, diag: *Diagnostics) ScanError!Token {
        assert(scanner.input[scanner.offset] == '"');
        const token = try scanner.scan_string(diag, .key);
        scanner.skip_whitespace();
        if (scanner.offset == scanner.input.len) {
            return scanner.fail(diag, error.UnexpectedEnd, scanner.offset);
        }
        if (scanner.input[scanner.offset] != ':') {
            return scanner.fail(diag, error.UnexpectedToken, scanner.offset);
        }
        scanner.offset += 1;
        scanner.expect = .value;
        return token;
    }

    /// A validated string: the structural walk finds the closing quote or the first fault, then
    /// UTF-8 is checked over the bytes before it, so a bad byte ahead of the fault is reported.
    fn scan_string(scanner: *Scanner, diag: *Diagnostics, kind: Kind) ScanError!Token {
        assert(kind == .key or kind == .string);
        assert(scanner.input[scanner.offset] == '"');
        const start = scanner.offset;
        const body = walk_string_body(scanner.input, start + 1);
        const limit = switch (body) {
            .closed => |closed| closed.quote_offset,
            .failed => |failed| failed.offset,
        };
        assert(limit > start);
        assert(limit <= scanner.input.len);
        const invalid = core.unicode.find_invalid(scanner.input[start + 1 .. limit]) catch |err| {
            switch (err) { // proof: `core.unicode.Error` has no I/O variant.
                // proof: `init` checked `input.len <= maxInt(u32)`, so the slice is shorter.
                error.InputTooLarge => unreachable,
            }
        };
        if (invalid) |bad| return scanner.fail(diag, error.InvalidUtf8, start + 1 + bad.offset);
        switch (body) {
            .failed => |failed| return scanner.fail(diag, failed.err, failed.offset),
            .closed => |closed| {
                scanner.offset = closed.quote_offset + 1;
                return .{
                    .kind = kind,
                    .has_escapes = closed.has_escapes,
                    .offset = start,
                    .raw = scanner.input[start + 1 .. closed.quote_offset],
                };
            },
        }
    }

    fn scan_literal(
        scanner: *Scanner,
        diag: *Diagnostics,
        comptime text: []const u8,
        kind: Kind,
    ) ScanError!Token {
        assert(scanner.input[scanner.offset] == text[0]);
        const rest = scanner.input[scanner.offset..];
        const common = @min(rest.len, text.len);
        if (!std.mem.eql(u8, rest[0..common], text[0..common])) {
            return scanner.fail(diag, error.UnexpectedToken, scanner.offset);
        }
        if (rest.len < text.len) {
            return scanner.fail(diag, error.UnexpectedEnd, @intCast(scanner.input.len));
        }
        scanner.after_value();
        return scanner.take(kind, text.len);
    }

    /// The maximal run of `[0-9+-.eE]`, judged whole against the RFC 8259 grammar.
    fn scan_number(scanner: *Scanner, diag: *Diagnostics) ScanError!Token {
        const start = scanner.offset;
        var stop: usize = start;
        while (stop < scanner.input.len and is_number_byte(scanner.input[stop])) stop += 1;
        const run = scanner.input[start..stop];
        if (!is_number_grammar(run)) return scanner.fail(diag, error.InvalidNumber, start);
        scanner.after_value();
        return scanner.take(.number, run.len);
    }

    /// The token of `len` bytes at the cursor; advances past it.
    fn take(scanner: *Scanner, kind: Kind, len: usize) Token {
        assert(len >= 1);
        assert(scanner.offset + len <= scanner.input.len);
        const start = scanner.offset;
        scanner.offset += @intCast(len);
        return .{
            .kind = kind,
            .has_escapes = false,
            .offset = start,
            .raw = scanner.input[start..scanner.offset],
        };
    }

    fn after_value(scanner: *Scanner) void {
        scanner.expect = if (scanner.depth == 0) .end else .comma_or_end;
    }

    fn skip_whitespace(scanner: *Scanner) void {
        while (scanner.offset < scanner.input.len) : (scanner.offset += 1) {
            switch (scanner.input[scanner.offset]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// Writes `diag` (position and snippet from `offset`) and finishes the scanner.
    fn fail(scanner: *Scanner, diag: *Diagnostics, err: ScanError, offset: u32) ScanError {
        assert(offset <= scanner.input.len);
        assert(scanner.expect != .failed);
        const position = core.diagnostics.position_of(scanner.input, offset);
        const snippet = core.diagnostics.snippet_of(scanner.input, offset);
        const message = message_of(scanner, err, offset);
        diag.* = Diagnostics.init(position.line, position.col, message, snippet);
        scanner.expect = .failed;
        return err;
    }

    fn message_of(scanner: *const Scanner, err: ScanError, offset: u32) []const u8 {
        // proof: `ScanError` holds no I/O error, so `error.Canceled` cannot occur.
        return switch (err) {
            error.UnexpectedEnd => "unexpected end of input",
            error.UnexpectedToken => if (is_bom_at(scanner.input, offset))
                "unexpected byte order mark"
            else
                "unexpected character",
            error.TrailingData => "trailing data after the root value",
            error.InvalidNumber => "invalid number",
            error.TooDeep => "nesting is too deep",
            error.InvalidEscape => "invalid escape sequence",
            error.LoneSurrogate => "unpaired UTF-16 surrogate in escape",
            error.ControlCharacter => "unescaped control character in string",
            error.InvalidUtf8 => "invalid UTF-8 in string",
        };
    }
};

/// How a string body ended: at its closing quote, or at the first structural fault.
const Body = union(enum) {
    closed: struct { quote_offset: u32, has_escapes: bool },
    failed: struct { err: ScanError, offset: u32 },
};

/// Walks the string body from `body_start` (the byte after the opening quote) checking control
/// bytes and escapes. UTF-8 is not judged here. Bounded: each pass advances at least one byte.
fn walk_string_body(input: []const u8, body_start: u32) Body {
    assert(body_start >= 1);
    assert(input[body_start - 1] == '"');
    var index: u32 = body_start;
    var has_escapes = false;
    for (0..input.len) |_| {
        if (index >= input.len) {
            return .{ .failed = .{ .err = error.UnexpectedEnd, .offset = @intCast(input.len) } };
        }
        const byte = input[index];
        if (byte == '"') {
            return .{ .closed = .{ .quote_offset = index, .has_escapes = has_escapes } };
        }
        if (byte < 0x20) return .{ .failed = .{ .err = error.ControlCharacter, .offset = index } };
        if (byte != '\\') {
            index += 1;
            continue;
        }
        has_escapes = true;
        const escape_len = check_escape(input, index) catch |err| {
            // An escape cut short by the input end is reported there, any other at its backslash.
            const offset: u32 = switch (err) { // proof: `EscapeFault` has no I/O variant.
                error.UnexpectedEnd => @intCast(input.len),
                error.InvalidEscape, error.LoneSurrogate => index,
            };
            return .{ .failed = .{ .err = err, .offset = offset } };
        };
        assert(escape_len == 2 or escape_len == 6 or escape_len == 12);
        index += escape_len;
    }
    unreachable; // proof: `body_start >= 1` and each pass advances, so index reaches input.len.
}

/// Why an escape is bad; the walk maps these to an offset, so the set is closed on purpose.
const EscapeFault = error{ UnexpectedEnd, InvalidEscape, LoneSurrogate };

/// The byte length of the escape whose backslash is at `backslash` (2, 6, or 12 for a pair).
fn check_escape(input: []const u8, backslash: u32) EscapeFault!u32 {
    assert(input[backslash] == '\\');
    const at = backslash + 1;
    if (at >= input.len) return error.UnexpectedEnd;
    switch (input[at]) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => return 2,
        'u' => {},
        else => return error.InvalidEscape,
    }
    const first = try read_hex4(input, at + 1);
    if (first < 0xD800 or first > 0xDFFF) return 6;
    const second = peek_second_unit(input, backslash + 6);
    // `decode_utf16` documents `LoneSurrogate` as its only failure; `InvalidHex` and
    // `InvalidCodepoint` belong to `parse_hex4` and `encode`, which it does not call.
    // proof: no I/O here, and the two other members cannot occur.
    const decoded = core.unicode_escape.decode_utf16(first, second) catch |err| switch (err) {
        error.LoneSurrogate => return error.LoneSurrogate,
        error.InvalidHex, error.InvalidCodepoint => unreachable,
    };
    assert(decoded.units_count == 1 or decoded.units_count == 2);
    assert(decoded.units_count == 2 or first > 0xDBFF);
    return @as(u32, decoded.units_count) * 6;
}

/// The four hex digits at `at` as a UTF-16 unit. A non-hex byte is `InvalidEscape` even when
/// fewer than four bytes remain; otherwise a short run is `UnexpectedEnd`.
fn read_hex4(input: []const u8, at: u32) EscapeFault!u16 {
    assert(at <= input.len);
    const available = @min(input.len - at, 4);
    for (input[at..][0..available]) |digit| {
        if (!std.ascii.isHex(digit)) return error.InvalidEscape;
    }
    if (available < 4) return error.UnexpectedEnd;
    const unit = hex4_at(input, at) orelse unreachable; // proof: all four bytes were hex.
    assert(available == 4);
    return unit;
}

/// The unit of a `\uXXXX` escape starting at `at`, or null when none follows there.
fn peek_second_unit(input: []const u8, at: u32) ?u16 {
    assert(at >= 6);
    assert(at <= input.len);
    if (input.len < @as(usize, at) + 6) return null;
    if (input[at] != '\\') return null;
    if (input[at + 1] != 'u') return null;
    return hex4_at(input, at + 2);
}

/// Four hex digits at `at` (precondition: they are inside `input`), or null if any is not hex.
fn hex4_at(input: []const u8, at: u32) ?u16 {
    assert(input.len >= @as(usize, at) + 4);
    const digits: *const [4]u8 = input[at..][0..4];
    // `parse_hex4` documents `InvalidHex` as its only failure; the other two members of
    // `EscapeError` belong to `decode_utf16` and `encode`.
    // proof: no I/O here, and the two other members cannot occur.
    return core.unicode_escape.parse_hex4(digits) catch |err| switch (err) {
        error.InvalidHex => null,
        error.LoneSurrogate, error.InvalidCodepoint => unreachable,
    };
}

/// Decodes the escapes of a validated `.key`/`.string` `raw` into `out`; returns the decoded
/// prefix of `out`. Precondition: `raw` came from a token (so every escape is well formed) and
/// `out.len >= raw.len`, which suffices because an escape never grows. Breaking either is
/// undefined behaviour in ReleaseFast. Allocation: none.
pub fn decode_string(raw: []const u8, out: []u8) []u8 {
    assert(out.len >= raw.len);
    var read: usize = 0;
    var written: usize = 0;
    for (0..raw.len) |_| {
        if (read == raw.len) break;
        if (raw[read] != '\\') {
            out[written] = raw[read];
            read += 1;
            written += 1;
            continue;
        }
        const step = decode_escape(raw[read..], out[written..]);
        read += step.read_len;
        written += step.written_len;
    }
    assert(read == raw.len);
    assert(written <= read);
    return out[0..written];
}

/// How many bytes one escape consumed from `raw` and produced into `out`.
const EscapeStep = struct { read_len: u8, written_len: u8 };

/// Decodes the one escape at the start of `rest` into `out`. Preconditions: it is well formed
/// and `out` has room for its result (at most as many bytes as the escape has).
fn decode_escape(rest: []const u8, out: []u8) EscapeStep {
    assert(rest.len >= 2);
    assert(rest[0] == '\\');
    const simple: u8 = switch (rest[1]) {
        '"', '\\', '/' => rest[1],
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => return decode_unicode_escape(rest, out),
        else => unreachable, // proof: the scanner rejected every other escape byte.
    };
    out[0] = simple;
    return .{ .read_len = 2, .written_len = 1 };
}

/// The `\uXXXX` or `\uXXXX\uXXXX` escape at the start of `rest`, as UTF-8 into `out`.
fn decode_unicode_escape(rest: []const u8, out: []u8) EscapeStep {
    assert(rest.len >= 6);
    assert(rest[1] == 'u');
    const first = hex4_at(rest, 2) orelse unreachable; // proof: the scanner checked the digits.
    const second: ?u16 = if (first >= 0xD800 and first <= 0xDBFF) hex4_at(rest, 8) else null;
    // proof: the scanner paired every surrogate, so decoding succeeds.
    const decoded = core.unicode_escape.decode_utf16(first, second) catch unreachable;
    var buf: [4]u8 = undefined;
    // proof: `decode_utf16` never yields a surrogate or a value above U+10FFFF.
    const len = core.unicode_escape.encode(decoded.codepoint, &buf) catch unreachable;
    assert(len <= out.len);
    @memcpy(out[0..len], buf[0..len]);
    return .{ .read_len = @as(u8, decoded.units_count) * 6, .written_len = len };
}

fn is_bom_at(input: []const u8, offset: u32) bool {
    return std.mem.startsWith(u8, input[offset..], "\xef\xbb\xbf");
}

fn is_number_byte(byte: u8) bool {
    return switch (byte) {
        '0'...'9', '+', '-', '.', 'e', 'E' => true,
        else => false,
    };
}

/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` over the whole of `run`.
fn is_number_grammar(run: []const u8) bool {
    assert(run.len >= 1);
    var index: usize = 0;
    if (run[index] == '-') index += 1;
    index = skip_integer(run, index) orelse return false;
    if (index < run.len and run[index] == '.') {
        index = skip_digits(run, index + 1) orelse return false;
    }
    if (index < run.len and (run[index] == 'e' or run[index] == 'E')) {
        index += 1;
        if (index < run.len and (run[index] == '+' or run[index] == '-')) index += 1;
        index = skip_digits(run, index) orelse return false;
    }
    return index == run.len;
}

/// `0` or `[1-9][0-9]*` at `start`; the index after it, or null.
fn skip_integer(run: []const u8, start: usize) ?usize {
    assert(start <= run.len);
    if (start == run.len) return null;
    if (run[start] == '0') return start + 1;
    if (run[start] < '1' or run[start] > '9') return null;
    return skip_digits(run, start);
}

/// One or more digits at `start`; the index after them, or null when there is none.
fn skip_digits(run: []const u8, start: usize) ?usize {
    assert(start <= run.len);
    var index = start;
    while (index < run.len and run[index] >= '0' and run[index] <= '9') index += 1;
    if (index == start) return null;
    assert(index <= run.len);
    return index;
}

test {
    _ = @import("scanner_test.zig");
    _ = @import("scanner_string_test.zig");
}

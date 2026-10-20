//! toml/lexer — a pull lexer over one complete input slice (ADR 0005 section 1; ADR 0003
//! section 1 for the shape).
//!
//! `next` yields the structure of a TOML 1.0.0 document one token at a time: newlines, `.`, `=`,
//! `,`, braces, brackets, `[[` and `]]` headers, bare keys, the four string forms, and scalar
//! runs, then `.end` exactly once. Spaces, tabs and comments are skipped; a comment is checked
//! (control characters, UTF-8) and never returned.
//!
//! TOML is context sensitive at the byte level: `1.5` is a key path in a header and one number
//! in a value. The caller (the parser) therefore passes a `Mode` on every call: `.key` splits
//! bare keys at `.` and recognises `[[` and `]]`; `.value` returns everything up to a delimiter
//! as one `.scalar` run (item 4 classifies it) and always returns `[` and `]` singly.
//!
//! A string token is validated whole before it is returned: strict UTF-8, no raw control
//! character, escape syntax (`\b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX`, and in a multi-line basic
//! string the line-ending backslash). The earliest fault wins. `raw` is the body between the
//! delimiters (a multi-line body keeps its first newline; `decode_string` drops it), so such a
//! token is always decodable and `decode_string` has no error set.
//!
//! Invariants: `offset <= input.len <= maxInt(u32)`; every `raw` is a sub-slice of `input`;
//! a decoded string is never longer than its `raw`. Calling `next` after `.end` or after an
//! error is a contract violation (asserted).
//!
//! Allocation: none, ever. Cost: O(1) state, one pass over the input per token, no line
//! tracking; line:col are computed from the offset only when an error is reported. Every error
//! writes `diag` once; success never writes it.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const unicode_escape = core.unicode_escape;

/// Which grammar the next token is read in; see the module doc.
pub const Mode = enum(u8) { key, value };

pub const Kind = enum(u8) {
    newline,
    dot,
    equals,
    comma,
    brace_open,
    brace_close,
    bracket_open,
    bracket_close,
    /// `[[`, `.key` mode only.
    table_array_open,
    /// `]]` with no byte between, `.key` mode only.
    table_array_close,
    /// One or more of `A-Za-z0-9_-`, `.key` mode only.
    bare_key,
    /// A run up to a delimiter, `.value` mode only; the parser classifies it.
    scalar,
    string_basic,
    string_literal,
    string_basic_multiline,
    string_literal_multiline,
    end,
};

pub const Token = struct {
    kind: Kind,
    /// String kinds only: `raw` holds at least one backslash.
    has_escapes: bool,
    /// First byte of the token; the opening delimiter of a string; `input.len` for `.end`.
    offset: u32,
    /// Sub-slice of the input: the string body between its delimiters, or the token text.
    raw: []const u8,
};

pub const ScanError = error{
    /// The input ends inside a string.
    UnexpectedEnd,
    /// A byte the grammar forbids here: BOM, bare CR, a non-ASCII bare key, six closing quotes.
    UnexpectedToken,
    /// A backslash followed by anything outside the TOML 1.0.0 escapes, a short or non-hex
    /// `\u`/`\U`, or `\U` above U+10FFFF.
    InvalidEscape,
    /// A `\uD800`..`\uDFFF` or `\U0000D800`..`\U0000DFFF` escape.
    LoneSurrogate,
    /// A raw control character other than tab (and DEL) in a comment or string.
    ControlCharacter,
    /// A comment or string holds bytes that are not strict UTF-8.
    InvalidUtf8,
};

pub const Lexer = struct {
    input: []const u8,
    offset: u32,
    state: State,

    pub const InitError = error{InputTooLarge};

    const State = enum(u8) { active, finished, failed };

    comptime {
        assert(@sizeOf(Lexer) <= 32);
        assert(@typeInfo(State).@"enum".fields.len == 3);
    }

    /// Starts lexing `input`. `InputTooLarge` when it is longer than `maxInt(u32)`.
    pub fn init(lexer: *Lexer, input: []const u8) InitError!void {
        _ = try core.unicode.check_len(input.len);
        lexer.* = .{ .input = input, .offset = 0, .state = .active };
        assert(lexer.state == .active);
        assert(lexer.offset == 0);
    }

    /// The next token. On error `diag` is written once and the lexer is finished: calling
    /// `next` again is a contract violation. `raw` borrows the input.
    pub fn next(lexer: *Lexer, diag: *Diagnostics, mode: Mode) ScanError!Token {
        assert(lexer.state == .active);
        assert(lexer.offset <= lexer.input.len);
        errdefer assert(lexer.state == .failed);

        try lexer.skip_blank(diag);
        if (lexer.offset == lexer.input.len) {
            lexer.state = .finished;
            return .{ .kind = .end, .has_escapes = false, .offset = lexer.offset, .raw = "" };
        }
        const byte = lexer.input[lexer.offset];
        switch (byte) {
            '\n' => return lexer.take(.newline, 1),
            '\r' => return lexer.next_crlf(diag),
            '"' => return lexer.scan_string(diag, '"'),
            '\'' => return lexer.scan_string(diag, '\''),
            ',' => return lexer.take(.comma, 1),
            '=' => return lexer.take(.equals, 1),
            '{' => return lexer.take(.brace_open, 1),
            '}' => return lexer.take(.brace_close, 1),
            '[' => return lexer.next_bracket(mode, '[', .bracket_open, .table_array_open),
            ']' => return lexer.next_bracket(mode, ']', .bracket_close, .table_array_close),
            '.' => if (mode == .key) return lexer.take(.dot, 1),
            else => {},
        }
        return switch (mode) {
            .key => lexer.scan_bare_key(diag),
            .value => lexer.scan_scalar(diag),
        };
    }

    /// `[` or `]`: doubled and adjacent in `.key` mode it is the array-of-tables form.
    fn next_bracket(lexer: *Lexer, mode: Mode, byte: u8, single: Kind, double: Kind) Token {
        assert(byte == '[' or byte == ']');
        assert(lexer.input[lexer.offset] == byte);
        const after = lexer.offset + 1;
        const doubled = after < lexer.input.len and lexer.input[after] == byte;
        if (mode == .key and doubled) return lexer.take(double, 2);
        return lexer.take(single, 1);
    }

    fn next_crlf(lexer: *Lexer, diag: *Diagnostics) ScanError!Token {
        assert(lexer.input[lexer.offset] == '\r');
        const after = lexer.offset + 1;
        if (after < lexer.input.len and lexer.input[after] == '\n') {
            return lexer.take(.newline, 2);
        }
        return lexer.fail(diag, error.UnexpectedToken, lexer.offset);
    }

    fn take(lexer: *Lexer, kind: Kind, len: usize) Token {
        assert(len >= 1);
        assert(lexer.offset + len <= lexer.input.len);
        const start = lexer.offset;
        lexer.offset += @intCast(len);
        return .{
            .kind = kind,
            .has_escapes = false,
            .offset = start,
            .raw = lexer.input[start..lexer.offset],
        };
    }

    /// Skips spaces, tabs and comments; stops before a newline, a CR or any other byte.
    fn skip_blank(lexer: *Lexer, diag: *Diagnostics) ScanError!void {
        assert(lexer.offset <= lexer.input.len);
        while (lexer.offset < lexer.input.len) {
            switch (lexer.input[lexer.offset]) {
                ' ', '\t' => lexer.offset += 1,
                '#' => try lexer.skip_comment(diag),
                else => return,
            }
        }
        assert(lexer.offset == lexer.input.len);
    }

    /// Checks a comment and moves to its line ending (or the end of the input).
    fn skip_comment(lexer: *Lexer, diag: *Diagnostics) ScanError!void {
        const input = lexer.input;
        const start = lexer.offset;
        assert(input[start] == '#');
        var index = start + 1;
        var control: ?u32 = null;
        while (index < input.len) : (index += 1) {
            const byte = input[index];
            if (byte == '\n') break;
            if (byte == '\r' and index + 1 < input.len and input[index + 1] == '\n') break;
            if (is_control(byte)) {
                control = index;
                break;
            }
        }
        if (utf8_fault(input, start + 1, index)) |fault| {
            return lexer.fail(diag, fault.err, fault.offset);
        }
        if (control) |offset| return lexer.fail(diag, error.ControlCharacter, offset);
        assert(index >= start + 1);
        lexer.offset = index;
    }

    /// A bare key: `A-Za-z0-9_-`, at least one byte.
    fn scan_bare_key(lexer: *Lexer, diag: *Diagnostics) ScanError!Token {
        const input = lexer.input;
        const start = lexer.offset;
        assert(start < input.len);
        var index = start;
        while (index < input.len and is_bare_key_byte(input[index])) index += 1;
        if (index == start) return lexer.fail(diag, error.UnexpectedToken, start);
        assert(index > start);
        return lexer.take(.bare_key, index - start);
    }

    /// A scalar run: everything up to a blank, a line ending or one of `, ] } #`.
    fn scan_scalar(lexer: *Lexer, diag: *Diagnostics) ScanError!Token {
        const input = lexer.input;
        const start = lexer.offset;
        assert(start < input.len);
        var index = start;
        while (index < input.len) : (index += 1) {
            const byte = input[index];
            switch (byte) {
                ' ', '\t', '\r', '\n', ',', ']', '}', '#' => break,
                else => {},
            }
            if (byte >= 0x80 or is_control(byte)) {
                return lexer.fail(diag, error.UnexpectedToken, index);
            }
        }
        assert(index > start);
        return lexer.take(.scalar, index - start);
    }

    /// A basic (`"`) or literal (`'`) string, single-line or multi-line.
    fn scan_string(lexer: *Lexer, diag: *Diagnostics, quote: u8) ScanError!Token {
        const input = lexer.input;
        const start = lexer.offset;
        assert(quote == '"' or quote == '\'');
        assert(input[start] == quote);
        const multiline = start + 2 < input.len and input[start + 1] == quote and
            input[start + 2] == quote;
        const body_start: u32 = if (multiline) start + 3 else start + 1;
        const walked = if (multiline)
            walk_multiline(input, body_start, quote)
        else
            walk_single_line(input, body_start, quote);
        const body_limit = switch (walked) {
            .closed => |closed| closed.body_end,
            .failed => |fault| fault.offset,
        };
        if (utf8_fault(input, body_start, body_limit)) |fault| {
            return lexer.fail(diag, fault.err, fault.offset);
        }
        switch (walked) {
            .failed => |fault| return lexer.fail(diag, fault.err, fault.offset),
            .closed => |closed| {
                lexer.offset = closed.close_end;
                return .{
                    .kind = string_kind(quote, multiline),
                    .has_escapes = closed.has_escapes,
                    .offset = start,
                    .raw = input[body_start..closed.body_end],
                };
            },
        }
    }

    /// Writes `diag` (position and snippet from `offset`) and finishes the lexer.
    fn fail(lexer: *Lexer, diag: *Diagnostics, err: ScanError, offset: u32) ScanError {
        assert(offset <= lexer.input.len);
        assert(lexer.state != .failed);
        const position = core.diagnostics.position_of(lexer.input, offset);
        const snippet = core.diagnostics.snippet_of(lexer.input, offset);
        const message = message_of(lexer.input, err, offset);
        diag.* = Diagnostics.init(position.line, position.col, message, snippet);
        lexer.state = .failed;
        return err;
    }
};

const Fault = struct { err: ScanError, offset: u32 };

/// How a string body ended: at its closing delimiter, or at the first structural fault.
const Body = union(enum) {
    /// `body_end` is exclusive and may include up to two quotes of a multi-line closing run.
    closed: struct { body_end: u32, close_end: u32, has_escapes: bool },
    failed: Fault,
};

fn body_fault(err: ScanError, offset: u32) Body {
    return .{ .failed = .{ .err = err, .offset = offset } };
}

const Escape = union(enum) {
    /// Index of the first byte after the escape.
    next: u32,
    failed: Fault,
};

fn message_of(input: []const u8, err: ScanError, offset: u32) []const u8 {
    // proof: `ScanError` holds no I/O error, so `error.Canceled` cannot occur.
    return switch (err) {
        error.UnexpectedEnd => "unexpected end of input",
        error.UnexpectedToken => if (is_bom_at(input, offset))
            "unexpected byte order mark"
        else
            "unexpected character",
        error.InvalidEscape => "invalid escape sequence",
        error.LoneSurrogate => "surrogate code point in escape",
        error.ControlCharacter => "unescaped control character",
        error.InvalidUtf8 => "invalid UTF-8",
    };
}

fn string_kind(quote: u8, multiline: bool) Kind {
    assert(quote == '"' or quote == '\'');
    if (quote == '"') return if (multiline) .string_basic_multiline else .string_basic;
    return if (multiline) .string_literal_multiline else .string_literal;
}

fn is_control(byte: u8) bool {
    return (byte < 0x20 and byte != '\t') or byte == 0x7f;
}

fn is_bare_key_byte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

fn is_bom_at(input: []const u8, offset: u32) bool {
    return std.mem.startsWith(u8, input[offset..], "\xEF\xBB\xBF");
}

/// The first invalid UTF-8 sequence of `input[start..end]`, as a fault, or null.
fn utf8_fault(input: []const u8, start: u32, end: u32) ?Fault {
    assert(start <= end);
    assert(end <= input.len);
    // proof: the lexer was initialised with `input.len <= maxInt(u32)`.
    const invalid = core.unicode.find_invalid(input[start..end]) catch unreachable;
    const found = invalid orelse return null;
    return .{ .err = error.InvalidUtf8, .offset = start + found.offset };
}

/// Walks a single-line string body from `body_start`; a raw control byte (a newline included)
/// or the end of the input is a fault. Bounded: every pass advances at least one byte.
fn walk_single_line(input: []const u8, body_start: u32, quote: u8) Body {
    assert(body_start >= 1);
    assert(input[body_start - 1] == quote);
    var index = body_start;
    var has_escapes = false;
    while (index < input.len) {
        const byte = input[index];
        if (byte == quote) {
            return .{ .closed = .{
                .body_end = index,
                .close_end = index + 1,
                .has_escapes = has_escapes,
            } };
        }
        if (is_control(byte)) return body_fault(error.ControlCharacter, index);
        if (byte == '\\' and quote == '"') {
            has_escapes = true;
            switch (check_escape(input, index, false)) {
                .next => |after| index = after,
                .failed => |fault| return .{ .failed = fault },
            }
        } else {
            index += 1;
        }
    }
    return body_fault(error.UnexpectedEnd, @intCast(input.len));
}

/// Walks a multi-line string body: LF and CRLF are data, a bare CR is not, and a run of three to
/// five quotes closes the string (the first run bytes beyond three belong to the body).
fn walk_multiline(input: []const u8, body_start: u32, quote: u8) Body {
    assert(body_start >= 3);
    assert(input[body_start - 1] == quote);
    var index = body_start;
    var has_escapes = false;
    while (index < input.len) {
        const byte = input[index];
        if (byte == quote) {
            const run = quote_run(input, index, quote);
            if (run > 5) return body_fault(error.UnexpectedToken, index + 5);
            if (run >= 3) {
                return .{ .closed = .{
                    .body_end = index + run - 3,
                    .close_end = index + run,
                    .has_escapes = has_escapes,
                } };
            }
            index += run;
        } else if (byte == '\r' and index + 1 < input.len and input[index + 1] == '\n') {
            index += 2;
        } else if (is_control(byte) and byte != '\n') {
            return body_fault(error.ControlCharacter, index);
        } else if (byte == '\\' and quote == '"') {
            has_escapes = true;
            switch (check_escape(input, index, true)) {
                .next => |after| index = after,
                .failed => |fault| return .{ .failed = fault },
            }
        } else {
            index += 1;
        }
    }
    return body_fault(error.UnexpectedEnd, @intCast(input.len));
}

/// The number of consecutive `quote` bytes at `index`, capped at 6 (enough to tell too many).
fn quote_run(input: []const u8, index: u32, quote: u8) u32 {
    assert(input[index] == quote);
    var run: u32 = 0;
    while (run < 6 and index + run < input.len and input[index + run] == quote) run += 1;
    assert(run >= 1);
    assert(run <= 6);
    return run;
}

/// Checks the escape whose backslash is at `backslash`.
fn check_escape(input: []const u8, backslash: u32, multiline: bool) Escape {
    assert(input[backslash] == '\\');
    const at = backslash + 1;
    if (at == input.len) return .{ .failed = .{ .err = error.UnexpectedEnd, .offset = at } };
    switch (input[at]) {
        'b', 't', 'n', 'f', 'r', '"', '\\' => return .{ .next = at + 1 },
        'u' => return check_unicode_escape(input, backslash, 4),
        'U' => return check_unicode_escape(input, backslash, 8),
        ' ', '\t', '\r', '\n' => if (multiline) {
            return check_line_ending_backslash(input, backslash);
        },
        else => {},
    }
    return .{ .failed = .{ .err = error.InvalidEscape, .offset = backslash } };
}

/// A backslash, optional blanks, then a line ending: the escape ends after the line ending.
fn check_line_ending_backslash(input: []const u8, backslash: u32) Escape {
    assert(input[backslash] == '\\');
    var index = backslash + 1;
    while (index < input.len and (input[index] == ' ' or input[index] == '\t')) index += 1;
    if (index < input.len and input[index] == '\n') return .{ .next = index + 1 };
    const crlf = index + 1 < input.len and input[index] == '\r' and input[index + 1] == '\n';
    if (crlf) return .{ .next = index + 2 };
    return .{ .failed = .{ .err = error.InvalidEscape, .offset = backslash } };
}

/// `\uXXXX` (`digits` 4) or `\UXXXXXXXX` (`digits` 8): hex digits, a scalar value in range.
fn check_unicode_escape(input: []const u8, backslash: u32, digits: u32) Escape {
    assert(digits == 4 or digits == 8);
    assert(input[backslash + 1] == 'u' or input[backslash + 1] == 'U');
    const invalid: Escape = .{ .failed = .{ .err = error.InvalidEscape, .offset = backslash } };
    const hex_start = backslash + 2;
    if (hex_start + digits > input.len) return invalid;
    var value: u32 = 0;
    var group: u32 = 0;
    while (group < digits) : (group += 4) {
        const digits_group = input[hex_start + group ..][0..4];
        const unit = unicode_escape.parse_hex4(digits_group) catch return invalid;
        value = (value << 16) | unit;
    }
    if (value > 0x10FFFF) return invalid;
    if (value >= 0xD800 and value <= 0xDFFF) {
        return .{ .failed = .{ .err = error.LoneSurrogate, .offset = backslash } };
    }
    return .{ .next = hex_start + digits };
}

pub fn is_string(kind: Kind) bool {
    return switch (kind) {
        .string_basic, .string_literal, .string_basic_multiline, .string_literal_multiline => true,
        else => false,
    };
}

/// Decodes the `raw` of a string token of `kind` into `out` and returns the used prefix.
/// A multi-line body drops its first newline; escapes are resolved; a line-ending backslash
/// removes the newline and all blanks after it. Precondition: `raw` came from a token of
/// `kind` (so it is valid) and `out.len >= raw.len`; a decoded string is never longer.
pub fn decode_string(kind: Kind, raw: []const u8, out: []u8) []u8 {
    assert(is_string(kind));
    assert(out.len >= raw.len);
    const multiline = kind == .string_basic_multiline or kind == .string_literal_multiline;
    var src: usize = 0;
    if (multiline) {
        if (std.mem.startsWith(u8, raw, "\r\n")) {
            src = 2;
        } else if (std.mem.startsWith(u8, raw, "\n")) {
            src = 1;
        }
    }
    if (kind == .string_literal or kind == .string_literal_multiline) {
        const body = raw[src..];
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }
    var dst: usize = 0;
    while (src < raw.len) {
        if (raw[src] != '\\') {
            out[dst] = raw[src];
            dst += 1;
            src += 1;
            continue;
        }
        src += decode_escape(raw[src..], out, &dst);
    }
    assert(dst <= raw.len);
    return out[0..dst];
}

/// Decodes the escape at the start of `rest` (a backslash) into `out[dst.*..]`, advances `dst`
/// and returns the number of source bytes consumed.
fn decode_escape(rest: []const u8, out: []u8, dst: *usize) usize {
    assert(rest[0] == '\\');
    assert(rest.len >= 2);
    const simple: ?u8 = switch (rest[1]) {
        'b' => 0x08,
        't' => '\t',
        'n' => '\n',
        'f' => 0x0c,
        'r' => '\r',
        '"' => '"',
        '\\' => '\\',
        else => null,
    };
    if (simple) |byte| {
        out[dst.*] = byte;
        dst.* += 1;
        return 2;
    }
    if (rest[1] == 'u' or rest[1] == 'U') {
        const digits: usize = if (rest[1] == 'u') 4 else 8;
        var codepoint: u32 = 0;
        var group: usize = 0;
        while (group < digits) : (group += 4) {
            // proof: the lexer validated these hex digits when it returned the token.
            const unit = unicode_escape.parse_hex4(rest[2 + group ..][0..4]) catch unreachable;
            codepoint = (codepoint << 16) | unit;
        }
        var encoded = [_]u8{0} ** 4;
        // proof: the lexer rejected surrogates and values above U+10FFFF.
        const len = unicode_escape.encode(@intCast(codepoint), &encoded) catch unreachable;
        @memcpy(out[dst.*..][0..len], encoded[0..len]);
        dst.* += len;
        return 2 + digits;
    }
    // A line-ending backslash: drop the blanks and every newline after it.
    var used: usize = 1;
    while (used < rest.len and std.mem.findScalar(u8, " \t\r\n", rest[used]) != null) used += 1;
    return used;
}

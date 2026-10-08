//! json/scanner — a pull tokenizer over one complete input slice (ADR 0003 section 1).
//!
//! `next` yields object/array begin and end, keys, strings, numbers and the three literals,
//! then `.end` exactly once. It validates structure, separators, literal spelling and the RFC
//! 8259 section 6 number grammar. Number text is grammar-checked, not range-checked: range is
//! the consumer's business.
//!
//! Status (plan 004 item 2): a `.key`/`.string` token ends at the first unescaped quote and its
//! content is NOT validated yet. Item 3 adds UTF-8, control-byte, escape and surrogate checks,
//! plus the `decode_string` function and the four `ScanError` variants that go with them.
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

    /// Item 2 placeholder: ends at the first unescaped quote and checks nothing else.
    fn scan_string(scanner: *Scanner, diag: *Diagnostics, kind: Kind) ScanError!Token {
        assert(kind == .key or kind == .string);
        assert(scanner.input[scanner.offset] == '"');
        const start = scanner.offset;
        var index: usize = start + 1;
        var has_escapes = false;
        for (0..scanner.input.len) |_| {
            if (index >= scanner.input.len) {
                return scanner.fail(diag, error.UnexpectedEnd, @intCast(scanner.input.len));
            }
            const byte = scanner.input[index];
            if (byte == '"') break;
            if (byte == '\\') {
                has_escapes = true;
                index += 1;
            }
            index += 1;
        } else unreachable; // proof: each pass advances index, so it reaches input.len.
        assert(scanner.input[index] == '"');
        scanner.offset = @intCast(index + 1);
        return .{
            .kind = kind,
            .has_escapes = has_escapes,
            .offset = start,
            .raw = scanner.input[start + 1 .. index],
        };
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
        };
    }
};

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
}

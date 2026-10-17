//! path/jsonpath — JSONPath (RFC 9535 subset) query parsing (ADR 0004 section 6).
//!
//! `compile` turns a query text into a `Program`: up to `segments_max` segments, each a child or
//! descendant (`..`) step holding a selector list of names, indices, wildcards and slices. The
//! grammar is RFC 9535 section 2 including filters (`?expr`, see `filter.zig` for the compiled
//! form and `filter_parse.zig` for the grammar). Whitespace is accepted where the RFC allows it
//! (before a segment and around bracket selectors, never trailing and never after a `.`).
//!
//! Invariants: `segments_count <= segments_max`, `selectors_count <= selectors_max`, `names_len
//! <= query_len_max`; the selectors of segment `i` are the `selectors_count` entries starting at
//! its `selectors_first`, and the segments partition `selectors` in order; every name selector
//! indexes into `names`. Integers are within the I-JSON range of plus or minus 2^53 - 1.
//! Allocation: none. A `Program` is a fixed-size struct the caller owns; decoded names are
//! copied inline, so it borrows nothing from the query text. Read-only after `compile`.
//! Cost: O(query length). Segments are a flat loop; only filter nesting recurses, bounded by
//! `filter_depth_max` (ADR 0004 section 6). Embedded queries of filters share the `sub_segments`
//! and `sub_selectors` pools (at most `segments_max` and `selectors_max` entries in total, then
//! `TooManySegments`/`TooManySelectors`).

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const filter = @import("filter.zig");
const filter_parse = @import("filter_parse.zig");
const select_impl = @import("select.zig");
const Diagnostics = core.Diagnostics;

pub const segments_max: u32 = 32;
pub const selectors_max: u32 = 64;
pub const query_len_max: u32 = 1024;
/// Nesting of `(...)`, function calls and filters inside filters.
pub const filter_depth_max: u32 = 8;
/// Filter selectors, expression nodes and embedded queries in the whole query.
pub const filters_max: u32 = 32;
pub const exprs_max: u32 = 128;
pub const queries_max: u32 = 32;

/// Largest index, slice bound or step: the I-JSON exact-integer limit 2^53 - 1.
pub const integer_max: i64 = 9007199254740991;

pub const QueryError = error{
    InvalidSyntax,
    QueryTooLong,
    TooManySegments,
    TooManySelectors,
    IntegerOutOfRange,
    FilterTooDeep,
    /// More than `filters_max` filters, `exprs_max` expression nodes or `queries_max` embedded
    /// queries.
    FilterTooLong,
    /// `match` and `search` need an I-Regexp matcher (ADR 0004 section 6).
    UnsupportedFunction,
    /// An unknown function name, or a known one with the wrong argument count or type.
    UnknownFunction,
};

/// A decoded name: `len` bytes at `offset` of the program's `names` buffer.
pub const Name = struct { offset: u32, len: u32 };

/// `start`/`end` are absent when omitted; `step` is 1 when omitted (0 selects nothing).
pub const Slice = struct { start: ?i64, end: ?i64, step: i64 };

pub const Selector = union(enum) {
    name: Name,
    index: i64,
    wildcard,
    slice: Slice,
    /// Index into `Program.filters`.
    filter: u32,
};

/// One step of the query: the selectors at `selectors[selectors_first..][0..selectors_count]`,
/// applied to the children (or, with `descendant`, to every descendant) of each current node.
pub const Segment = struct {
    descendant: bool,
    selectors_first: u32,
    selectors_count: u32,
};

pub const Program = struct {
    segments_count: u32,
    selectors_count: u32,
    names_len: u32,
    segments: [segments_max]Segment,
    selectors: [selectors_max]Selector,
    names: [query_len_max]u8,
    /// Filter machinery; segments and selectors of embedded queries live in the `sub_` pools.
    filters_count: u32,
    exprs_count: u32,
    queries_count: u32,
    sub_segments_count: u32,
    sub_selectors_count: u32,
    filters: [filters_max]filter.Filter,
    exprs: [exprs_max]filter.Expr,
    queries: [queries_max]filter.QueryRef,
    sub_segments: [segments_max]Segment,
    sub_selectors: [selectors_max]Selector,

    /// The compiled segments, in query order.
    pub fn segment_list(program: *const Program) []const Segment {
        assert(program.segments_count <= segments_max);
        return program.segments[0..program.segments_count];
    }

    /// The selectors of `segment`, which must come from this program's `segment_list`.
    pub fn selector_list(program: *const Program, segment: Segment) []const Selector {
        assert(segment.selectors_first + segment.selectors_count <= program.selectors_count);
        assert(segment.selectors_count >= 1);
        return program.selectors[segment.selectors_first..][0..segment.selectors_count];
    }

    /// The decoded bytes of `name`, which must come from this program's selectors.
    pub fn name_text(program: *const Program, name: Name) []const u8 {
        assert(name.offset + name.len <= program.names_len);
        return program.names[name.offset..][0..name.len];
    }

    /// Asserts the structural invariants listed in the module header; tests call it after
    /// every `compile`.
    pub fn check_invariants(program: *const Program) void {
        assert(program.segments_count <= segments_max);
        assert(program.selectors_count <= selectors_max);
        assert(program.names_len <= query_len_max);

        var next_selector: u32 = 0;
        for (program.segment_list()) |segment| {
            assert(segment.selectors_first == next_selector);
            assert(segment.selectors_count >= 1);
            next_selector += segment.selectors_count;
            for (program.selector_list(segment)) |selector| switch (selector) {
                .name => |name| assert(name.offset + name.len <= program.names_len),
                .index => |value| assert(@abs(value) <= integer_max),
                .wildcard => {},
                .slice => |slice| {
                    assert(@abs(slice.step) <= integer_max);
                    if (slice.start) |start| assert(@abs(start) <= integer_max);
                    if (slice.end) |end| assert(@abs(end) <= integer_max);
                },
                .filter => |id| assert(id < program.filters_count),
            };
        }
        assert(next_selector == program.selectors_count);
        program.check_filter_invariants();
    }

    /// The filter half of `check_invariants`: counts within limits, every filter's nodes inside
    /// the node pool with children below parents, embedded queries inside the `sub_` pools.
    fn check_filter_invariants(program: *const Program) void {
        assert(program.filters_count <= filters_max);
        assert(program.exprs_count <= exprs_max);
        assert(program.queries_count <= queries_max);
        assert(program.sub_segments_count <= segments_max);
        assert(program.sub_selectors_count <= selectors_max);
        for (program.filters[0..program.filters_count], 0..) |one, id| {
            assert(one.first <= one.root);
            assert(one.root < program.exprs_count);
            const root = program.exprs[one.root];
            assert(root.owner == id);
            switch (root.node) {
                .exists, .negation, .compare, .conjunction, .disjunction => {},
                else => unreachable, // proof: parse_basic/parse_or only return logical nodes.
            }
        }
        for (program.exprs[0..program.exprs_count], 0..) |expr, index| {
            assert(expr.owner < program.filters_count);
            assert(index >= program.filters[expr.owner].first);
            assert(index <= program.filters[expr.owner].root);
            switch (expr.node) {
                .query => |query| assert(query < program.queries_count),
                .exists, .negation => |child| {
                    assert(child < index);
                    assert(program.exprs[child].owner == expr.owner);
                },
                .call => |call| {
                    assert(call.argument < index);
                    assert(program.exprs[call.argument].owner == expr.owner);
                },
                .compare => |pair| assert(@max(pair.left, pair.right) < index),
                .conjunction, .disjunction => |pair| assert(@max(pair.left, pair.right) < index),
                else => {},
            }
        }
        for (program.queries[0..program.queries_count]) |query| {
            assert(query.segments_first + query.segments_count <= program.sub_segments_count);
        }
        for (program.sub_segments[0..program.sub_segments_count]) |segment| {
            assert(segment.selectors_count >= 1);
            const end = segment.selectors_first + segment.selectors_count;
            assert(end <= program.sub_selectors_count);
        }
    }
};

pub const SelectError = select_impl.SelectError;

/// Evaluates `program` over `root` into `out`; see `path/select.zig` for the contract.
pub const select = select_impl.select;

/// Parses `query` into `program`. On error `diag` holds `1:col`, `col` the 1-based byte column of
/// the offending byte (`QueryTooLong`: of the first byte past `query_len_max`;
/// `TooManySegments`: of the segment's first byte; `TooManySelectors`: of the selector's first
/// byte; `IntegerOutOfRange`: of the number's first byte), and `program` is unspecified. On
/// success `diag` is untouched. The query is not retained. The whole query is checked for UTF-8
/// first, so an invalid byte hides an earlier syntax error; the segment limit is checked before
/// a segment is parsed, so a 33rd segment is `TooManySegments` even if it is malformed.
pub fn compile(program: *Program, query: []const u8, diag: *Diagnostics) QueryError!void {
    reset(program);
    var parser: Parser = .{
        .query = query,
        .program = program,
        .diag = diag,
        .pos = 0,
        .depth = 0,
        .filter_current = 0,
    };
    if (query.len > query_len_max) {
        return parser.fail(query_len_max, error.QueryTooLong, "query is longer than query_len_max");
    }
    // proof: query.len <= query_len_max, far below the u32 limit that makes find_invalid fail.
    const invalid = core.unicode.find_invalid(query) catch unreachable;
    if (invalid) |found| {
        return parser.fail(found.offset, error.InvalidSyntax, "query is not valid UTF-8");
    }
    try parser.parse_query();

    assert(program.segments_count <= segments_max);
    assert(program.selectors_count >= program.segments_count);
}

const blank_bytes = " \t\n\r";

/// Where the segments and selectors of one query are collected: the program's own arrays for
/// the main query, local buffers for an embedded one (copied into the `sub_` pools once the
/// query is complete, so its entries stay contiguous even when a filter nests another query).
pub const Builder = struct {
    segments: []Segment,
    selectors: []Selector,
    segments_count: u32,
    selectors_count: u32,
};

pub const Parser = struct {
    query: []const u8,
    program: *Program,
    diag: *Diagnostics,
    pos: u32,
    /// Open `(...)`, function calls and filters at the current position.
    depth: u32,
    /// Index of the filter whose expression is being parsed (the `owner` of new nodes).
    filter_current: u32,

    fn parse_query(parser: *Parser) QueryError!void {
        assert(parser.pos == 0);
        if (parser.query.len == 0 or parser.query[0] != '$') {
            return parser.fail(0, error.InvalidSyntax, "a query must start with '$'");
        }
        parser.pos = 1;
        var builder: Builder = .{
            .segments = &parser.program.segments,
            .selectors = &parser.program.selectors,
            .segments_count = 0,
            .selectors_count = 0,
        };
        try parser.parse_segments(&builder, false);
        parser.program.segments_count = builder.segments_count;
        parser.program.selectors_count = builder.selectors_count;
    }

    /// Parses `@` or `$` (at `pos`) and the segments after it as an embedded query; returns its
    /// index in `program.queries`.
    pub fn parse_embedded_query(parser: *Parser, absolute: bool) QueryError!u32 {
        const start = parser.pos;
        assert(parser.query[start] == (if (absolute) @as(u8, '$') else '@'));
        parser.pos += 1;
        var segments: [segments_max]Segment = undefined;
        var selectors: [selectors_max]Selector = undefined;
        var builder: Builder = .{
            .segments = &segments,
            .selectors = &selectors,
            .segments_count = 0,
            .selectors_count = 0,
        };
        try parser.parse_segments(&builder, true);
        return parser.commit_query(&builder, absolute, start);
    }

    fn commit_query(
        parser: *Parser,
        builder: *const Builder,
        absolute: bool,
        at: u32,
    ) QueryError!u32 {
        const program = parser.program;
        if (program.queries_count == queries_max) {
            return parser.fail(at, error.FilterTooLong, "more than queries_max embedded queries");
        }
        if (program.sub_segments_count + builder.segments_count > segments_max) {
            return parser.fail(at, error.TooManySegments, "more than segments_max segments");
        }
        if (program.sub_selectors_count + builder.selectors_count > selectors_max) {
            return parser.fail(at, error.TooManySelectors, "more than selectors_max selectors");
        }
        const segments_first = program.sub_segments_count;
        const selectors_first = program.sub_selectors_count;
        var singular = true;
        for (builder.segments[0..builder.segments_count]) |segment| {
            var copy = segment;
            copy.selectors_first += selectors_first;
            program.sub_segments[program.sub_segments_count] = copy;
            program.sub_segments_count += 1;
            const only = builder.selectors[segment.selectors_first];
            const single = segment.selectors_count == 1 and (only == .name or only == .index);
            if (segment.descendant or !single) singular = false;
        }
        for (builder.selectors[0..builder.selectors_count]) |selector| {
            program.sub_selectors[program.sub_selectors_count] = selector;
            program.sub_selectors_count += 1;
        }
        const index = program.queries_count;
        program.queries[index] = .{
            .absolute = absolute,
            .singular = singular,
            .segments_first = segments_first,
            .segments_count = builder.segments_count,
        };
        program.queries_count += 1;
        assert(program.sub_selectors_count == selectors_first + builder.selectors_count);
        return index;
    }

    /// Segments up to the end of the query (`embedded` false: trailing whitespace is an error)
    /// or up to the first byte that cannot start a segment (`embedded` true: the position is
    /// left before any blank that precedes it).
    fn parse_segments(parser: *Parser, builder: *Builder, embedded: bool) QueryError!void {
        for (0..segments_max + 1) |_| {
            const blank_start = parser.pos;
            parser.skip_blank();
            const byte = parser.peek();
            if (embedded and byte != '.' and byte != '[') {
                parser.pos = blank_start;
                return;
            }
            if (byte == null) {
                if (parser.pos == blank_start) return;
                return parser.fail(blank_start, error.InvalidSyntax, "trailing whitespace");
            }
            try parser.parse_segment(builder);
        }
        // proof: segment number segments_max + 1 fails with TooManySegments before the loop ends.
        unreachable;
    }

    fn parse_segment(parser: *Parser, builder: *Builder) QueryError!void {
        const start = parser.pos;
        if (builder.segments_count == segments_max) {
            return parser.fail(start, error.TooManySegments, "more than segments_max segments");
        }
        const first = builder.selectors_count;
        var descendant = false;
        switch (parser.query[start]) {
            '.' => {
                descendant = parser.peek_at(start + 1) == '.';
                parser.pos += if (descendant) 2 else 1;
                try parser.parse_after_dots(builder, descendant);
            },
            '[' => try parser.parse_bracket(builder),
            else => return parser.fail(start, error.InvalidSyntax, "expected '.', '..' or '['"),
        }
        const count = builder.selectors_count - first;
        assert(count >= 1);
        builder.segments[builder.segments_count] = .{
            .descendant = descendant,
            .selectors_first = first,
            .selectors_count = count,
        };
        builder.segments_count += 1;
    }

    /// After `.` or `..`: a wildcard or a shorthand name, and after `..` also a bracket list.
    fn parse_after_dots(parser: *Parser, builder: *Builder, descendant: bool) QueryError!void {
        const at = parser.pos;
        const byte = parser.peek() orelse {
            return parser.fail(at, error.InvalidSyntax, "a selector must follow the dots");
        };
        if (byte == '*') {
            parser.pos += 1;
            return parser.add_selector(builder, .wildcard, at);
        }
        if (byte == '[' and descendant) return parser.parse_bracket(builder);
        if (!is_name_first(byte)) {
            return parser.fail(at, error.InvalidSyntax, "a name or '*' must follow the dots");
        }
        const name_start = parser.program.names_len;
        for (0..parser.query.len) |_| {
            const next = parser.peek() orelse break;
            if (!is_name_first(next) and !std.ascii.isDigit(next)) break;
            parser.push_name_byte(next);
            parser.pos += 1;
        }
        const name: Name = .{ .offset = name_start, .len = parser.program.names_len - name_start };
        assert(name.len >= 1);
        return parser.add_selector(builder, .{ .name = name }, at);
    }

    fn parse_bracket(parser: *Parser, builder: *Builder) QueryError!void {
        assert(parser.query[parser.pos] == '[');
        parser.pos += 1;
        for (0..selectors_max + 1) |_| {
            parser.skip_blank();
            const at = parser.pos;
            const selector = try parser.parse_selector();
            try parser.add_selector(builder, selector, at);
            parser.skip_blank();
            const byte = parser.peek() orelse {
                return parser.fail(parser.pos, error.InvalidSyntax, "unterminated bracket");
            };
            switch (byte) {
                ',' => parser.pos += 1,
                ']' => {
                    parser.pos += 1;
                    return;
                },
                else => return parser.fail(parser.pos, error.InvalidSyntax, "expected ',' or ']'"),
            }
        }
        // proof: selector number selectors_max + 1 fails with TooManySelectors in add_selector.
        unreachable;
    }

    fn parse_selector(parser: *Parser) QueryError!Selector {
        const at = parser.pos;
        const byte = parser.peek() orelse {
            return parser.fail(at, error.InvalidSyntax, "a selector is expected");
        };
        switch (byte) {
            '*' => {
                parser.pos += 1;
                return .wildcard;
            },
            '\'', '"' => return .{ .name = try parser.parse_string(byte) },
            '-', '0'...'9', ':' => return parser.parse_index_or_slice(),
            '?' => return .{ .filter = try filter_parse.parse_filter(parser) },
            else => return parser.fail(at, error.InvalidSyntax, "a selector is expected"),
        }
    }

    /// `int` alone is an index; `[int] ':' [int] [':' [int]]` is a slice.
    fn parse_index_or_slice(parser: *Parser) QueryError!Selector {
        const first: ?i64 = if (parser.at_integer()) try parser.parse_integer() else null;
        parser.skip_blank();
        if (parser.peek() != ':') {
            assert(first != null);
            return .{ .index = first.? };
        }
        parser.pos += 1;
        parser.skip_blank();
        const end: ?i64 = if (parser.at_integer()) try parser.parse_integer() else null;
        parser.skip_blank();
        var step: i64 = 1;
        if (parser.peek() == ':') {
            parser.pos += 1;
            parser.skip_blank();
            if (parser.at_integer()) step = try parser.parse_integer();
        }
        return .{ .slice = .{ .start = first, .end = end, .step = step } };
    }

    /// `'-'? ('0' | [1-9][0-9]*)` within plus or minus `integer_max`; no `-0`, no leading zero.
    fn parse_integer(parser: *Parser) QueryError!i64 {
        const start = parser.pos;
        const negative = parser.peek() == '-';
        if (negative) parser.pos += 1;
        const digits_start = parser.pos;
        while (parser.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            parser.pos += 1;
        }
        const digits = parser.query[digits_start..parser.pos];
        if (digits.len == 0) {
            return parser.fail(parser.pos, error.InvalidSyntax, "a digit must follow '-'");
        }
        if (digits.len > 1 and digits[0] == '0') {
            return parser.fail(start, error.InvalidSyntax, "an integer has no leading zero");
        }
        if (negative and digits[0] == '0') {
            return parser.fail(start, error.InvalidSyntax, "'-0' is not an integer");
        }
        // proof: digits are all ASCII digits (checked above), so only Overflow can occur.
        const magnitude = std.fmt.parseInt(i64, digits, 10) catch |err| switch (err) {
            error.InvalidCharacter => unreachable,
            error.Overflow => return parser.fail_range(start),
        };
        if (magnitude > integer_max) return parser.fail_range(start);
        assert(magnitude >= 0);
        assert(parser.pos > start);
        return if (negative) -magnitude else magnitude;
    }

    pub fn parse_string(parser: *Parser, quote: u8) QueryError!Name {
        assert(quote == '\'' or quote == '"');
        assert(parser.query[parser.pos] == quote);
        const name_start = parser.program.names_len;
        parser.pos += 1;
        for (0..parser.query.len + 1) |_| {
            const byte = parser.peek() orelse {
                return parser.fail(parser.pos, error.InvalidSyntax, "unterminated string");
            };
            if (byte == quote) {
                parser.pos += 1;
                const len = parser.program.names_len - name_start;
                return .{ .offset = name_start, .len = len };
            }
            if (byte < 0x20) {
                return parser.fail(parser.pos, error.InvalidSyntax, "control character in string");
            }
            if (byte == '\\') {
                try parser.parse_escape(quote);
            } else {
                parser.push_name_byte(byte);
                parser.pos += 1;
            }
        }
        // proof: every iteration consumes a byte, so the end of the query errors above.
        unreachable;
    }

    fn parse_escape(parser: *Parser, quote: u8) QueryError!void {
        const at = parser.pos;
        assert(parser.query[at] == '\\');
        const code = parser.peek_at(at + 1) orelse {
            return parser.fail(at, error.InvalidSyntax, "an escape is incomplete");
        };
        const decoded: u8 = switch (code) {
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '/', '\\' => code,
            '\'', '"' => if (code == quote) code else {
                return parser.fail(at, error.InvalidSyntax, "this quote needs no escape here");
            },
            'u' => return parser.parse_unicode(at),
            else => return parser.fail(at, error.InvalidSyntax, "unknown escape"),
        };
        parser.push_name_byte(decoded);
        parser.pos = at + 2;
    }

    /// `\uXXXX`, with a following `\uXXXX` when the first unit is a high surrogate.
    fn parse_unicode(parser: *Parser, at: u32) QueryError!void {
        const first = parser.hex4_at(at + 2) orelse {
            return parser.fail(at, error.InvalidSyntax, "\\u needs four hex digits");
        };
        const follows = parser.peek_at(at + 6) == '\\' and parser.peek_at(at + 7) == 'u';
        const second: ?u16 = if (follows) parser.hex4_at(at + 8) else null;
        // proof: every EscapeError is one data error, a malformed surrogate pair in the query.
        const decoded = core.unicode_escape.decode_utf16(first, second) catch |err| switch (err) {
            error.InvalidHex, error.LoneSurrogate, error.InvalidCodepoint => {
                return parser.fail(at, error.InvalidSyntax, "a surrogate escape has no partner");
            },
        };
        var utf8: [4]u8 = undefined;
        // proof: decode_utf16 returns only scalar values, which always have a UTF-8 form.
        const len = core.unicode_escape.encode(decoded.codepoint, &utf8) catch unreachable;
        for (utf8[0..len]) |byte| parser.push_name_byte(byte);
        parser.pos = at + 6 * @as(u32, decoded.units_count);
        assert(parser.pos <= parser.query.len);
        assert(decoded.units_count == 1 or decoded.units_count == 2);
    }

    fn add_selector(
        parser: *Parser,
        builder: *Builder,
        selector: Selector,
        at: u32,
    ) QueryError!void {
        if (builder.selectors_count == selectors_max) {
            return parser.fail(at, error.TooManySelectors, "more than selectors_max selectors");
        }
        builder.selectors[builder.selectors_count] = selector;
        builder.selectors_count += 1;
        assert(builder.selectors_count <= selectors_max);
        assert(at < parser.query.len);
    }

    pub fn push_name_byte(parser: *Parser, byte: u8) void {
        const program = parser.program;
        // Decoded names never outgrow the query text, which is at most query_len_max bytes.
        assert(program.names_len < query_len_max);
        program.names[program.names_len] = byte;
        program.names_len += 1;
    }

    fn hex4_at(parser: *const Parser, offset: u32) ?u16 {
        if (offset + 4 > parser.query.len) return null;
        const digits = parser.query[offset..][0..4];
        return core.unicode_escape.parse_hex4(digits) catch null;
    }

    pub fn peek(parser: *const Parser) ?u8 {
        return parser.peek_at(parser.pos);
    }

    pub fn peek_at(parser: *const Parser, offset: u32) ?u8 {
        if (offset >= parser.query.len) return null;
        return parser.query[offset];
    }

    fn at_integer(parser: *const Parser) bool {
        const byte = parser.peek() orelse return false;
        return byte == '-' or std.ascii.isDigit(byte);
    }

    pub fn skip_blank(parser: *Parser) void {
        while (parser.peek()) |byte| {
            if (std.mem.findScalar(u8, blank_bytes, byte) == null) return;
            parser.pos += 1;
        }
    }

    fn fail_range(parser: *Parser, offset: u32) QueryError {
        return parser.fail(offset, error.IntegerOutOfRange, "integer is outside 2^53 - 1");
    }

    pub fn fail(parser: *Parser, offset: u32, err: QueryError, message: []const u8) QueryError {
        assert(offset <= parser.query.len);
        parser.diag.* = Diagnostics.init(
            1,
            offset + 1,
            message,
            core.diagnostics.snippet_of(parser.query, offset),
        );
        return err;
    }
};

fn is_name_first(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

fn reset(program: *Program) void {
    program.segments_count = 0;
    program.selectors_count = 0;
    program.names_len = 0;
    const empty_segment: Segment = .{
        .descendant = false,
        .selectors_first = 0,
        .selectors_count = 0,
    };
    @memset(&program.segments, empty_segment);
    @memset(&program.selectors, .wildcard);
    @memset(&program.names, 0);
    program.filters_count = 0;
    program.exprs_count = 0;
    program.queries_count = 0;
    program.sub_segments_count = 0;
    program.sub_selectors_count = 0;
    @memset(&program.filters, .{ .first = 0, .root = 0 });
    @memset(&program.exprs, .{ .owner = 0, .node = .literal_null });
    const empty_query: filter.QueryRef = .{
        .absolute = false,
        .singular = false,
        .segments_first = 0,
        .segments_count = 0,
    };
    @memset(&program.queries, empty_query);
    @memset(&program.sub_segments, empty_segment);
    @memset(&program.sub_selectors, .wildcard);
}

test {
    _ = @import("jsonpath_test.zig");
    _ = select_impl;
    _ = filter;
    _ = filter_parse;
}

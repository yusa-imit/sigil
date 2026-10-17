//! path/filter_parse — the filter grammar of RFC 9535 section 2.3.5, compiled into
//! `Program.exprs` (ADR 0004 section 6).
//!
//! `parse_filter` is called with the parser on the `?` of a filter selector. Precedence climbing:
//! `||` binds loosest, then `&&`, then a basic expression: a parenthesized expression, a
//! comparison of two operands, or an existence test of an embedded query, with an optional `!`
//! in front of a parenthesis or test (never a comparison). An operand is a literal, an
//! embedded query (`@` relative, `$` absolute) or a function call. Functions: `length`,
//! `count`, `value` (argument types checked here, so evaluation cannot fail on a type);
//! `match` and `search` are `UnsupportedFunction`, any other name `UnknownFunction`.
//!
//! Invariants: nodes are appended children first; every node's `owner` is the filter being
//! parsed when it was created; `parser.depth` counts open parentheses, calls and filters and
//! never exceeds `filter_depth_max` (`FilterTooDeep` past it). The grammar recurses once per
//! nesting level, so the machine stack is bounded by that constant (a few frames per level),
//! not by the input. Allocation: none; literal strings are decoded into the program's `names`.

const std = @import("std");
const core = @import("../core.zig");
const filter = @import("filter.zig");
const jsonpath = @import("jsonpath.zig");
const assert = std.debug.assert;
const Parser = jsonpath.Parser;
const QueryError = jsonpath.QueryError;

/// What an operand may be used as: literals and singular queries compare, any query tests
/// existence or feeds `count`/`value`, a function result compares.
const Kind = enum { literal, query_singular, query_many, function_value };

const Operand = struct { index: u32, kind: Kind, at: u32 };

/// Parses `?` and the expression after it; returns the new filter's index in `program.filters`.
pub fn parse_filter(parser: *Parser) QueryError!u32 {
    const at = parser.pos;
    assert(parser.query[at] == '?');
    const program = parser.program;
    if (parser.depth == jsonpath.filter_depth_max) {
        return parser.fail(at, error.FilterTooDeep, "filters nest deeper than filter_depth_max");
    }
    if (program.filters_count == jsonpath.filters_max) {
        return parser.fail(at, error.FilterTooLong, "more than filters_max filters");
    }
    const id = program.filters_count;
    program.filters_count += 1;
    const first = program.exprs_count;
    const outer = parser.filter_current;
    parser.filter_current = id;
    parser.depth += 1;
    parser.pos += 1;
    const root = try parse_or(parser);
    parser.depth -= 1;
    parser.filter_current = outer;
    program.filters[id] = .{ .first = first, .root = root };
    assert(first <= root);
    assert(root < program.exprs_count);
    return id;
}

fn parse_or(parser: *Parser) QueryError!u32 {
    var left = try parse_and(parser);
    for (0..jsonpath.exprs_max) |_| {
        parser.skip_blank();
        const at = parser.pos;
        if (!at_pair(parser, '|')) return left;
        parser.pos += 2;
        const right = try parse_and(parser);
        left = try new_node(parser, .{ .disjunction = .{ .left = left, .right = right } }, at);
    }
    // proof: each iteration appends a node, so exprs_max iterations fail with FilterTooLong.
    unreachable;
}

fn parse_and(parser: *Parser) QueryError!u32 {
    var left = try parse_basic(parser);
    for (0..jsonpath.exprs_max) |_| {
        parser.skip_blank();
        const at = parser.pos;
        if (!at_pair(parser, '&')) return left;
        parser.pos += 2;
        const right = try parse_basic(parser);
        left = try new_node(parser, .{ .conjunction = .{ .left = left, .right = right } }, at);
    }
    // proof: each iteration appends a node, so exprs_max iterations fail with FilterTooLong.
    unreachable;
}

fn parse_basic(parser: *Parser) QueryError!u32 {
    parser.skip_blank();
    const at = parser.pos;
    const negate = parser.peek() == '!';
    if (negate) {
        parser.pos += 1;
        parser.skip_blank();
    }
    const inner = if (parser.peek() == '(')
        try parse_paren(parser)
    else
        try parse_comparison_or_test(parser, negate);
    if (!negate) return inner;
    return new_node(parser, .{ .negation = inner }, at);
}

fn parse_paren(parser: *Parser) QueryError!u32 {
    const at = parser.pos;
    assert(parser.query[at] == '(');
    try enter(parser, at);
    parser.pos += 1;
    const inner = try parse_or(parser);
    try expect(parser, ')', "expected ')'");
    parser.depth -= 1;
    return inner;
}

fn parse_comparison_or_test(parser: *Parser, negate: bool) QueryError!u32 {
    const left = try parse_operand(parser);
    parser.skip_blank();
    const op_at = parser.pos;
    if (read_compare_op(parser)) |op| {
        if (negate) {
            return parser.fail(op_at, error.InvalidSyntax, "'!' cannot negate a comparison");
        }
        try require_comparable(parser, left);
        const right = try parse_operand(parser);
        try require_comparable(parser, right);
        const compare: filter.Node = .{ .compare = .{
            .op = op,
            .left = left.index,
            .right = right.index,
        } };
        return new_node(parser, compare, op_at);
    }
    switch (left.kind) {
        .query_singular, .query_many => return new_node(parser, .{ .exists = left.index }, left.at),
        .literal, .function_value => {
            return parser.fail(left.at, error.InvalidSyntax, "a test needs a query, not a value");
        },
    }
}

fn require_comparable(parser: *Parser, operand: Operand) QueryError!void {
    if (operand.kind != .query_many) return;
    return parser.fail(operand.at, error.InvalidSyntax, "a comparison needs a singular query");
}

fn parse_operand(parser: *Parser) QueryError!Operand {
    parser.skip_blank();
    const at = parser.pos;
    const byte = parser.peek() orelse {
        return parser.fail(at, error.InvalidSyntax, "an operand is expected");
    };
    switch (byte) {
        '@', '$' => {
            const query = try parser.parse_embedded_query(byte == '$');
            const singular = parser.program.queries[query].singular;
            const kind: Kind = if (singular) .query_singular else .query_many;
            const index = try new_node(parser, .{ .query = query }, at);
            return .{ .index = index, .kind = kind, .at = at };
        },
        '\'', '"' => {
            const name = try parser.parse_string(byte);
            const index = try new_node(parser, .{ .literal_string = name }, at);
            return .{ .index = index, .kind = .literal, .at = at };
        },
        '-', '0'...'9' => return parse_number(parser),
        'a'...'z' => return parse_word(parser),
        else => return parser.fail(at, error.InvalidSyntax, "an operand is expected"),
    }
}

/// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, exact through `core.number`.
fn parse_number(parser: *Parser) QueryError!Operand {
    const start = parser.pos;
    var end = start + 1;
    for (0..parser.query.len) |_| {
        const byte = parser.peek_at(end) orelse break;
        const sign_ok = (byte == '+' or byte == '-') and (parser.query[end - 1] | 0x20) == 'e';
        if (!std.ascii.isDigit(byte) and byte != '.' and (byte | 0x20) != 'e' and !sign_ok) break;
        end += 1;
    }
    const text = parser.query[start..end];
    const digits = if (text[0] == '-') text[1..] else text;
    const leading_zero = digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1]);
    if (!core.number.is_decimal_literal(text) or leading_zero) {
        return parser.fail(start, error.InvalidSyntax, "a number literal is malformed");
    }
    // proof: every NumberError is one data error, a literal outside the exact i64/u64/f64 range.
    const value = core.number.parse_decimal(text) catch |err| switch (err) {
        error.IntegerAboveMax, error.IntegerBelowMin, error.FloatOutOfRange => {
            return parser.fail(start, error.IntegerOutOfRange, "number is out of range");
        },
    };
    parser.pos = end;
    const node: filter.Node = switch (value) {
        .int => |number| .{ .literal_int = number },
        .uint => |number| .{ .literal_uint = number },
        .float => |number| .{ .literal_float = number },
        else => unreachable, // proof: parse_decimal returns only .int, .uint or .float.
    };
    return .{ .index = try new_node(parser, node, start), .kind = .literal, .at = start };
}

/// `true`, `false`, `null`, or a function call `name(`.
fn parse_word(parser: *Parser) QueryError!Operand {
    const start = parser.pos;
    var end = start;
    while (parser.peek_at(end)) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') break;
        end += 1;
    }
    const word = parser.query[start..end];
    if (parser.peek_at(end) == '(') return parse_call(parser, word, start);
    const node: filter.Node = if (std.mem.eql(u8, word, "true"))
        .{ .literal_bool = true }
    else if (std.mem.eql(u8, word, "false"))
        .{ .literal_bool = false }
    else if (std.mem.eql(u8, word, "null"))
        .literal_null
    else
        return parser.fail(start, error.InvalidSyntax, "an operand is expected");
    parser.pos = end;
    return .{ .index = try new_node(parser, node, start), .kind = .literal, .at = start };
}

fn parse_call(parser: *Parser, name: []const u8, start: u32) QueryError!Operand {
    const function: filter.Function = if (std.mem.eql(u8, name, "length"))
        .length
    else if (std.mem.eql(u8, name, "count"))
        .count
    else if (std.mem.eql(u8, name, "value"))
        .value
    else if (std.mem.eql(u8, name, "match") or std.mem.eql(u8, name, "search"))
        return parser.fail(start, error.UnsupportedFunction, "match and search are not supported")
    else
        return parser.fail(start, error.UnknownFunction, "unknown function");
    parser.pos = start + @as(u32, @intCast(name.len));
    try enter(parser, parser.pos);
    parser.pos += 1;
    parser.skip_blank();
    if (parser.peek() == ')' or parser.peek() == null) {
        return parser.fail(parser.pos, error.UnknownFunction, "a function takes one argument");
    }
    const argument = try parse_operand(parser);
    parser.skip_blank();
    if (parser.peek() == ',') {
        return parser.fail(parser.pos, error.UnknownFunction, "a function takes one argument");
    }
    try expect(parser, ')', "expected ')'");
    parser.depth -= 1;
    const wants_nodes = function != .length;
    const is_query = argument.kind == .query_singular or argument.kind == .query_many;
    const accepted = if (wants_nodes) is_query else argument.kind != .query_many;
    if (!accepted) {
        return parser.fail(argument.at, error.UnknownFunction, "the argument has the wrong type");
    }
    const call: filter.Node = .{ .call = .{ .function = function, .argument = argument.index } };
    return .{ .index = try new_node(parser, call, start), .kind = .function_value, .at = start };
}

fn enter(parser: *Parser, at: u32) QueryError!void {
    if (parser.depth == jsonpath.filter_depth_max) {
        return parser.fail(at, error.FilterTooDeep, "nests deeper than filter_depth_max");
    }
    parser.depth += 1;
}

fn expect(parser: *Parser, byte: u8, message: []const u8) QueryError!void {
    parser.skip_blank();
    if (parser.peek() != byte) return parser.fail(parser.pos, error.InvalidSyntax, message);
    parser.pos += 1;
}

fn at_pair(parser: *const Parser, byte: u8) bool {
    return parser.peek() == byte and parser.peek_at(parser.pos + 1) == byte;
}

/// Consumes a comparison operator at `pos`, longest first (`<=` before `<`).
fn read_compare_op(parser: *Parser) ?filter.CompareOp {
    const first = parser.peek() orelse return null;
    const second = parser.peek_at(parser.pos + 1);
    const pair = second == '=';
    const op: filter.CompareOp = switch (first) {
        '=' => if (pair) .eq else return null,
        '!' => if (pair) .ne else return null,
        '<' => if (pair) .le else .lt,
        '>' => if (pair) .ge else .gt,
        else => return null,
    };
    parser.pos += if (pair) 2 else 1;
    return op;
}

fn new_node(parser: *Parser, node: filter.Node, at: u32) QueryError!u32 {
    const program = parser.program;
    if (program.exprs_count == jsonpath.exprs_max) {
        return parser.fail(at, error.FilterTooLong, "more than exprs_max expression nodes");
    }
    const index = program.exprs_count;
    program.exprs[index] = .{ .owner = parser.filter_current, .node = node };
    program.exprs_count += 1;
    assert(program.exprs_count <= jsonpath.exprs_max);
    assert(parser.filter_current < program.filters_count);
    return index;
}

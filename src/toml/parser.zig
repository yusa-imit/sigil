//! toml/parser — turns a TOML 1.0.0 document into a `core.Value` map (ADR 0005 §3, 4, 6, 7).
//!
//! `parse_value` drives the pull lexer one statement at a time: a `[table]` or `[[array]]`
//! header, or a `key = value` line whose key may be dotted. Tables are built in a
//! `scratch.Scratch` (hash-indexed, out-of-order friendly, one `State` per table that decides
//! which redefinitions are legal) and copied once into the tree by `scratch.materialize`, so
//! every `Map` has exactly its final size and keeps document order.
//!
//! Values are scalars, strings, arrays (any mix of types, newlines, comments and a trailing
//! comma allowed) and single-line inline tables (frozen once closed, no trailing comma). They
//! nest on an explicit stack of at most `core.value.nesting_max` frames, one per open container;
//! the scratch depth check refuses a deeper container before it is pushed.
//!
//! Every error writes `diag` once, at the first byte of the offending token or key segment
//! (a conflict names the line of the earlier definition); success never writes it. There is no
//! recursion: nesting is bounded by `ParseOptions.depth_max` and held in scratch nodes.
//!
//! Allocation: `gpa` is used for the two scratch arrays only (sized from the input length,
//! freed before return, success or error); strings and keys go to the tree arena. Nothing is
//! stored: `gpa` is not kept past the call.

const std = @import("std");
const core = @import("../core.zig");
const lexer_module = @import("lexer.zig");
const scalar = @import("scalar.zig");
const scratch_module = @import("scratch.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diagnostics = core.Diagnostics;
const Lexer = lexer_module.Lexer;
const Path = @import("../reflect/context.zig").Path;
const Token = lexer_module.Token;
const Key = scratch_module.Key;
const Scratch = scratch_module.Scratch;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// The 17 errors of ADR 0005 section 6, a comptime test pins the members.
pub const ParseValueError = lexer_module.ScanError || scalar.Error || scratch_module.Error ||
    error{InputTooLarge};

pub const ParseOptions = struct {
    /// Containers on a path including the root, `1..core.value.nesting_max` (ADR 0005 section 5).
    depth_max: u16,
    /// Longest accepted input; longer is `InputTooLarge`. At most `Lexer.input_len_max`.
    bytes_max: u32,
};

/// Parses `input` and returns the root table. The result and everything it points at lives
/// until `tree.deinit()`; `tree.root` is not set. On error `diag` is written once.
/// Preconditions: `options.depth_max` in `1..core.value.nesting_max`.
pub fn parse_value(
    gpa: Allocator,
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    if (input.len > options.bytes_max) {
        write_diag(input, diag, 0, "input is longer than bytes_max");
        return error.InputTooLarge;
    }
    var parser: Parser = undefined;
    // proof: `begin` returns the two names below and no I/O error.
    parser.begin(gpa, tree, input, options.depth_max, diag) catch |err| switch (err) {
        error.InputTooLarge => {
            write_diag(input, diag, 0, "input is longer than the lexer limit");
            return error.InputTooLarge;
        },
        error.OutOfMemory => return parser.out_of_memory(0),
    };
    defer parser.scratch.deinit(gpa);

    try parser.run();
    parser.scratch.check_invariants();
    const root = scratch_module.materialize(&parser.scratch, tree) catch {
        return parser.out_of_memory(0);
    };
    assert(root == .map);
    return root;
}

/// The byte offset in `input` of the value that `path` names, or of the deepest value along it
/// that exists; 0 when `input` does not parse (or memory for a second parse is short). It
/// parses again into a scratch tree that is dropped on return, so call it on the error path
/// only: `toml.parse` uses it to put a reflect failure on a line:col. Tables sit at their key
/// or header, array elements at their first byte (ADR 0005 section 6).
/// Preconditions: `options.depth_max` in `1..core.value.nesting_max`; `path.count` is at most
/// `core.value.nesting_max`.
pub fn locate(
    gpa: Allocator,
    input: []const u8,
    options: ParseOptions,
    path: *const Path,
) u32 {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    assert(path.count <= core.value.nesting_max);
    if (input.len > options.bytes_max) return 0;

    var tree: ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "", null);
    var parser: Parser = undefined;
    parser.begin(gpa, &tree, input, options.depth_max, &diag) catch return 0;
    defer parser.scratch.deinit(gpa);

    parser.run() catch return 0;
    const offset = parser.scratch.offset_of_path(path.segments[0..path.count]);
    assert(offset <= input.len);
    return offset;
}

/// Where a value goes: under a key of a table, or at the end of an array.
const Target = union(enum) {
    keyed: KeyPath,
    element: u32,
};

/// A table and the last segment of a dotted key inside it.
const KeyPath = struct { cursor: u32, key: Key };

/// An open array or inline table, and what the next token of it may be.
const Frame = struct {
    node: u32,
    is_array: bool,
    need: Need,
};

const Need = enum(u8) {
    /// Just opened: a value (or key) or the closer.
    first,
    /// After a comma: a value or key; an array also takes the closer (trailing comma).
    after_comma,
    /// After a value: a comma or the closer.
    comma_or_close,
};

const Step = union(enum) {
    none,
    close,
    open: Frame,
};

/// The key named in a conflict message: the real one, or for an array element the token itself.
fn target_key(target: Target, token: Token) Key {
    switch (target) {
        .keyed => |keyed| return keyed.key,
        .element => return .{ .bytes = token.raw, .offset = token.offset, .owned = false },
    }
}

const Parser = struct {
    input: []const u8,
    tree: *ValueTree,
    diag: *Diagnostics,
    lexer: Lexer,
    scratch: Scratch,
    /// The table that the keys of the current section go into.
    current: u32,

    /// Fills `parser` in place and allocates its scratch; on error the scratch is not live and
    /// `input`, `tree` and `diag` are set. `InputTooLarge` is the lexer's own limit.
    fn begin(
        parser: *Parser,
        gpa: Allocator,
        tree: *ValueTree,
        input: []const u8,
        depth_max: u16,
        diag: *Diagnostics,
    ) error{ InputTooLarge, OutOfMemory }!void {
        parser.input = input;
        parser.tree = tree;
        parser.diag = diag;
        parser.current = scratch_module.root_index;
        parser.lexer.init(input) catch return error.InputTooLarge;
        const input_len: u32 = @intCast(input.len); // The lexer accepted it, so it fits a u32.
        try parser.scratch.init(gpa, input_len, depth_max);
        assert(parser.scratch.node_count == 1);
    }

    /// The statement loop. Each iteration consumes at least one byte, or returns at `.end`.
    fn run(parser: *Parser) ParseValueError!void {
        for (0..parser.input.len + 1) |_| {
            const token = try parser.lexer.next(parser.diag, .key);
            const ended = switch (token.kind) {
                .end => true,
                .newline => false,
                .bracket_open => try parser.table_header(false),
                .table_array_open => try parser.table_header(true),
                .bare_key, .string_basic, .string_literal => try parser.key_value(token),
                else => return parser.unexpected(token),
            };
            if (ended) return;
        }
        unreachable; // proof: each non-end token consumes a byte, so len + 1 rounds reach `.end`.
    }

    /// `[a.b]` or `[[a.b]]`, after the opening token. Returns whether the input ended.
    fn table_header(parser: *Parser, array: bool) ParseValueError!bool {
        const close: lexer_module.Kind = if (array) .table_array_close else .bracket_close;
        var cursor: u32 = scratch_module.root_index;
        var key = try parser.read_key(try parser.lexer.next(parser.diag, .key));
        for (0..parser.input.len + 1) |_| {
            const token = try parser.lexer.next(parser.diag, .key);
            if (token.kind == .dot) {
                cursor = parser.scratch.header_pass(cursor, key) catch |err| {
                    return parser.scratch_fail(err, key);
                };
                key = try parser.read_key(try parser.lexer.next(parser.diag, .key));
                continue;
            }
            if (token.kind != close) return parser.unexpected(token);
            cursor = parser.scratch.header_end(cursor, key, array) catch |err| {
                return parser.scratch_fail(err, key);
            };
            parser.current = cursor;
            return parser.line_end();
        }
        unreachable; // proof: each iteration consumes a dot and a key, so at most len iterations.
    }

    /// `a.b.c = value`, after its first token. Returns whether the input ended.
    fn key_value(parser: *Parser, first: Token) ParseValueError!bool {
        const target = try parser.key_path(parser.current, first);
        try parser.read_value(target.cursor, target.key);
        return parser.line_end();
    }

    /// The dotted key `a.b.c =` from its first token through the `=`: creates the tables of
    /// the non-last segments under `cursor` and returns the table and the last segment.
    fn key_path(parser: *Parser, start: u32, first: Token) ParseValueError!KeyPath {
        var cursor = start;
        var key = try parser.read_key(first);
        for (0..parser.input.len + 1) |_| {
            const token = try parser.lexer.next(parser.diag, .key);
            switch (token.kind) {
                .dot => {
                    cursor = parser.scratch.dotted_pass(cursor, key) catch |err| {
                        return parser.scratch_fail(err, key);
                    };
                    key = try parser.read_key(try parser.lexer.next(parser.diag, .key));
                },
                .equals => return .{ .cursor = cursor, .key = key },
                else => return parser.unexpected(token),
            }
        }
        unreachable; // proof: each iteration consumes a dot and a key, so at most len iterations.
    }

    /// The value after `=`, stored under `key` in table `parent`. Containers are filled
    /// iteratively: `stack` holds the open ones, the innermost last.
    fn read_value(parser: *Parser, parent: u32, key: Key) ParseValueError!void {
        var stack: [core.value.nesting_max]Frame = undefined;
        var depth: u32 = 0;
        const first = try parser.lexer.next(parser.diag, .value);
        const root_target: Target = .{ .keyed = .{ .cursor = parent, .key = key } };
        stack[0] = (try parser.place(root_target, first)) orelse return;
        depth = 1;
        for (0..parser.input.len + 1) |_| {
            switch (try parser.step(&stack[depth - 1])) {
                .none => {},
                .close => {
                    depth -= 1;
                    if (depth == 0) return;
                },
                .open => |frame| {
                    assert(depth < stack.len); // proof: `link` refused a container past depth_max.
                    stack[depth] = frame;
                    depth += 1;
                },
            }
        }
        unreachable; // proof: each step consumes a token, and a non-`.end` token is a byte.
    }

    /// One token of the innermost open container: a value, a comma or the closer.
    fn step(parser: *Parser, frame: *Frame) ParseValueError!Step {
        if (frame.is_array) return parser.array_step(frame);
        return parser.table_step(frame);
    }

    fn array_step(parser: *Parser, frame: *Frame) ParseValueError!Step {
        assert(frame.is_array);
        const token = try parser.next_array_token();
        switch (frame.need) {
            .comma_or_close => switch (token.kind) {
                .comma => frame.need = .after_comma,
                .bracket_close => return .close,
                else => return parser.unexpected(token),
            },
            .first, .after_comma => {
                if (token.kind == .bracket_close) return .close;
                frame.need = .comma_or_close;
                const opened = try parser.place(.{ .element = frame.node }, token);
                if (opened) |opened_frame| return .{ .open = opened_frame };
            },
        }
        return .none;
    }

    fn table_step(parser: *Parser, frame: *Frame) ParseValueError!Step {
        assert(!frame.is_array);
        const token = try parser.lexer.next(parser.diag, .key);
        switch (frame.need) {
            .comma_or_close => switch (token.kind) {
                .comma => {
                    frame.need = .after_comma;
                    return .none;
                },
                .brace_close => return .close,
                else => return parser.unexpected(token),
            },
            .first => if (token.kind == .brace_close) return .close,
            .after_comma => {},
        }
        frame.need = .comma_or_close;
        const target = try parser.key_path(frame.node, token);
        const value_token = try parser.lexer.next(parser.diag, .value);
        const keyed: Target = .{ .keyed = target };
        const opened = try parser.place(keyed, value_token);
        if (opened) |opened_frame| return .{ .open = opened_frame };
        return .none;
    }

    /// The next token inside an array, skipping the newlines that arrays allow.
    fn next_array_token(parser: *Parser) ParseValueError!Token {
        for (0..parser.input.len + 1) |_| {
            const token = try parser.lexer.next(parser.diag, .value);
            if (token.kind != .newline) return token;
        }
        unreachable; // proof: each newline is a byte, so at most len newlines precede a token.
    }

    /// Stores the value that starts at `token` at `target`. A scalar or string is stored and
    /// gives null; `[` or `{` creates the container and returns its frame to fill.
    fn place(parser: *Parser, target: Target, token: Token) ParseValueError!?Frame {
        switch (token.kind) {
            .bracket_open => return try parser.place_container(target, token, .array_static),
            .brace_open => return try parser.place_container(target, token, .inline_table),
            else => {},
        }
        const value = try parser.scalar_value(token);
        const stored = switch (target) {
            .keyed => |keyed| parser.scratch.insert_scalar(keyed.cursor, keyed.key, value),
            .element => |array| parser.scratch.append_scalar(array, value, token.offset),
        };
        stored catch |err| return parser.scratch_fail(err, target_key(target, token));
        return null;
    }

    fn place_container(
        parser: *Parser,
        target: Target,
        token: Token,
        state: scratch_module.State,
    ) ParseValueError!Frame {
        assert(token.kind == .bracket_open or token.kind == .brace_open);
        const created = switch (target) {
            .keyed => |keyed| parser.scratch.insert_container(keyed.cursor, keyed.key, state),
            .element => |array| parser.scratch.append_container(array, state, token.offset),
        };
        const node = created catch |err| return parser.scratch_fail(err, target_key(target, token));
        return .{ .node = node, .is_array = state == .array_static, .need = .first };
    }

    /// The end of a statement: a newline (false) or the end of the input (true).
    fn line_end(parser: *Parser) ParseValueError!bool {
        const token = try parser.lexer.next(parser.diag, .key);
        return switch (token.kind) {
            .newline => false,
            .end => true,
            else => parser.unexpected(token),
        };
    }

    /// A key segment: bare, or a single-line quoted string (escapes decoded into the arena).
    fn read_key(parser: *Parser, token: Token) ParseValueError!scratch_module.Key {
        switch (token.kind) {
            .bare_key => return .{ .bytes = token.raw, .offset = token.offset, .owned = false },
            .string_basic, .string_literal => {
                if (!token.has_escapes) {
                    return .{ .bytes = token.raw, .offset = token.offset, .owned = false };
                }
                const buffer = try parser.alloc_bytes(token.raw.len, token.offset);
                const bytes = lexer_module.decode_string(token.kind, token.raw, buffer);
                return .{ .bytes = bytes, .offset = token.offset, .owned = true };
            },
            else => return parser.unexpected(token),
        }
    }

    /// A scalar or a string value; any other token is `UnexpectedToken` (or `UnexpectedEnd`).
    fn scalar_value(parser: *Parser, token: Token) ParseValueError!Value {
        switch (token.kind) {
            .scalar => return scalar.parse(token.raw) catch |err| {
                return parser.scalar_fail(err, token);
            },
            .string_basic,
            .string_literal,
            .string_basic_multiline,
            .string_literal_multiline,
            => return parser.string_value(token),
            else => return parser.unexpected(token),
        }
    }

    fn string_value(parser: *Parser, token: Token) ParseValueError!Value {
        assert(lexer_module.is_string(token.kind));
        const single = token.kind == .string_basic or token.kind == .string_literal;
        if (single and !token.has_escapes) {
            return parser.tree.dupe_string(token.raw) catch parser.out_of_memory(token.offset);
        }
        const buffer = try parser.alloc_bytes(token.raw.len, token.offset);
        const decoded = lexer_module.decode_string(token.kind, token.raw, buffer);
        assert(decoded.len <= token.raw.len);
        return .{ .string = decoded };
    }

    fn alloc_bytes(parser: *Parser, len: usize, offset: u32) ParseValueError![]u8 {
        return parser.tree.arena.allocator().alloc(u8, len) catch parser.out_of_memory(offset);
    }

    fn unexpected(parser: *Parser, token: Token) ParseValueError {
        if (token.kind == .end) {
            parser.fail(token.offset, "unexpected end of input");
            return error.UnexpectedEnd;
        }
        parser.fail(token.offset, "unexpected token");
        return error.UnexpectedToken;
    }

    fn out_of_memory(parser: *Parser, offset: u32) ParseValueError {
        parser.fail(offset, "out of memory");
        return error.OutOfMemory;
    }

    fn scalar_fail(parser: *Parser, err: scalar.Error, token: Token) ParseValueError {
        // proof: the switch covers every `scalar.Error` variant; a new one fails the build here.
        const message = switch (err) {
            error.UnexpectedToken => "not a boolean, number or date-time",
            error.InvalidNumber => "invalid number",
            error.InvalidDatetime => "invalid date or time",
            error.IntegerAboveMax => "integer above 9223372036854775807",
            error.IntegerBelowMin => "integer below -9223372036854775808",
            error.FloatOutOfRange => "float out of range",
        };
        parser.fail(token.offset, message);
        return err;
    }

    /// A state-machine conflict at `key`; the message names the line of the earlier definition.
    fn scratch_fail(
        parser: *Parser,
        err: scratch_module.Error,
        key: scratch_module.Key,
    ) ParseValueError {
        const earlier = core.diagnostics.position_of(parser.input, parser.scratch.conflict_offset);
        var shown_len = @min(key.bytes.len, 40);
        // Do not cut inside a UTF-8 sequence: back up to a boundary.
        while (shown_len > 0 and shown_len < key.bytes.len and
            (key.bytes[shown_len] & 0xC0) == 0x80) shown_len -= 1;
        const shown = key.bytes[0..shown_len];
        var buffer: [160]u8 = undefined;
        // proof: the switch covers every `scratch.Error` variant; a new one fails the build here.
        const text = switch (err) {
            error.DuplicateKey => std.fmt.bufPrint(
                &buffer,
                "duplicate key `{s}` (first defined at line {d})",
                .{ shown, earlier.line },
            ),
            error.TableRedefined => std.fmt.bufPrint(
                &buffer,
                "table `{s}` cannot be redefined or extended (defined at line {d})",
                .{ shown, earlier.line },
            ),
            error.TypeConflict => std.fmt.bufPrint(
                &buffer,
                "`{s}` is already defined as another kind of value (line {d})",
                .{ shown, earlier.line },
            ),
            error.TooDeep => std.fmt.bufPrint(&buffer, "`{s}` nests too deeply", .{shown}),
            error.OutOfMemory => std.fmt.bufPrint(&buffer, "out of memory", .{}),
        } catch "conflicting definition";
        parser.fail(key.offset, text);
        return err;
    }

    fn fail(parser: *Parser, offset: u32, message: []const u8) void {
        assert(offset <= parser.input.len);
        assert(message.len > 0);
        write_diag(parser.input, parser.diag, offset, message);
    }
};

fn write_diag(input: []const u8, diag: *Diagnostics, offset: u32, message: []const u8) void {
    assert(offset <= input.len);
    const position = core.diagnostics.position_of(input, offset);
    const snippet = core.diagnostics.snippet_of(input, offset);
    diag.* = Diagnostics.init(position.line, position.col, message, snippet);
}

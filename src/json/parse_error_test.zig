//! Every variant of `json.ParseError` (plan 004 item 8, ADR 0003 sections 3 and 8): the 15
//! `ParseValueError` variants of the scanner and the DOM plus the 11 of `reflect.ParseError`,
//! 23 names after the merge. Each is provoked through `json.parse(T, ...)`, with the `line:col`
//! and the snippet of the failing byte (or of the failing value's first byte, for reflect) taken
//! from a plain scan of the test text, and with reflect's `"{path}: {reason}"` message kept.
//! Also pinned: success leaves `diag` untouched, `bytes_max` and `depth_max` boundaries,
//! `DuplicateKey` under `.reject` and `.last`, `MissingField`/`UnknownField` on the object's `{`,
//! every allocation failing in turn, and a fuzz target over arbitrary bytes.

const std = @import("std");
const core = @import("../core.zig");
const reflect = @import("../reflect.zig");
const json = @import("../json.zig");
const assert = std.debug.assert;
const testing = std.testing;

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const position_none = core.diagnostics.position_none;

const sentinel_line: u32 = 777;
const sentinel_col: u32 = 5;
const never: u32 = std.math.maxInt(u32);
/// ADR 0003 section 2: the snippet starts at most this many bytes before the offset.
const snippet_half = 40;
/// `Diagnostics` snippet capacity; a longer line is cut and ends in `...`.
const snippet_len_max = 80;

const base_options: json.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const last_options: json.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .last,
};

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, sentinel_col, "untouched", null);
}

fn expect_untouched(diag: *const Diagnostics) !void {
    try testing.expectEqual(sentinel_line, diag.line);
    try testing.expectEqual(sentinel_col, diag.col);
    try testing.expectEqualStrings("untouched", diag.message());
    try testing.expect(diag.snippet_text() == null);
}

/// Parses `text` as `T` under `opts`; asserts that success left `diag` untouched.
fn parse_ok(comptime T: type, tree: *ValueTree, text: []const u8, opts: json.ParseOptions) !T {
    var diag = fresh_diag();
    const got = try json.parse(T, tree, text, opts, &diag);
    try expect_untouched(&diag);
    return got;
}

const Server = struct { host: []const u8, port: u16 = 8080 };
const Fleet = struct { name: []const u8, servers: []const Server };
const Wrapper = struct { server: Server };
const Mode = enum { fast, slow };
const Modal = struct { mode: Mode };
const Wide = struct { ratio: f64 };
const Narrow = struct { ratio: f32 };
const Grid = struct { grid: [2]u8 };
const Strict = struct {
    name: []const u8,
    pub const sigil_options = .{ .deny_unknown_fields = true };
};

/// A hook that accepts `"<digits>ms"` only.
const Duration = struct {
    ms: u64,

    pub fn sigilParse(context: *reflect.Context, value: Value) reflect.ParseError!Duration {
        assert(context.depth <= core.value.nesting_max);
        const text = switch (value) {
            .string => |text| text,
            else => return error.TypeMismatch,
        };
        const digits = if (std.mem.endsWith(u8, text, "ms")) text[0 .. text.len - 2] else "";
        const ms = std.fmt.parseInt(u64, digits, 10) catch {
            return context.fail(error.InvalidValue, "bad duration \"{s}\"", .{text});
        };
        return .{ .ms = ms };
    }

    pub fn sigilStringify(
        self: *const Duration,
        context: *reflect.Context,
    ) reflect.StringifyError!Value {
        assert(self.ms <= std.math.maxInt(i64));
        assert(@intFromPtr(context) != 0);
        return .{ .int = @intCast(self.ms) };
    }
};
const Timed = struct { timeout: Duration };

/// A hook that parses its own value again, so it can only end in reflect's `TooDeep`.
const Loop = struct {
    x: u8,

    pub fn sigilParse(context: *reflect.Context, value: Value) reflect.ParseError!Loop {
        assert(context.depth <= core.value.nesting_max);
        return context.parse_child(Loop, .none, value);
    }

    pub fn sigilStringify(
        self: *const Loop,
        context: *reflect.Context,
    ) reflect.StringifyError!Value {
        assert(self.x <= 255);
        assert(@intFromPtr(context) != 0);
        return .null;
    }
};

const Position = struct { line: u32, col: u32 };

/// 1-based line and byte column of `offset` by a plain scan: the reference model.
fn model_position(text: []const u8, offset: u32) Position {
    assert(offset <= text.len);
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (text[0..offset], 0..) |byte, at| {
        if (byte != '\n') continue;
        line += 1;
        line_start = @intCast(at + 1);
    }
    return .{ .line = line, .col = offset - line_start + 1 };
}

/// The failing line around `offset` by a plain scan, checked against `diag`'s snippet.
fn expect_snippet(text: []const u8, offset: u32, diag: *const Diagnostics) !void {
    var line_start: u32 = 0;
    for (text[0..offset], 0..) |byte, at| {
        if (byte == '\n') line_start = @intCast(at + 1);
    }
    var line_end: u32 = offset;
    while (line_end < text.len and text[line_end] != '\n') line_end += 1;
    const want = text[@max(line_start, offset -| snippet_half)..line_end];
    const got = diag.snippet_text() orelse return error.TestExpectedSnippet;
    if (want.len <= snippet_len_max) return testing.expectEqualStrings(want, got);
    try testing.expectEqual(snippet_len_max, got.len);
    try testing.expectEqualStrings(want[0 .. snippet_len_max - 3], got[0 .. snippet_len_max - 3]);
    try testing.expect(std.mem.endsWith(u8, got, "..."));
}

/// Where a failure must be reported.
const Where = union(enum) {
    /// The first byte of the first occurrence of this text.
    at: []const u8,
    offset: u32,
    /// One past the last byte.
    end,
    /// `position_none`: the failure has no source position.
    none,
    /// Some diagnostics were written; the position is not part of the contract.
    any,
};

const Row = struct {
    err: json.ParseError,
    text: []const u8,
    where: Where,
    /// The exact message, when reflect's `"{path}: {reason}"` grammar fixes it.
    message: ?[]const u8 = null,
    /// The end of the message, when only the reason's fixed part is contract.
    tail: ?[]const u8 = null,
    options: json.ParseOptions = base_options,
    /// Fail the n-th allocation of the tree's backing allocator.
    fail_index: u32 = never,
    run: *const fn (Row) anyerror!void,
};

fn check_diag(row: Row, diag: *const Diagnostics) !void {
    try testing.expect(diag.message().len > 0);
    if (row.message) |want| try testing.expectEqualStrings(want, diag.message());
    if (row.tail) |tail| try testing.expect(std.mem.endsWith(u8, diag.message(), tail));
    const offset: u32 = switch (row.where) {
        .at => |needle| blk: {
            const found = std.mem.find(u8, row.text, needle) orelse return error.NeedleNotInText;
            break :blk @intCast(found);
        },
        .offset => |offset| offset,
        .end => @intCast(row.text.len),
        .none => {
            try testing.expectEqual(position_none, diag.line);
            return testing.expectEqual(position_none, diag.col);
        },
        .any => return testing.expect(diag.line != sentinel_line),
    };
    const want = model_position(row.text, offset);
    try testing.expectEqual(want.line, diag.line);
    try testing.expectEqual(want.col, diag.col);
    try expect_snippet(row.text, offset, diag);
}

const run_value = Probe(Value).run;

/// The runner of one row for target type `T`.
fn Probe(comptime T: type) type {
    return struct {
        fn run(row: Row) anyerror!void {
            var failing = testing.FailingAllocator.init(
                testing.allocator,
                .{ .fail_index = row.fail_index },
            );
            var tree: ValueTree = undefined;
            tree.init(failing.allocator());
            defer tree.deinit();

            var diag = fresh_diag();
            const result = json.parse(T, &tree, row.text, row.options, &diag);
            try testing.expectError(row.err, result);
            try check_diag(row, &diag);
        }
    };
}

fn expect_fail(
    comptime T: type,
    err: json.ParseError,
    text: []const u8,
    where: Where,
    message: ?[]const u8,
) !void {
    const row: Row = .{
        .err = err,
        .text = text,
        .where = where,
        .message = message,
        .run = Probe(T).run,
    };
    try row.run(row);
}

const fleet_text =
    \\{
    \\  "name": "f",
    \\  "servers": [
    \\    {"host": "a"},
    \\    {"host": "b", "port": 2},
    \\    {"host": 5}
    \\  ]
    \\}
;

const deep_arrays = ("[" ** 129) ++ ("]" ** 129);
const deep_message = "exceeds nesting depth limit 128";

/// One row per variant of `json.ParseError`; the first 15 are `ParseValueError`.
const rows = [_]Row{
    .{ .err = error.UnexpectedEnd, .text = "[1,", .where = .end, .run = run_value },
    .{ .err = error.UnexpectedToken, .text = "[1,]", .where = .{ .at = "]" }, .run = run_value },
    .{ .err = error.TrailingData, .text = "{} x", .where = .{ .at = "x" }, .run = run_value },
    .{ .err = error.InvalidNumber, .text = "[1, 01]", .where = .{ .at = "01" }, .run = run_value },
    .{
        .err = error.InvalidEscape,
        .text = "[\"a\\qb\"]",
        .where = .{ .at = "\\q" },
        .run = run_value,
    },
    .{
        .err = error.LoneSurrogate,
        .text = "[\"x\\ud800y\"]",
        .where = .{ .at = "\\ud800" },
        .run = run_value,
    },
    .{
        .err = error.ControlCharacter,
        .text = "[\"a\tb\"]",
        .where = .{ .at = "\t" },
        .run = run_value,
    },
    .{
        .err = error.InvalidUtf8,
        .text = "{\"k\": \"a\xffb\"}",
        .where = .{ .at = "\xff" },
        .run = run_value,
    },
    .{ .err = error.TooDeep, .text = deep_arrays, .where = .{ .offset = 128 }, .run = run_value },
    .{
        .err = error.InputTooLarge,
        .text = "[1,2,3]",
        .where = .none,
        .options = .{ .depth_max = 128, .bytes_max = 6, .duplicate_key = .reject },
        .run = run_value,
    },
    .{
        .err = error.IntegerAboveMax,
        .text = "[1, 18446744073709551616]",
        .where = .{ .at = "18446744073709551616" },
        .run = run_value,
    },
    .{
        .err = error.IntegerBelowMin,
        .text = "[0, -9223372036854775809]",
        .where = .{ .at = "-9223372036854775809" },
        .run = run_value,
    },
    .{
        .err = error.FloatOutOfRange,
        .text = "[1e400]",
        .where = .{ .at = "1e400" },
        .run = run_value,
    },
    .{
        .err = error.DuplicateKey,
        .text = "{\"a\": 1,\n \"a\": 2}",
        .where = .{ .at = "\"a\": 2" },
        .run = run_value,
    },
    .{
        .err = error.OutOfMemory,
        .text = "[1]",
        .where = .any,
        .fail_index = 0,
        .run = run_value,
    },
    // The 8 variants only reflect raises, then reflect's 3 shared names from the typed layer.
    .{
        .err = error.TypeMismatch,
        .text = fleet_text,
        .where = .{ .at = "5}" },
        .message = "servers[2].host: expected string, found int",
        .run = Probe(Fleet).run,
    },
    .{
        .err = error.IntegerOutOfRange,
        .text = "{\"host\": \"h\", \"port\": 70000}",
        .where = .{ .at = "70000" },
        .message = "port: 70000 is out of range for u16",
        .run = Probe(Server).run,
    },
    .{
        .err = error.InexactNumber,
        .text = "{\"ratio\": 9007199254740993}",
        .where = .{ .at = "9007199254740993" },
        .message = "ratio: 9007199254740993 is not exactly representable as f64",
        .run = Probe(Wide).run,
    },
    .{
        .err = error.FloatOutOfRange,
        .text = "{\"ratio\": 1e39}",
        .where = .{ .at = "1e39" },
        .tail = " is out of range for f32",
        .run = Probe(Narrow).run,
    },
    .{
        .err = error.UnknownEnumValue,
        .text = "{\"mode\": \"warp\"}",
        .where = .{ .at = "\"warp\"" },
        .tail = " \"warp\"",
        .run = Probe(Modal).run,
    },
    .{
        .err = error.MissingField,
        .text = "{\"port\": 1}",
        .where = .{ .at = "{" },
        .message = "missing field \"host\"",
        .run = Probe(Server).run,
    },
    .{
        .err = error.UnknownField,
        .text = "{\"name\": \"x\", \"bogus\": 1}",
        .where = .{ .at = "{" },
        .message = "unknown field \"bogus\"",
        .run = Probe(Strict).run,
    },
    .{
        .err = error.LengthMismatch,
        .text = "{\"grid\": [1, 2, 3]}",
        .where = .{ .at = "[1, 2, 3]" },
        .message = "grid: expected array of length 2, found 3",
        .run = Probe(Grid).run,
    },
    .{
        .err = error.InvalidValue,
        .text = "{\"timeout\": \"5x\"}",
        .where = .{ .at = "\"5x\"" },
        .message = "timeout: bad duration \"5x\"",
        .run = Probe(Timed).run,
    },
    .{
        .err = error.TooDeep,
        .text = " 7",
        .where = .{ .at = "7" },
        .tail = deep_message,
        .run = Probe(Loop).run,
    },
};

test "parse: ParseError is the 23 contract names and none of the stub names" {
    const names = @typeInfo(json.ParseError).error_set.?;
    try testing.expectEqual(@as(usize, 23), names.len);
    try testing.expectEqual(@as(usize, 15), @typeInfo(json.ParseValueError).error_set.?.len);
    // Each reflect name coerces into the merged set; the stub names are in no json set.
    inline for (@typeInfo(reflect.ParseError).error_set.?) |name| {
        const merged: json.ParseError = @field(reflect.ParseError, name.name);
        try testing.expectEqualStrings(name.name, @errorName(merged));
    }
    const stubs = [_][]const u8{
        "DepthExceeded",  "NumberOutOfRange", "ParseFailed", "UnsupportedType",
        "NotImplemented",
    };
    inline for (names) |name| {
        for (stubs) |stub| try testing.expect(!std.mem.eql(u8, name.name, stub));
    }
}

test "parse: every ParseError variant is provoked at its source position" {
    var covered = [_]bool{false} ** 64;
    for (rows) |row| {
        try row.run(row);
        inline for (@typeInfo(json.ParseError).error_set.?, 0..) |name, index| {
            if (row.err == @field(json.ParseError, name.name)) covered[index] = true;
        }
    }
    inline for (@typeInfo(json.ParseError).error_set.?, 0..) |name, index| {
        errdefer std.log.err("ParseError.{s} is never provoked", .{name.name});
        try testing.expect(covered[index]);
    }
}

test "parse: success leaves diag untouched for every shape of target" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const server = try parse_ok(Server, &tree, "{\"host\": \"h\"}", base_options);
    try testing.expectEqualStrings("h", server.host);
    try testing.expectEqual(@as(u16, 8080), server.port);
    const empty_fleet = "{\"name\":\"n\",\"servers\":[]}";
    const fleet = try parse_ok(Fleet, &tree, empty_fleet, base_options);
    try testing.expectEqual(@as(usize, 0), fleet.servers.len);
    try testing.expectEqual(@as(u8, 200), try parse_ok(u8, &tree, "200", base_options));
    const modal = try parse_ok(Modal, &tree, "{\"mode\":\"slow\"}", base_options);
    try testing.expectEqual(Mode.slow, modal.mode);
    const any = try parse_ok(Value, &tree, " [null, 1e2] ", base_options);
    try testing.expectEqual(@as(f64, 100), any.array[1].float);
    const timed = try parse_ok(Timed, &tree, "{\"timeout\": \"250ms\"}", base_options);
    try testing.expectEqual(@as(u64, 250), timed.timeout.ms);
}

test "parse: empty and whitespace-only input end at the end of the text" {
    try expect_fail(Value, error.UnexpectedEnd, "", .end, null);
    try expect_fail(Value, error.UnexpectedEnd, "  \n\t", .end, null);
    try expect_fail(Server, error.UnexpectedEnd, "{\"host\": 5", .end, null);
    // The end of text that ends in a newline is the next line's first column.
    try expect_fail(Value, error.UnexpectedEnd, "[1,\n", .end, null);
    const crlf = "[1,\r\n";
    try expect_fail(Value, error.UnexpectedEnd, crlf, .end, null);
}

test "parse: a byte order mark is UnexpectedToken at 1:1 and the message names it" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    const bom = "\xEF\xBB\xBF{}";
    const result = json.parse(Value, &tree, bom, base_options, &diag);
    try testing.expectError(error.UnexpectedToken, result);
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 1), diag.col);
    try testing.expect(std.mem.find(u8, diag.message(), "byte order mark") != null);
}

test "parse: a syntax error after a type mismatch is the syntax error" {
    // The DOM reads the whole document before reflect sees any of it.
    try expect_fail(Server, error.UnexpectedToken, "{\"host\": 5, ]", .{ .at = "]" }, null);
    try expect_fail(Server, error.TrailingData, "{\"host\": 5} {}", .{ .at = "{}" }, null);
    const bad_port = "{\"host\": 5, \"port\": 01}";
    try expect_fail(Server, error.InvalidNumber, bad_port, .{ .at = "01" }, null);
}

test "parse: bytes_max accepts the empty input and the maximum and refuses one byte more" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const text = "[1,2,3]";
    const exact: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = text.len,
        .duplicate_key = .reject,
    };
    const root = try parse_ok(Value, &tree, text, exact);
    try testing.expectEqual(@as(usize, 3), root.array.len);

    // Empty input under bytes_max 0 is within the limit: it is a syntax error, not too large.
    const zero: json.ParseOptions = .{ .depth_max = 4, .bytes_max = 0, .duplicate_key = .reject };
    var diag = fresh_diag();
    try testing.expectError(error.UnexpectedEnd, json.parse(Value, &tree, "", zero, &diag));
    try testing.expectEqual(@as(u32, 1), diag.line);

    // One byte more: InputTooLarge before any byte is read, so bad syntax does not win.
    const short: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = text.len - 1,
        .duplicate_key = .reject,
    };
    const junk = "[1,2,3 ??";
    const junk_options: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = junk.len - 1,
        .duplicate_key = .reject,
    };
    inline for (.{ .{ text, short }, .{ junk, junk_options } }) |case| {
        diag = fresh_diag();
        const result = json.parse(Value, &tree, case[0], case[1], &diag);
        try testing.expectError(error.InputTooLarge, result);
        try testing.expectEqual(position_none, diag.line);
        try testing.expectEqual(position_none, diag.col);
        try testing.expect(diag.message().len > 0);
        diag = fresh_diag();
        const raw = json.parse_value(&tree, case[0], case[1], &diag);
        try testing.expectError(error.InputTooLarge, raw);
        try testing.expectEqual(position_none, diag.line);
    }
    // At the maximum the junk is read, and it is the syntax error.
    const junk_exact: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = junk.len,
        .duplicate_key = .reject,
    };
    diag = fresh_diag();
    const parsed = json.parse(Value, &tree, junk, junk_exact, &diag);
    try testing.expectError(error.UnexpectedToken, parsed);
    try testing.expectEqual(@as(u32, 8), diag.col);
}

const deep_objects = ("{\"a\":" ** 129) ++ "1" ++ ("}" ** 129);

test "parse: depth_max is exact for arrays and objects and the next container is TooDeep" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const exact_arrays = ("[" ** 128) ++ ("]" ** 128);
    try testing.expect((try parse_ok(Value, &tree, exact_arrays, base_options)) == .array);
    try expect_fail(Value, error.TooDeep, deep_arrays, .{ .offset = 128 }, null);

    const exact_objects = ("{\"a\":" ** 128) ++ "1" ++ ("}" ** 128);
    try testing.expect((try parse_ok(Value, &tree, exact_objects, base_options)) == .map);
    try expect_fail(Value, error.TooDeep, deep_objects, .{ .offset = 128 * 5 }, null);

    const narrow: json.ParseOptions = .{
        .depth_max = 1,
        .bytes_max = 64,
        .duplicate_key = .reject,
    };
    _ = try parse_ok(Value, &tree, "[]", narrow);
    _ = try parse_ok(Value, &tree, "{\"a\": 1}", narrow);
    var diag = fresh_diag();
    try testing.expectError(error.TooDeep, json.parse(Value, &tree, "[[]]", narrow, &diag));
    try testing.expectEqual(@as(u32, 2), diag.col);
    diag = fresh_diag();
    try testing.expectError(error.TooDeep, json.parse(Value, &tree, "{\"a\": []}", narrow, &diag));
    try testing.expectEqual(@as(u32, 7), diag.col);
    // The scalar inside the deepest container costs no level.
    _ = try parse_ok(Value, &tree, "[[\"s\", 1, true, null]]", .{
        .depth_max = 2,
        .bytes_max = 64,
        .duplicate_key = .reject,
    });
}

test "parse: DuplicateKey under reject lands on the second key, under last it keeps the slot" {
    const text = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"a\": 3\n}";
    try expect_fail(Value, error.DuplicateKey, text, .{ .at = "\"a\": 3" }, null);
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const merged = try parse_ok(Value, &tree, text, last_options);
    const items = merged.map.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", items[0].key);
    try testing.expectEqual(@as(i64, 3), items[0].value.int);
    try testing.expectEqualStrings("b", items[1].key);
    try testing.expectEqual(@as(i64, 2), items[1].value.int);

    // Keys are compared decoded: `\u0061` is `a`.
    const escaped = "{\"a\":1,\"\\u0061\":2}";
    try expect_fail(Value, error.DuplicateKey, escaped, .{ .at = "\"\\u0061\"" }, null);
    const escaped_last = try parse_ok(Value, &tree, escaped, last_options);
    try testing.expectEqual(@as(u32, 1), escaped_last.map.count);
    try testing.expectEqual(@as(i64, 2), escaped_last.map.get("a").?.int);

    // The policy reaches typed targets, and the repeat is not an error under `last`.
    const server_text = "{\"host\": \"x\", \"host\": \"y\"}";
    try expect_fail(Server, error.DuplicateKey, server_text, .{ .at = "\"host\": \"y\"" }, null);
    const server = try parse_ok(Server, &tree, server_text, last_options);
    try testing.expectEqualStrings("y", server.host);

    // Equal keys in different objects are not duplicates.
    const sibling_text = "[{\"a\":1},{\"a\":2},{\"a\":{\"a\":3}}]";
    const siblings = try parse_ok(Value, &tree, sibling_text, base_options);
    try testing.expectEqual(@as(usize, 3), siblings.array.len);
}

test "parse: UnknownField and MissingField land on the opening brace of their object" {
    const server_message = "server: unknown field \"bogus\"";
    const nested = "{\"server\": {\"host\": \"h\", \"bogus\": 1}}";
    try expect_fail(Wrapper, error.UnknownField, nested, .{ .at = "{\"host\"" }, server_message);
    const crlf = "{\r\n  \"name\": \"x\",\r\n  \"colour\": 1\r\n}";
    try expect_fail(Strict, error.UnknownField, crlf, .{ .at = "{" }, "unknown field \"colour\"");
    // Unknown keys are judged before missing ones, so the unknown key is the error.
    const both = "\n\n   {\"colour\": 1}";
    try expect_fail(Strict, error.UnknownField, both, .{ .at = "{" }, "unknown field \"colour\"");

    const missing = "{\"name\": \"f\",\n \"servers\": [{\"host\": \"a\"},\n  {\"port\": 2}]}";
    const missing_message = "servers[1]: missing field \"host\"";
    try expect_fail(Fleet, error.MissingField, missing, .{ .at = "{\"port\"" }, missing_message);
    try expect_fail(Strict, error.MissingField, "  \n{}", .{ .at = "{" }, "missing field \"name\"");
    // An array is not an object: that is a mismatch at the `[`, not a missing field.
    const array = "[{\"port\": 1}]";
    try expect_fail(Server, error.TypeMismatch, array, .{ .at = "[" }, "expected map, found array");
}

test "parse: a TypeMismatch at servers[2].host reports line 6 column 14 and its line" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    const result = json.parse(Fleet, &tree, fleet_text, base_options, &diag);
    try testing.expectError(error.TypeMismatch, result);
    try testing.expectEqual(@as(u32, 6), diag.line);
    try testing.expectEqual(@as(u32, 14), diag.col);
    try testing.expectEqualStrings("servers[2].host: expected string, found int", diag.message());
    try testing.expectEqualStrings("    {\"host\": 5}", diag.snippet_text().?);

    // The same document with the bad host fixed parses, and the same tree is reusable.
    const host_5 = "\"host\": 5";
    const host_c = "\"host\": \"c\"";
    const fixed = try std.mem.replaceOwned(u8, testing.allocator, fleet_text, host_5, host_c);
    defer testing.allocator.free(fixed);
    const fleet = try parse_ok(Fleet, &tree, fixed, base_options);
    try testing.expectEqual(@as(usize, 3), fleet.servers.len);
    try testing.expectEqual(@as(u16, 2), fleet.servers[1].port);
    try testing.expectEqualStrings("c", fleet.servers[2].host);
}

test "parse: a long line keeps a snippet window around the failing byte" {
    const filler = "1, " ** 40;
    const text = "[" ++ filler ++ "01, " ++ filler ++ "2]";
    try expect_fail(Value, error.InvalidNumber, text, .{ .at = "01" }, null);
}

test "parse: every allocation failing in turn is OutOfMemory, written, leak free" {
    const text =
        \\{"name": "fleet\u0021", "servers": [{"host": "a", "port": 1}, {"host": "b"}]}
    ;
    for (0..512) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        var tree: ValueTree = undefined;
        tree.init(failing.allocator());
        defer tree.deinit();

        var diag = fresh_diag();
        const result = json.parse(Fleet, &tree, text, base_options, &diag);
        if (result) |fleet| {
            // The first allocation is the DOM's counting array, so index 0 cannot get here.
            try testing.expect(index > 0);
            try expect_untouched(&diag);
            try testing.expectEqualStrings("fleet!", fleet.name);
            try testing.expectEqual(@as(usize, 2), fleet.servers.len);
            try testing.expectEqual(@as(u16, 8080), fleet.servers[1].port);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(diag.line != sentinel_line);
            try testing.expect(diag.message().len > 0);
        }
    }
    return error.NeverSucceeded;
}

// ---------------------------------------------------------------------------------------------
// Fuzz (std.testing.fuzz, Zig 0.16): the seed corpus runs in `zig build test`; under
// `zig build test --fuzz` the same target is mutated coverage-guided. Invariant: arbitrary bytes
// either parse and leave `diag` untouched, or fail with a message and a position that exists in
// the text (or `position_none`); and anything accepted is accepted by `std.json` too.
// ---------------------------------------------------------------------------------------------

/// All 256 bytes stay reachable (baseline); JSON structure is boosted.
const fuzz_structural = "{}[]\",:\\-+.0123456789eEtrufalsn \n";
const fuzz_boosts = blk: {
    const Weight = std.testing.Smith.Weight;
    var out: [fuzz_structural.len]Weight = undefined;
    for (fuzz_structural, &out) |byte, *weight| weight.* = Weight.rangeAtMost(u8, byte, byte, 12);
    break :blk out;
};
const fuzz_byte_weights = std.testing.Smith.baselineWeights(u8) ++ fuzz_boosts;

fn fuzz_check(comptime T: type, text: []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    if (json.parse(T, &tree, text, base_options, &diag)) |_| {
        try expect_untouched(&diag);
        if (T == Value) try testing.expect(try std.json.validate(testing.allocator, text));
        return;
    } else |_| {}
    try testing.expect(diag.message().len > 0);
    if (diag.line == position_none) return testing.expectEqual(position_none, diag.col);
    const lines: u32 = @intCast(1 + std.mem.count(u8, text, "\n"));
    try testing.expect(diag.line >= 1 and diag.line <= lines);
    try testing.expect(diag.col >= 1 and diag.col <= text.len + 1);
    try testing.expect(diag.snippet_text() != null);
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [64]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, fuzz_byte_weights);
    // An exact-size heap copy: reads past the end are caught, and nothing leaks.
    const copy = try testing.allocator.dupe(u8, buffer[0..len]);
    defer testing.allocator.free(copy);
    try fuzz_check(Value, copy);
    try fuzz_check(Fleet, copy);
}

/// One corpus entry in Smith's `slice` wire format: u32 little-endian length, then the bytes.
fn seed(comptime bytes: []const u8) [4 + bytes.len]u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes[0..bytes.len].*;
}

const fuzz_corpus = [_][]const u8{
    &seed(""),
    &seed("{\"name\":\"a\",\"servers\":[{\"host\":\"h\"}]}"),
    &seed("{\"name\":\"a\",\"servers\":[{\"host\":5}]}"),
    &seed("[1,2.5e3,-0,true,false,null,\"x\\n\\u00e9\"]"),
    &seed("{\"a\":1,\"a\":2}"),
    &seed("[[[[[[[[[[]]]]]]]]]]"),
    &seed("\"\\ud800\""),
    &seed("[01]"),
    &seed("\xEF\xBB\xBF{}"),
    &seed("{\"k\":\"\xff\"}"),
    &seed("[1e400, 18446744073709551616]"),
};

test "parse: fuzz arbitrary bytes keep the diagnostics contract" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &fuzz_corpus });
}

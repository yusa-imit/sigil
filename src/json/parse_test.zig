//! Tests for `json.parse(T, ...)` (plan 004 item 8, ADR 0003 sections 3 and 8): JSON text into a
//! Zig type through the DOM and `reflect.parse`, the PRD section 4.2 `Config`, and the upgrade
//! of reflect's path-only diagnostics to the source `line:col` while the message is kept.
//! Expected positions come from a plain scan of the test text (a trivial reference model), not
//! from `core.diagnostics`. Every error variant is in `parse_error_test.zig`.

const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json.zig");
const assert = std.debug.assert;
const testing = std.testing;

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;

const sentinel_line: u32 = 777;
const options: json.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const options_last: json.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .last,
};

pub fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 5, "untouched", null);
}

/// The PRD section 4.2 example, verbatim.
pub const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    tags: []const []const u8 = &.{},
    tls: ?struct { cert: []const u8, key: []const u8 } = null,

    pub const sigil_options = .{
        .rename = .{ .name = "server_name" },
        .rename_all = .snake_case,
        .deny_unknown_fields = true,
    };
};

const Server = struct { host: []const u8, port: u16 = 8080 };
const Fleet = struct { name: []const u8, servers: []const Server };
const Wrapper = struct { server: Server };

/// Parses `text` as `T`; asserts success left `diag` untouched.
fn parse_ok(comptime T: type, tree: *ValueTree, text: []const u8) !T {
    var diag = fresh_diag();
    const got = try json.parse(T, tree, text, options, &diag);
    try testing.expectEqual(sentinel_line, diag.line);
    try testing.expectEqual(@as(u32, 5), diag.col);
    try testing.expectEqualStrings("untouched", diag.message());
    return got;
}

const Position = struct { line: u32, col: u32 };

/// 1-based line and byte column of `offset` by a plain scan: the reference model.
fn model_position(text: []const u8, offset: usize) Position {
    assert(offset <= text.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (text[0..offset], 0..) |byte, at| {
        if (byte != '\n') continue;
        line += 1;
        line_start = at + 1;
    }
    return .{ .line = line, .col = @intCast(offset - line_start + 1) };
}

/// The offset of the unique `needle` in `text`.
fn offset_of(text: []const u8, needle: []const u8) usize {
    // proof: every caller passes a needle that occurs in its own literal text.
    const first = std.mem.find(u8, text, needle) orelse unreachable;
    assert(std.mem.findLast(u8, text, needle).? == first);
    return first;
}

/// Parses `text` as `T`, expects `err`, the position of the first byte of `needle`, and
/// exactly `message`. Returns the diagnostics for further checks.
fn expect_fail(
    comptime T: type,
    text: []const u8,
    err: json.ParseError,
    needle: []const u8,
    message: []const u8,
) !Diagnostics {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    try testing.expectError(err, json.parse(T, &tree, text, options, &diag));
    const want = model_position(text, offset_of(text, needle));
    try testing.expectEqual(want.line, diag.line);
    try testing.expectEqual(want.col, diag.col);
    try testing.expectEqualStrings(message, diag.message());
    try testing.expect(diag.snippet_text() != null);
    return diag;
}

test "parse: the PRD Config from JSON text, every field present" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const text =
        \\{
        \\  "server_name": "edge",
        \\  "port": 9090,
        \\  "tags": ["a", "b"],
        \\  "tls": {"cert": "c.pem", "key": "k.pem"}
        \\}
    ;
    const cfg = try parse_ok(Config, &tree, text);
    try testing.expectEqualStrings("edge", cfg.name);
    try testing.expectEqual(@as(u16, 9090), cfg.port);
    try testing.expectEqual(@as(usize, 2), cfg.tags.len);
    try testing.expectEqualStrings("a", cfg.tags[0]);
    try testing.expectEqualStrings("b", cfg.tags[1]);
    try testing.expectEqualStrings("c.pem", cfg.tls.?.cert);
    try testing.expectEqualStrings("k.pem", cfg.tls.?.key);
}

test "parse: Config defaults apply to omitted fields and an explicit null stays null" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();

    const bare = try parse_ok(Config, &tree, "{\"server_name\": \"x\"}");
    try testing.expectEqualStrings("x", bare.name);
    try testing.expectEqual(@as(u16, 8080), bare.port);
    try testing.expectEqual(@as(usize, 0), bare.tags.len);
    try testing.expect(bare.tls == null);

    const explicit = try parse_ok(Config, &tree, "{\"server_name\":\"y\",\"tls\":null}");
    try testing.expect(explicit.tls == null);
    const empty_tags = try parse_ok(Config, &tree, "{\"server_name\":\"z\",\"tags\":[]}");
    try testing.expectEqual(@as(usize, 0), empty_tags.tags.len);
}

test "parse: the renamed field only answers to its wire name and unknown keys are refused" {
    // `name` is the Zig name; the wire name is `server_name`. The unknown key is reported
    // before the missing field, as in reflect, and lands on the object's `{`.
    const old = "{\"name\": \"x\"}";
    const diag = try expect_fail(Config, old, error.UnknownField, "{", "unknown field \"name\"");
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 1), diag.col);

    const absent = "{\"port\": 1}";
    _ = try expect_fail(Config, absent, error.MissingField, "{", "missing field \"server_name\"");
    const extra = "{\"server_name\": \"x\", \"colour\": 1}";
    _ = try expect_fail(Config, extra, error.UnknownField, "{", "unknown field \"colour\"");
}

test "parse: a TypeMismatch at servers[2].host reports the source line and column" {
    const text =
        \\{
        \\  "name": "fleet",
        \\  "servers": [
        \\    {"host": "a", "port": 1},
        \\    {"host": "b"},
        \\    {"host": 5}
        \\  ]
        \\}
    ;
    const message = "servers[2].host: expected string, found int";
    const diag = try expect_fail(Fleet, text, error.TypeMismatch, "5}", message);
    try testing.expectEqual(@as(u32, 6), diag.line);
    try testing.expectEqual(@as(u32, 14), diag.col);
    try testing.expectEqualStrings("    {\"host\": 5}", diag.snippet_text().?);
}

test "parse: an UnknownField reports the line and column of the object that holds it" {
    const text =
        \\{
        \\  "server": {
        \\    "host": "h",
        \\    "bogus": 1
        \\  }
        \\}
    ;
    const message = "server: unknown field \"bogus\"";
    const diag = try expect_fail(Wrapper, text, error.UnknownField, "{\n    \"host\"", message);
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expectEqual(@as(u32, 13), diag.col);
    try testing.expectEqualStrings("  \"server\": {", diag.snippet_text().?);
}

test "parse: a MissingField lands on the opening brace of its object" {
    const text =
        \\{"name": "f",
        \\ "servers": [{"host": "a"},
        \\              {"port": 2}]}
    ;
    const message = "servers[1]: missing field \"host\"";
    const diag = try expect_fail(Fleet, text, error.MissingField, "{\"port\"", message);
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expectEqual(@as(u32, 15), diag.col);

    const root = "  \n{\"servers\": []}";
    const root_message = "missing field \"name\"";
    const root_diag = try expect_fail(Fleet, root, error.MissingField, "{", root_message);
    try testing.expectEqual(@as(u32, 2), root_diag.line);
    try testing.expectEqual(@as(u32, 1), root_diag.col);
}

test "parse: a mismatch inside a nested array lands on the element" {
    const Row = struct { text: []const u8, needle: []const u8, message: []const u8 };
    const rows = [_]Row{
        .{
            .text = "[[1, 2], [3, \"x\"]]",
            .needle = "\"x\"",
            .message = "[1][1]: expected integer, found string",
        },
        .{
            .text = "[[1, 2],[3,4.5]]",
            .needle = "4.5",
            .message = "[1][1]: expected integer, found float",
        },
        .{
            .text = "[[], [true]]",
            .needle = "true",
            .message = "[1][0]: expected integer, found bool",
        },
        .{
            .text = "[[1], null]",
            .needle = "null",
            .message = "[1]: expected array, found null",
        },
    };
    for (rows) |row| {
        const T = []const []const i32;
        _ = try expect_fail(T, row.text, error.TypeMismatch, row.needle, row.message);
    }
}

test "parse: with the last-wins policy a mismatch lands on the last occurrence of a key" {
    const text =
        \\{
        \\  "host": "a",
        \\  "host": 5
        \\}
    ;
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    const result = json.parse(Server, &tree, text, options_last, &diag);
    try testing.expectError(error.TypeMismatch, result);
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expectEqual(@as(u32, 11), diag.col);
    try testing.expectEqualStrings("host: expected string, found int", diag.message());

    // The first occurrence is the bad one and the last is fine: the parse succeeds with it.
    const fixed = "{\"host\": 5, \"host\": \"ok\", \"port\": 1, \"port\": 2}";
    diag = fresh_diag();
    const got = try json.parse(Server, &tree, fixed, options_last, &diag);
    try testing.expectEqualStrings("ok", got.host);
    try testing.expectEqual(@as(u16, 2), got.port);
    try testing.expectEqual(sentinel_line, diag.line);
}

test "parse: with the reject policy a repeated key is a DuplicateKey at the second quote" {
    const text = "{\n  \"host\": \"a\",\n  \"host\": \"b\"\n}";
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    try testing.expectError(error.DuplicateKey, json.parse(Server, &tree, text, options, &diag));
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expectEqual(@as(u32, 3), diag.col);
}

test "parse: an escaped key is matched by its decoded bytes and located on its value" {
    const text = "{\"h\\u006fst\": 5}";
    const message = "host: expected string, found int";
    const diag = try expect_fail(Server, text, error.TypeMismatch, "5}", message);
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 15), diag.col);

    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const spelled = try parse_ok(Server, &tree, "{\"\\u0068ost\": \"h\", \"p\\u006frt\": 3}");
    try testing.expectEqualStrings("h", spelled.host);
    try testing.expectEqual(@as(u16, 3), spelled.port);

    const Strings = std.array_hash_map.String(u8);
    const quoted = "{\"a\\\"b\": \"x\"}";
    const quoted_message = "[\"a\\\"b\"]: expected integer, found string";
    const qdiag = try expect_fail(Strings, quoted, error.TypeMismatch, "\"x\"", quoted_message);
    try testing.expectEqual(@as(u32, 10), qdiag.col);
}

test "parse: columns count bytes and a CRLF counts as one line break" {
    // The 2-byte `\u{e9}` shifts the next column by two: bytes, not codepoints.
    const text = "[\"\u{e9}\", 5]";
    const message = "[1]: expected string, found int";
    const diag = try expect_fail([2][]const u8, text, error.TypeMismatch, "5]", message);
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 8), diag.col);

    const crlf = "{\r\n  \"host\": 5\r\n}";
    const host_message = "host: expected string, found int";
    const crlf_diag = try expect_fail(Server, crlf, error.TypeMismatch, "5\r", host_message);
    try testing.expectEqual(@as(u32, 2), crlf_diag.line);
    try testing.expectEqual(@as(u32, 11), crlf_diag.col);
}

test "parse: source errors keep the position the DOM gave and are never reflected" {
    // Unterminated, so UnexpectedEnd wins over the TypeMismatch the complete text would give.
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    var diag = fresh_diag();
    const text = "{\"host\": 5";
    try testing.expectError(error.UnexpectedEnd, json.parse(Server, &tree, text, options, &diag));
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 11), diag.col);
    try testing.expect(diag.snippet_text() != null);
}

test "parse: the supported shapes of reflect round-trip through text" {
    const Shape = union(enum) { none, circle: f64, rect: struct { w: u32, h: u32 } };
    const Mode = enum { fast, slow };
    const Mixed = struct {
        shapes: []const Shape,
        mode: Mode,
        scores: std.array_hash_map.String(i8),
        grid: [2]u8,
        maybe: ?i32,
        big: u64,
        low: i64,
        ratio: f64,
    };
    const text =
        \\{"shapes":["none",{"circle":2.5},{"rect":{"w":3,"h":4}}],"mode":"slow",
        \\ "scores":{"b":-1,"a":2},"grid":[7,8],"maybe":null,
        \\ "big":18446744073709551615,"low":-9223372036854775808,"ratio":-0.0}
    ;
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const got = try parse_ok(Mixed, &tree, text);
    try testing.expectEqual(@as(usize, 3), got.shapes.len);
    try testing.expect(got.shapes[0] == .none);
    try testing.expectEqual(@as(f64, 2.5), got.shapes[1].circle);
    try testing.expectEqual(@as(u32, 4), got.shapes[2].rect.h);
    try testing.expectEqual(Mode.slow, got.mode);
    try testing.expectEqualStrings("b", got.scores.keys()[0]);
    try testing.expectEqual(@as(i8, 2), got.scores.get("a").?);
    try testing.expectEqual([2]u8{ 7, 8 }, got.grid);
    try testing.expect(got.maybe == null);
    try testing.expectEqual(std.math.maxInt(u64), got.big);
    try testing.expectEqual(std.math.minInt(i64), got.low);
    try testing.expect(std.math.signbit(got.ratio));
    try testing.expectEqual(@as(f64, 0), got.ratio);
}

test "parse: scalar roots and core.Value targets" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(@as(u8, 200), try parse_ok(u8, &tree, "200"));
    try testing.expect(try parse_ok(bool, &tree, " true\n"));
    try testing.expectEqualStrings("hi\n", try parse_ok([]const u8, &tree, "\"hi\\n\""));
    try testing.expect((try parse_ok(?u8, &tree, "null")) == null);
    const any = try parse_ok(Value, &tree, "{\"a\": [1, 2.5]}");
    try testing.expectEqual(@as(i64, 1), any.map.get("a").?.array[0].int);
    try testing.expectEqual(@as(f64, 2.5), any.map.get("a").?.array[1].float);
}

test "parse: the result does not borrow from the input and the tree stays unrooted" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const input = try testing.allocator.dupe(u8, "{\"host\": \"example.org\"}");
    const got = try parse_ok(Server, &tree, input);
    const start = @intFromPtr(input.ptr);
    const text = @intFromPtr(got.host.ptr);
    try testing.expect(text < start or text >= start + input.len);
    @memset(input, 'x');
    testing.allocator.free(input);
    try testing.expectEqualStrings("example.org", got.host);
    try testing.expect(tree.root == .null);

    // One tree holds several documents at once.
    const second = try parse_ok(Server, &tree, "{\"host\": \"two\"}");
    try testing.expectEqualStrings("example.org", got.host);
    try testing.expectEqualStrings("two", second.host);
}

test "parse: depth_max is exact for the text and the 129th container is TooDeep" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const deep = ("[" ** 128) ++ ("]" ** 128);
    const root = try parse_ok(Value, &tree, deep);
    try testing.expect(root == .array);

    var diag = fresh_diag();
    const over = ("[" ** 129) ++ ("]" ** 129);
    try testing.expectError(error.TooDeep, json.parse(Value, &tree, over, options, &diag));
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 129), diag.col);

    const narrow: json.ParseOptions = .{
        .depth_max = 2,
        .bytes_max = 64,
        .duplicate_key = .reject,
    };
    diag = fresh_diag();
    _ = try json.parse(Value, &tree, "[[1]]", narrow, &diag);
    try testing.expectEqual(sentinel_line, diag.line);
    try testing.expectError(error.TooDeep, json.parse(Value, &tree, "[[[1]]]", narrow, &diag));
    try testing.expectEqual(@as(u32, 3), diag.col);
}

test "parse_value: returns the DOM root without storing it and honors bytes_max" {
    var tree: ValueTree = undefined;
    tree.init(testing.allocator);
    defer tree.deinit();
    const text = "[1,2,3]";
    var diag = fresh_diag();
    const exact: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = text.len,
        .duplicate_key = .reject,
    };
    const root = try json.parse_value(&tree, text, exact, &diag);
    try testing.expectEqual(@as(usize, 3), root.array.len);
    try testing.expect(tree.root == .null);
    try testing.expectEqual(sentinel_line, diag.line);

    const short: json.ParseOptions = .{
        .depth_max = 4,
        .bytes_max = text.len - 1,
        .duplicate_key = .reject,
    };
    try testing.expectError(error.InputTooLarge, json.parse_value(&tree, text, short, &diag));
    try testing.expectEqual(core.diagnostics.position_none, diag.line);
    try testing.expectEqual(core.diagnostics.position_none, diag.col);
    try testing.expect(diag.message().len > 0);
}

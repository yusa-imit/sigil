//! Tests for `path/pointer.zig` (plan 005 item 2): every RFC 6901 section 5 example, the
//! parse and index error cases with their diagnostic columns, the `segments_max` boundary,
//! and a seeded model against a naive splitter.

const std = @import("std");
const core = @import("../core.zig");
const pointer = @import("pointer.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Segment = pointer.Segment;

const sentinel_line: u32 = 777;

fn fresh_diag() Diagnostics {
    return Diagnostics.init(sentinel_line, 0, "untouched", null);
}

/// Parses `text`, asserting success left `diag` untouched.
fn parse_ok(text: []const u8, buffer: []Segment) !pointer.Pointer {
    var diag = fresh_diag();
    const parsed = try pointer.parse(text, buffer, &diag);
    try expectEqual(sentinel_line, diag.line);
    try expectEqualStrings(text, parsed.text);
    return parsed;
}

fn expect_parse_fail(text: []const u8, err: pointer.ParseError, col: u32) !void {
    var buffer: [pointer.segments_max]Segment = undefined;
    var diag = fresh_diag();
    try std.testing.expectError(err, pointer.parse(text, &buffer, &diag));
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(col, diag.col);
    try expect(diag.message().len > 0);
}

/// The document of RFC 6901 section 5.
fn rfc_document(tree: *ValueTree) !Value {
    const foo = try tree.dupe_array(&.{ .{ .string = "bar" }, .{ .string = "baz" } });
    var map = try tree.new_map(10);
    try map.put("foo", foo);
    try map.put("", .{ .int = 0 });
    try map.put("a/b", .{ .int = 1 });
    try map.put("c%d", .{ .int = 2 });
    try map.put("e^f", .{ .int = 3 });
    try map.put("g|h", .{ .int = 4 });
    try map.put("i\\j", .{ .int = 5 });
    try map.put("k\"l", .{ .int = 6 });
    try map.put(" ", .{ .int = 7 });
    try map.put("m~n", .{ .int = 8 });
    return .{ .map = map };
}

fn expect_resolves_to(root: *const Value, text: []const u8, expected: Value) !void {
    var buffer: [pointer.segments_max]Segment = undefined;
    const parsed = try parse_ok(text, &buffer);
    const found = pointer.resolve(root, parsed) orelse return error.TestUnexpectedResult;
    try expect(try core.value.eql(found.*, expected));
}

fn expect_absent(root: *const Value, text: []const u8) !void {
    var buffer: [pointer.segments_max]Segment = undefined;
    const parsed = try parse_ok(text, &buffer);
    try expect(pointer.resolve(root, parsed) == null);
}

test "pointer: every RFC 6901 section 5 example resolves to the RFC's value" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    tree.root = try rfc_document(&tree);
    const root = &tree.root;
    const foo = root.map.get("foo").?.*;

    try expect_resolves_to(root, "", root.*);
    try expect_resolves_to(root, "/foo", foo);
    try expect_resolves_to(root, "/foo/0", .{ .string = "bar" });
    try expect_resolves_to(root, "/", .{ .int = 0 });
    try expect_resolves_to(root, "/a~1b", .{ .int = 1 });
    try expect_resolves_to(root, "/c%d", .{ .int = 2 });
    try expect_resolves_to(root, "/e^f", .{ .int = 3 });
    try expect_resolves_to(root, "/g|h", .{ .int = 4 });
    try expect_resolves_to(root, "/i\\j", .{ .int = 5 });
    try expect_resolves_to(root, "/k\"l", .{ .int = 6 });
    try expect_resolves_to(root, "/ ", .{ .int = 7 });
    try expect_resolves_to(root, "/m~0n", .{ .int = 8 });
}

test "pointer: resolve is null for every way a pointer can name nothing" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    tree.root = try rfc_document(&tree);
    const root = &tree.root;

    try expect_absent(root, "/missing");
    try expect_absent(root, "/foo/2"); // One past the end.
    try expect_absent(root, "/foo/-"); // The end marker names no node.
    try expect_absent(root, "/foo/00"); // Leading zeros.
    try expect_absent(root, "/foo/01");
    try expect_absent(root, "/foo/+1"); // Sign.
    try expect_absent(root, "/foo/-1");
    try expect_absent(root, "/foo/4294967296"); // Wider than u32.
    try expect_absent(root, "/foo/99999999999999999999");
    try expect_absent(root, "/foo/"); // Empty segment is not an index.
    try expect_absent(root, "/foo/bar");
    try expect_absent(root, "/a~1b/x"); // A segment applied to a scalar.
    try expect_absent(root, "/foo/0/x"); // A segment applied to a string.
    try expect_absent(root, "//"); // The empty key holds an int.
    try expect_absent(root, "/a/b"); // `a/b` is one key; `a` is absent.
}

test "pointer: resolve finds array elements, nested containers and null values" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var inner = try tree.new_map(1);
    try inner.put("k", .null);
    const list = try tree.dupe_array(&.{ .{ .int = 10 }, .{ .map = inner }, .{ .uint = 12 } });
    tree.root = list;
    const root = &tree.root;

    try expect_resolves_to(root, "/0", .{ .int = 10 });
    try expect_resolves_to(root, "/2", .{ .uint = 12 });
    try expect_resolves_to(root, "/1/k", .null); // A present null is a node, not absence.
    try expect_absent(root, "/3");

    var buffer: [pointer.segments_max]Segment = undefined;
    const parsed = try parse_ok("/2", &buffer);
    const found = pointer.resolve(root, parsed).?;
    try expect(found == &root.array[2]); // A borrowed view into the tree, not a copy.
}

test "pointer: parse splits segments and keeps escapes undecoded" {
    var buffer: [pointer.segments_max]Segment = undefined;

    const root = try parse_ok("", &buffer);
    try expectEqual(@as(usize, 0), root.segments.len);

    const one = try parse_ok("/", &buffer);
    try expectEqual(@as(usize, 1), one.segments.len);
    try expectEqualStrings("", one.segments[0].raw);

    const three = try parse_ok("/a~1b//m~0n", &buffer);
    try expectEqual(@as(usize, 3), three.segments.len);
    try expectEqualStrings("a~1b", three.segments[0].raw);
    try expectEqualStrings("", three.segments[1].raw);
    try expectEqualStrings("m~0n", three.segments[2].raw);
}

test "pointer: parse rejects bad text with a byte column" {
    try expect_parse_fail("foo", error.InvalidPointer, 1);
    try expect_parse_fail("~0", error.InvalidPointer, 1);
    try expect_parse_fail("#/foo", error.InvalidPointer, 1);
    try expect_parse_fail("/a~", error.InvalidPointer, 3);
    try expect_parse_fail("/a~2", error.InvalidPointer, 3);
    try expect_parse_fail("/ab/c~x/d", error.InvalidPointer, 6);
    try expect_parse_fail("/~~0", error.InvalidPointer, 2);
    try expect_parse_fail("/\xc3\xa9~", error.InvalidPointer, 4); // Columns count bytes.
}

test "pointer: segments_max is accepted and one more is TooDeep at its slash" {
    var text: [pointer.segments_max * 2 + 2]u8 = undefined;
    for (0..pointer.segments_max + 1) |index| {
        text[index * 2] = '/';
        text[index * 2 + 1] = 'a';
    }

    var buffer: [pointer.segments_max]Segment = undefined;
    const at_max = try parse_ok(text[0 .. pointer.segments_max * 2], &buffer);
    try expectEqual(pointer.segments_max, @as(u32, @intCast(at_max.segments.len)));

    // The 129th segment opens at byte offset 256, column 257.
    try expect_parse_fail(text[0 .. pointer.segments_max * 2 + 2], error.TooDeep, 257);

    // An empty 129th segment (`...//`) is caught at the same slash.
    text[pointer.segments_max * 2 + 1] = '/';
    try expect_parse_fail(text[0 .. pointer.segments_max * 2 + 1], error.TooDeep, 257);
}

test "pointer: format writes the parsed text back, and an empty pointer as empty" {
    const texts = [_][]const u8{ "", "/", "//", "/foo/0", "/a~1b/m~0n", "/ /k\"l/~01" };
    for (texts) |text| {
        var buffer: [pointer.segments_max]Segment = undefined;
        const parsed = try parse_ok(text, &buffer);
        var out: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        try pointer.format(parsed, &w);
        try expectEqualStrings(text, w.buffered());
    }
}

test "pointer: format reports a full writer as WriteFailed" {
    var buffer: [pointer.segments_max]Segment = undefined;
    const parsed = try parse_ok("/abc/def", &buffer);
    var out: [3]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try std.testing.expectError(error.WriteFailed, pointer.format(parsed, &w));
}

test "pointer: index_of follows the RFC grammar" {
    try expectEqual(@as(?u32, 0), pointer.index_of("0"));
    try expectEqual(@as(?u32, 7), pointer.index_of("7"));
    try expectEqual(@as(?u32, 10), pointer.index_of("10"));
    try expectEqual(@as(?u32, 4294967295), pointer.index_of("4294967295"));
    try expectEqual(@as(?u32, null), pointer.index_of("4294967296"));
    try expectEqual(@as(?u32, null), pointer.index_of("00"));
    try expectEqual(@as(?u32, null), pointer.index_of("-"));
    try expectEqual(@as(?u32, null), pointer.index_of(""));
    try expectEqual(@as(?u32, null), pointer.index_of("1e3"));
    try expectEqual(@as(?u32, null), pointer.index_of("0x1"));
    try expectEqual(@as(?u32, null), pointer.index_of("12345678901"));
}

test "pointer: segment_eql decodes on the fly and rejects prefixes" {
    try expect(pointer.segment_eql("", ""));
    try expect(pointer.segment_eql("a~1b", "a/b"));
    try expect(pointer.segment_eql("m~0n", "m~n"));
    try expect(pointer.segment_eql("~01", "~1")); // `~01` is `~` then `1`, not `/`.
    try expect(!pointer.segment_eql("a", "ab"));
    try expect(!pointer.segment_eql("ab", "a"));
    try expect(!pointer.segment_eql("~1", "~1"));
    try expect(!pointer.segment_eql("", "a"));
}

const alphabet = "a~/01";

/// Writes `key` escaped (`~` first, then `/`) to `out`, returning the filled prefix.
fn escape_key(key: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    for (key) |byte| {
        switch (byte) {
            '~' => {
                out[len..][0..2].* = "~0".*;
                len += 2;
            },
            '/' => {
                out[len..][0..2].* = "~1".*;
                len += 2;
            },
            else => {
                out[len] = byte;
                len += 1;
            },
        }
    }
    return out[0..len];
}

/// The naive reference: RFC 6901 section 4 decoding, `~1` then `~0`, into `out`.
fn naive_decode(raw: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '~') {
            index += 1;
            out[len] = if (raw[index] == '1') '/' else '~';
        } else {
            out[len] = raw[index];
        }
        len += 1;
    }
    return out[0..len];
}

test "pointer: model against a naive splitter over 1,000 seeds" {
    const depth_max = 6;
    const key_len_max = 4;
    var tally_present: u32 = 0;

    for (0..1000) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var tree: ValueTree = undefined;
        tree.init(std.testing.allocator);
        defer tree.deinit();

        var keys: [depth_max][key_len_max]u8 = undefined;
        var key_lens: [depth_max]usize = undefined;
        const depth = random.intRangeAtMost(usize, 1, depth_max);
        for (0..depth) |level| {
            key_lens[level] = random.intRangeAtMost(usize, 0, key_len_max);
            for (0..key_lens[level]) |at| keys[level][at] = alphabet[random.uintLessThan(usize, 5)];
        }

        // Build the nested document inside out; each map also holds a `key ++ "x"` decoy.
        var node: Value = .{ .int = @intCast(seed) };
        var level = depth;
        while (level > 0) {
            level -= 1;
            const key = keys[level][0..key_lens[level]];
            const decoy = try std.mem.concat(tree.arena.allocator(), u8, &.{ key, "x" });
            var map = try tree.new_map(2);
            try map.put(try tree.dupe_key(key), node);
            try map.put(decoy, .null);
            node = .{ .map = map };
        }
        tree.root = node;

        var text_buffer: [depth_max * (1 + 2 * key_len_max) + 8]u8 = undefined;
        var text_len: usize = 0;
        for (0..depth) |at| {
            text_buffer[text_len] = '/';
            text_len += 1;
            var escaped: [2 * key_len_max]u8 = undefined;
            const piece = escape_key(keys[at][0..key_lens[at]], &escaped);
            @memcpy(text_buffer[text_len..][0..piece.len], piece);
            text_len += piece.len;
        }
        const text = text_buffer[0..text_len];

        var buffer: [pointer.segments_max]Segment = undefined;
        const parsed = try parse_ok(text, &buffer);

        // The naive splitter: cut on '/', decode, compare with the generated keys.
        var split = std.mem.splitScalar(u8, text[1..], '/');
        var at: usize = 0;
        while (split.next()) |raw| : (at += 1) {
            var decoded: [key_len_max]u8 = undefined;
            try expectEqualStrings(keys[at][0..key_lens[at]], naive_decode(raw, &decoded));
            try expectEqualStrings(raw, parsed.segments[at].raw);
            try expect(pointer.segment_eql(raw, keys[at][0..key_lens[at]]));
        }
        try expectEqual(depth, at);
        try expectEqual(depth, parsed.segments.len);

        const found = pointer.resolve(&tree.root, parsed) orelse return error.TestUnexpectedResult;
        try expectEqual(@as(i64, @intCast(seed)), found.int);
        tally_present += 1;

        // Going one segment further hits a scalar; a sibling key that is absent finds nothing.
        var longer: [text_buffer.len + 2]u8 = undefined;
        @memcpy(longer[0..text.len], text);
        longer[text.len..][0..2].* = "/z".*;
        const beyond = try parse_ok(longer[0 .. text.len + 2], &buffer);
        try expect(pointer.resolve(&tree.root, beyond) == null);

        var out: [text_buffer.len]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        try pointer.format(parsed, &w);
        try expectEqualStrings(text, w.buffered());
    }
    try expectEqual(@as(u32, 1000), tally_present);
}

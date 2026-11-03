//! cbor/locate — where in the input a reflect key path points (ADR 0006 section 8).
//!
//! `locate` walks the item starting offsets of an already valid document along a `Path`: a
//! key segment scans the entries of a map for that key (definite or indefinite, the key itself
//! a definite or an indefinite text string), an index segment skips that many elements of an
//! array. It returns the offset of the first byte of the item the path names (the first tag's
//! head when the item is tagged), or of the deepest item it could reach when the path leaves
//! the data (a `MissingField` names the struct, whose own offset is the answer). No recursion:
//! skipping an item watches the reader's own nesting depth.
//!
//! Allocation: none. Cost: one pass over the bytes before the target.

const std = @import("std");
const core = @import("../core.zig");
const context = @import("../reflect/context.zig");
const decoder = @import("decoder.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Path = context.Path;
const Reader = decoder.Reader;
const Segment = context.Segment;
const Token = decoder.Token;

/// The byte offset of the item `path` names in `input`, or of the deepest item that exists on
/// the way; `0` when `input` has no readable root. `path` is not modified.
/// Preconditions: `path.count <= core.value.nesting_max`.
pub fn locate(input: []const u8, path: *const Path) u32 {
    assert(path.count <= core.value.nesting_max);

    var reader: Reader = undefined;
    reader.init(input, core.value.nesting_max) catch return 0;
    var diag = Diagnostics.init(0, 0, "", null);
    var token = read_item(&reader, &diag) orelse return 0;
    for (path.segments[0..path.count]) |segment| {
        token = descend(&reader, token, segment, &diag) orelse break;
    }
    assert(token.offset <= input.len);
    return token.offset;
}

/// The next item, with any tags in front of it folded in: the token has the first tag's offset
/// and the tagged item. Null on a malformed or exhausted input, or at a `stop`.
fn read_item(reader: *Reader, diag: *Diagnostics) ?Token {
    var token = reader.next(diag) catch return null;
    const offset = token.offset;
    // Each tag consumes a byte, so the loop ends within `nesting_max` tags: deeper is TooDeep.
    for (0..core.value.nesting_max + 1) |_| {
        switch (token.item) {
            .tag => token = reader.next(diag) catch return null,
            .stop, .end => return null,
            else => return .{ .offset = offset, .item = token.item },
        }
    }
    return null;
}

/// The child of the container `token` opened that `segment` names, or null. The reader sits just
/// after `token`.
fn descend(reader: *Reader, token: Token, segment: Segment, diag: *Diagnostics) ?Token {
    switch (segment) {
        .none => return token,
        .key => |name| return find_member(reader, token, name, diag),
        .index => |number| {
            const known: u64 = switch (token.item) {
                .array => |count| count,
                .array_indef => std.math.maxInt(u64),
                else => return null,
            };
            if (number >= known) return null;
            for (0..number) |_| skip_item(reader, diag) orelse return null;
            return read_item(reader, diag);
        },
    }
}

fn find_member(reader: *Reader, token: Token, name: []const u8, diag: *Diagnostics) ?Token {
    const known: u64 = switch (token.item) {
        .map => |count| count,
        .map_indef => std.math.maxInt(u64),
        else => return null,
    };
    // Each entry consumes two bytes at least, so the input bounds the loop.
    for (0..@min(known, @as(u64, reader.input.len) + 1)) |_| {
        const key = reader.next(diag) catch return null;
        const found = switch (key.item) {
            .text => |text| std.mem.eql(u8, text, name),
            .text_indef => chunks_equal(reader, name, diag) orelse return null,
            else => return null,
        };
        if (found) return read_item(reader, diag);
        skip_item(reader, diag) orelse return null;
    }
    return null;
}

/// Consumes the chunks of an indefinite text key and says whether they spell `name`.
fn chunks_equal(reader: *Reader, name: []const u8, diag: *Diagnostics) ?bool {
    var matched: u32 = 0;
    var equal = true;
    // Each chunk consumes at least one byte.
    for (0..@as(u64, reader.input.len) + 1) |_| {
        const chunk = reader.next(diag) catch return null;
        switch (chunk.item) {
            .stop => return equal and matched == name.len,
            .text => |text| {
                const rest = name[matched..];
                if (!std.mem.startsWith(u8, rest, text)) equal = false;
                matched += @intCast(@min(text.len, rest.len));
            },
            else => return null,
        }
    }
    return null;
}

/// Consumes one whole item: it is done when the reader is back at the nesting depth it had
/// before the item and no indefinite string is open. Null when the input ends first.
fn skip_item(reader: *Reader, diag: *Diagnostics) ?void {
    const base = reader.depth;
    // Each token consumes at least one byte, so the loop ends within `input.len + 1` tokens.
    for (0..@as(u64, reader.input.len) + 1) |_| {
        const token = reader.next(diag) catch return null;
        if (token.item == .end) return null;
        // A `stop` below the starting depth closes the enclosing container: no item was left.
        if (token.item == .stop and reader.depth < base) return null;
        if (reader.depth == base and reader.string == .none) return;
    }
    return null;
}

const list_key: Segment = .{ .key = "list" };

fn offset_of(input: []const u8, segments: []const Segment) u32 {
    var path: Path = undefined;
    path.init();
    for (segments) |segment| path.push(segment);
    return locate(input, &path);
}

test "locate: a key names the value's first byte, an index the element's" {
    // {"a": 1, "list": [10, "x", [0, 1]]}
    const input = "\xa2\x61a\x01\x64list\x83\x0a\x61x\x82\x00\x01";
    try std.testing.expectEqual(@as(u32, 0), offset_of(input, &.{}));
    try std.testing.expectEqual(@as(u32, 3), offset_of(input, &.{.{ .key = "a" }}));
    try std.testing.expectEqual(@as(u32, 9), offset_of(input, &.{list_key}));
    const second: []const Segment = &.{ list_key, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 11), offset_of(input, second));
    const third: []const Segment = &.{ list_key, .{ .index = 2 } };
    try std.testing.expectEqual(@as(u32, 13), offset_of(input, third));
    const inner: []const Segment = &.{ list_key, .{ .index = 2 }, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 15), offset_of(input, inner));
}

test "locate: indefinite containers, indefinite keys and tagged values" {
    // {_ "a": 1, (_ "l", "ist"): [_ 1, 1(2)], "b": 3}
    const input = "\xbf\x61a\x01\x7f\x61l\x63ist\xff\x9f\x01\xc1\x02\xff\x61b\x03\xff";
    try std.testing.expectEqual(@as(u32, 3), offset_of(input, &.{.{ .key = "a" }}));
    try std.testing.expectEqual(@as(u32, 12), offset_of(input, &.{list_key}));
    const tagged: []const Segment = &.{ list_key, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 14), offset_of(input, tagged));
    try std.testing.expectEqual(@as(u32, 19), offset_of(input, &.{.{ .key = "b" }}));
}

test "locate: skipping nested indefinite items and strings finds the later key" {
    // {"x": [_ {_ "k": h'0102'}, (_ "ab")], "y": 7}
    const input = "\xa2\x61x\x9f\xbf\x61k\x42\x01\x02\xff\x7f\x62ab\xff\xff\x61y\x07";
    try std.testing.expectEqual(@as(u32, 19), offset_of(input, &.{.{ .key = "y" }}));
    const second: []const Segment = &.{ .{ .key = "x" }, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 11), offset_of(input, second));
}

test "locate: a path that leaves the data stops at the deepest item reached" {
    const input = "\xa2\x61a\x01\x64list\x81\x05";
    // Missing key: the map itself. Index past the end: the array. Key under a scalar: the scalar.
    try std.testing.expectEqual(@as(u32, 0), offset_of(input, &.{.{ .key = "zz" }}));
    const past: []const Segment = &.{ list_key, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 9), offset_of(input, past));
    const under: []const Segment = &.{ .{ .key = "a" }, .{ .key = "b" } };
    try std.testing.expectEqual(@as(u32, 3), offset_of(input, under));
    try std.testing.expectEqual(@as(u32, 0), offset_of("", &.{}));
    try std.testing.expectEqual(@as(u32, 0), offset_of("\x1c", &.{.{ .key = "a" }}));
}

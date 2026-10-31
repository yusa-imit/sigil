//! msgpack/locate — where in the input a reflect key path points (ADR 0006 section 8).
//!
//! `locate` walks the item starting offsets of an already valid document along a `Path`: a
//! key segment scans the entries of a map for that key, an index segment skips that many
//! elements of an array. It returns the offset of the first byte of the item the path names, or
//! of the deepest item it could reach when the path leaves the data (a `MissingField` names the
//! struct, whose own offset is the answer). No recursion: skipping an item keeps one counter.
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
    reader.init(input) catch return 0;
    var diag = Diagnostics.init(0, 0, "", null);
    var token = reader.next(&diag) catch return 0;
    for (path.segments[0..path.count]) |segment| {
        token = descend(&reader, token, segment, &diag) orelse break;
    }
    assert(token.offset <= input.len);
    return token.offset;
}

/// The child of the container `token` opened that `segment` names, or null. The reader sits just
/// after `token`.
fn descend(reader: *Reader, token: Token, segment: Segment, diag: *Diagnostics) ?Token {
    switch (segment) {
        .none => return token,
        .key => |name| {
            const count = switch (token.item) {
                .map => |entries| entries,
                else => return null,
            };
            for (0..count) |_| {
                const key = reader.next(diag) catch return null;
                const found = switch (key.item) {
                    .str => |text| std.mem.eql(u8, text, name),
                    else => return null,
                };
                if (found) return reader.next(diag) catch null;
                skip_item(reader, diag) orelse return null;
            }
            return null;
        },
        .index => |number| {
            const count = switch (token.item) {
                .array => |elements| elements,
                else => return null,
            };
            if (number >= count) return null;
            for (0..number) |_| skip_item(reader, diag) orelse return null;
            return reader.next(diag) catch null;
        },
    }
}

/// Consumes one whole item. Null when the input ends or is malformed first.
fn skip_item(reader: *Reader, diag: *Diagnostics) ?void {
    var pending: u64 = 1;
    // Each token consumes at least one byte, so the loop ends within `input.len + 1` tokens.
    for (0..@as(u64, reader.input.len) + 1) |_| {
        const token = reader.next(diag) catch return null;
        pending -= 1;
        switch (token.item) {
            .array => |count| pending += count,
            .map => |count| pending += 2 * @as(u64, count),
            .end => return null,
            else => {},
        }
        if (pending == 0) return;
    }
    return null;
}

const Probe = struct { a: u8, list: []const u8 };

fn offset_of(input: []const u8, segments: []const Segment) u32 {
    var path: Path = undefined;
    path.init();
    for (segments) |segment| path.push(segment);
    return locate(input, &path);
}

const list_key: Segment = .{ .key = "list" };

test "locate: a key names the value's first byte, an index the element's" {
    // {"a": 1, "list": [10, "x", [0, 1]]}
    const input = "\x82\xa1a\x01\xa4list\x93\x0a\xa1x\x92\x00\x01";
    try std.testing.expectEqual(@as(u32, 0), offset_of(input, &.{}));
    try std.testing.expectEqual(@as(u32, 3), offset_of(input, &.{.{ .key = "a" }}));
    try std.testing.expectEqual(@as(u32, 9), offset_of(input, &.{list_key}));
    const second: []const Segment = &.{ list_key, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 11), offset_of(input, second));
    const first: []const Segment = &.{ list_key, .{ .index = 0 } };
    try std.testing.expectEqual(@as(u32, 10), offset_of(input, first));
    const third: []const Segment = &.{ list_key, .{ .index = 2 } };
    try std.testing.expectEqual(@as(u32, 13), offset_of(input, third));
    const inner: []const Segment = &.{ list_key, .{ .index = 2 }, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 15), offset_of(input, inner));
}

test "locate: a path that leaves the data stops at the deepest item reached" {
    const input = "\x82\xa1a\x01\xa4list\x91\x05";
    // Missing key: the map itself. Index past the end: the array. Key under a scalar: the scalar.
    try std.testing.expectEqual(@as(u32, 0), offset_of(input, &.{.{ .key = "zz" }}));
    const past: []const Segment = &.{ list_key, .{ .index = 1 } };
    try std.testing.expectEqual(@as(u32, 9), offset_of(input, past));
    const under: []const Segment = &.{ .{ .key = "a" }, .{ .key = "b" } };
    try std.testing.expectEqual(@as(u32, 3), offset_of(input, under));
    try std.testing.expectEqual(@as(u32, 0), offset_of("", &.{}));
    try std.testing.expectEqual(@as(u32, 0), offset_of("\xc1", &.{.{ .key = "a" }}));
}

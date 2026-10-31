//! Tests for the `msgpack` facade (plan 007 item 4): `parse`/`stringify` of a synod-shaped
//! message through the encoder and decoder, `sigil_options.bytes` in both directions, decode and
//! reflect errors with their positions, and the facade's declared error sets.

const std = @import("std");
const core = @import("../core.zig");
const msgpack = @import("../msgpack.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

const parse_options: msgpack.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const write_options: msgpack.StringifyOptions = .{ .depth_max = 128 };

const Kind = enum { append, vote, heartbeat };

const Entry = struct {
    index: u64,
    payload: []const u8,
    pub const sigil_options = .{ .bytes = .{"payload"} };
};

/// The shape synod puts on the wire: ints, an enum, text, opaque bytes, an optional digest and a
/// list of nested records.
const Message = struct {
    term: u64,
    from: i32,
    kind: Kind,
    note: []const u8,
    digest: ?[]const u8,
    entries: []const Entry,
    pub const sigil_options = .{ .bytes = .{"digest"} };
};

fn fresh_diag() Diagnostics {
    return Diagnostics.init(777, 0, "untouched", null);
}

fn encode(tree: *ValueTree, comptime T: type, value: T) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();

    var diag = fresh_diag();
    try msgpack.stringify(T, tree, &aw.writer, value, write_options, &diag);
    try expectEqual(@as(u32, 777), diag.line);
    return aw.toOwnedSlice();
}

test "facade: a synod-shaped message survives stringify then parse" {
    const entries = [_]Entry{
        .{ .index = 1, .payload = "\x00\x01\xff" },
        .{ .index = 2, .payload = "" },
    };
    const message: Message = .{
        .term = std.math.maxInt(u64),
        .from = -3,
        .kind = .vote,
        .note = "h\xc3\xa9llo",
        .digest = "\xde\xad\xbe\xef",
        .entries = &entries,
    };
    var write_tree: ValueTree = undefined;
    write_tree.init(std.testing.allocator);
    defer write_tree.deinit();

    const bytes = try encode(&write_tree, Message, message);
    defer std.testing.allocator.free(bytes);

    var read_tree: ValueTree = undefined;
    read_tree.init(std.testing.allocator);
    defer read_tree.deinit();

    var diag = fresh_diag();
    const read = try msgpack.parse(Message, &read_tree, bytes, parse_options, &diag);
    try expectEqual(message.term, read.term);
    try expectEqual(message.from, read.from);
    try expectEqual(message.kind, read.kind);
    try expectEqualStrings(message.note, read.note);
    try expectEqualSlices(u8, message.digest.?, read.digest.?);
    try expectEqual(@as(usize, 2), read.entries.len);
    try expectEqualSlices(u8, "\x00\x01\xff", read.entries[0].payload);
    try expectEqual(@as(usize, 0), read.entries[1].payload.len);
    // The second encode is byte-identical: the wire is a function of the value.
    const again = try encode(&write_tree, Message, read);
    defer std.testing.allocator.free(again);

    try expectEqualSlices(u8, bytes, again);
}

test "facade: bytes fields are bin on the wire, plain []const u8 fields are str" {
    const entries = [_]Entry{};
    const message: Message = .{
        .term = 1,
        .from = 2,
        .kind = .append,
        .note = "n",
        .digest = null,
        .entries = &entries,
    };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const bytes = try encode(&tree, Message, message);
    defer std.testing.allocator.free(bytes);

    const expected = "\x86" ++ // map of 6
        "\xa4term\x01" ++ "\xa4from\x02" ++ "\xa4kind\xa6append" ++ "\xa4note\xa1n" ++
        "\xa6digest\xc0" ++ "\xa7entries\x90";
    try expectEqualSlices(u8, expected, bytes);

    const with_digest: Entry = .{ .index = 7, .payload = "ab" };
    const entry_bytes = try encode(&tree, Entry, with_digest);
    defer std.testing.allocator.free(entry_bytes);

    try expectEqualSlices(u8, "\x82\xa5index\x07\xa7payload\xc4\x02ab", entry_bytes);
}

test "facade: a str in a bytes field and a bin in a text field are TypeMismatch" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const str_for_bin = "\x82\xa5index\x07\xa7payload\xa2ab";
    const wrong_payload = msgpack.parse(Entry, &tree, str_for_bin, parse_options, &diag);
    try expectError(error.TypeMismatch, wrong_payload);
    try expectEqual(@as(u32, 17), diag.col);
    try expectEqualStrings("byte 16: payload: expected bytes, found string", diag.message());

    const Plain = struct { note: []const u8 };
    diag = fresh_diag();
    const bin_for_str = "\x81\xa4note\xc4\x02ab";
    const result = msgpack.parse(Plain, &tree, bin_for_str, parse_options, &diag);
    try expectError(error.TypeMismatch, result);
    try expectEqualStrings("byte 6: note: expected string, found bytes", diag.message());
}

test "facade: an optional bytes field reads nil as null and bin as the data" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const Holder = struct {
        digest: ?[]const u8,
        pub const sigil_options = .{ .bytes = .{"digest"} };
    };
    var diag = fresh_diag();
    const nil = try msgpack.parse(Holder, &tree, "\x81\xa6digest\xc0", parse_options, &diag);
    try expect(nil.digest == null);
    const bin = "\x81\xa6digest\xc4\x01\x09";
    const some = try msgpack.parse(Holder, &tree, bin, parse_options, &diag);
    try expectEqualSlices(u8, "\x09", some.digest.?);
    try expectError(
        error.TypeMismatch,
        msgpack.parse(Holder, &tree, "\x81\xa6digest\x05", parse_options, &diag),
    );
    try expectEqualStrings("byte 8: digest: expected bytes, found int", diag.message());
}

test "facade: decode errors carry their byte position, reflect errors their key path" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const truncated = "\x82\xa5index\x07";
    const cut = msgpack.parse(Entry, &tree, truncated, parse_options, &diag);
    try expectError(error.UnexpectedEnd, cut);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 1), diag.col);
    try expect(std.mem.startsWith(u8, diag.message(), "byte 0:"));

    diag = fresh_diag();
    const bad_field = "\x82\xa5index\xa1x\xa7payload\xc4\x00";
    const wrong = msgpack.parse(Entry, &tree, bad_field, parse_options, &diag);
    try expectError(error.TypeMismatch, wrong);
    // The offending `index` value is the str at byte 7.
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 8), diag.col);
    try expectEqualStrings("byte 7: index: expected integer, found string", diag.message());

    diag = fresh_diag();
    const missing = "\x81\xa5index\x07";
    const absent = msgpack.parse(Entry, &tree, missing, parse_options, &diag);
    try expectError(error.MissingField, absent);
    try expectEqual(@as(u32, 1), diag.col);
    try expectEqualStrings("byte 0: missing field \"payload\"", diag.message());
}

test "facade: stringify writes nothing when the conversion fails" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const bad: struct { note: []const u8 } = .{ .note = "\xff" };
    const result = msgpack.stringify(@TypeOf(bad), &tree, &aw.writer, bad, write_options, &diag);
    try expectError(error.InvalidUtf8, result);
    try expectEqual(@as(usize, 0), aw.written().len);
}

test "facade: the error sets are pinned" {
    try expectEqual(@as(usize, 11), @typeInfo(msgpack.ParseValueError).error_set.?.len);
    try expectEqual(@as(usize, 5), @typeInfo(msgpack.WriteValueError).error_set.?.len);
    try expect(!@hasDecl(msgpack, "NotImplemented"));
}

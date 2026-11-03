//! Tests for the `cbor` facade (plan 007 item 7): `parse`/`stringify` of a synod-shaped message
//! through the encoder and decoder, `sigil_options.bytes` in both directions, the deterministic
//! option through `stringify`, decode and reflect errors with their positions (indefinite items
//! included), and the facade's declared error sets.

const std = @import("std");
const core = @import("../core.zig");
const cbor = @import("../cbor.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

const parse_options: cbor.ParseOptions = .{
    .depth_max = 128,
    .bytes_max = 1 << 20,
    .duplicate_key = .reject,
};
const write_options: cbor.StringifyOptions = .{ .depth_max = 128, .deterministic = false };
const sorted_options: cbor.StringifyOptions = .{ .depth_max = 128, .deterministic = true };

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

fn encode(
    tree: *ValueTree,
    comptime T: type,
    value: T,
    options: cbor.StringifyOptions,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();

    var diag = fresh_diag();
    try cbor.stringify(T, tree, &aw.writer, value, options, &diag);
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

    const bytes = try encode(&write_tree, Message, message, write_options);
    defer std.testing.allocator.free(bytes);

    var read_tree: ValueTree = undefined;
    read_tree.init(std.testing.allocator);
    defer read_tree.deinit();

    var diag = fresh_diag();
    const read = try cbor.parse(Message, &read_tree, bytes, parse_options, &diag);
    try expectEqual(message.term, read.term);
    try expectEqual(message.from, read.from);
    try expectEqual(message.kind, read.kind);
    try expectEqualStrings(message.note, read.note);
    try expectEqualSlices(u8, message.digest.?, read.digest.?);
    try expectEqual(@as(usize, 2), read.entries.len);
    try expectEqualSlices(u8, "\x00\x01\xff", read.entries[0].payload);
    try expectEqual(@as(usize, 0), read.entries[1].payload.len);
    // The second encode is byte-identical: the wire is a function of the value.
    const again = try encode(&write_tree, Message, read, write_options);
    defer std.testing.allocator.free(again);

    try expectEqualSlices(u8, bytes, again);
}

test "facade: bytes fields are byte strings on the wire, plain []const u8 fields are text" {
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

    const bytes = try encode(&tree, Message, message, write_options);
    defer std.testing.allocator.free(bytes);

    const expected = "\xa6" ++ // map of 6
        "\x64term\x01" ++ "\x64from\x02" ++ "\x64kind\x66append" ++ "\x64note\x61n" ++
        "\x66digest\xf6" ++ "\x67entries\x80";
    try expectEqualSlices(u8, expected, bytes);

    const with_digest: Entry = .{ .index = 7, .payload = "ab" };
    const entry_bytes = try encode(&tree, Entry, with_digest, write_options);
    defer std.testing.allocator.free(entry_bytes);

    try expectEqualSlices(u8, "\xa2\x65index\x07\x67payload\x42ab", entry_bytes);
}

test "facade: deterministic stringify sorts the fields, the plain one keeps declaration order" {
    const entry: Entry = .{ .index = 7, .payload = "ab" };
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const bytes = try encode(&tree, Entry, entry, sorted_options);
    defer std.testing.allocator.free(bytes);

    // "index" (5 bytes) sorts before "payload" (7): the same bytes as declaration order here.
    try expectEqualSlices(u8, "\xa2\x65index\x07\x67payload\x42ab", bytes);
    const Pair = struct { long_name: u8, id: u8 };
    const pair: Pair = .{ .long_name = 1, .id = 2 };
    const plain = try encode(&tree, Pair, pair, write_options);
    defer std.testing.allocator.free(plain);

    try expectEqualSlices(u8, "\xa2\x69long_name\x01\x62id\x02", plain);
    const reordered = try encode(&tree, Pair, pair, sorted_options);
    defer std.testing.allocator.free(reordered);

    try expectEqualSlices(u8, "\xa2\x62id\x02\x69long_name\x01", reordered);
}

test "facade: a text string in a bytes field and a byte string in a text field mismatch" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const str_for_bin = "\xa2\x65index\x07\x67payload\x62ab";
    const wrong_payload = cbor.parse(Entry, &tree, str_for_bin, parse_options, &diag);
    try expectError(error.TypeMismatch, wrong_payload);
    try expectEqual(@as(u32, 17), diag.col);
    try expectEqualStrings("byte 16: payload: expected bytes, found string", diag.message());

    const Plain = struct { note: []const u8 };
    diag = fresh_diag();
    const bin_for_str = "\xa1\x64note\x42ab";
    const result = cbor.parse(Plain, &tree, bin_for_str, parse_options, &diag);
    try expectError(error.TypeMismatch, result);
    try expectEqualStrings("byte 6: note: expected string, found bytes", diag.message());
}

test "facade: an optional bytes field reads null as null and a byte string as the data" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const Holder = struct {
        digest: ?[]const u8,
        pub const sigil_options = .{ .bytes = .{"digest"} };
    };
    var diag = fresh_diag();
    const nil = try cbor.parse(Holder, &tree, "\xa1\x66digest\xf6", parse_options, &diag);
    try expect(nil.digest == null);
    const bin = "\xa1\x66digest\x41\x09";
    const some = try cbor.parse(Holder, &tree, bin, parse_options, &diag);
    try expectEqualSlices(u8, "\x09", some.digest.?);
    try expectError(
        error.TypeMismatch,
        cbor.parse(Holder, &tree, "\xa1\x66digest\x05", parse_options, &diag),
    );
    try expectEqualStrings("byte 8: digest: expected bytes, found int", diag.message());
}

test "facade: decode errors carry their byte position, reflect errors their key path" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = fresh_diag();
    const truncated = "\xa2\x65index\x07";
    const cut = cbor.parse(Entry, &tree, truncated, parse_options, &diag);
    try expectError(error.UnexpectedEnd, cut);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 1), diag.col);
    try expect(std.mem.startsWith(u8, diag.message(), "byte 0:"));

    diag = fresh_diag();
    const bad_field = "\xa2\x65index\x61x\x67payload\x40";
    const wrong = cbor.parse(Entry, &tree, bad_field, parse_options, &diag);
    try expectError(error.TypeMismatch, wrong);
    // The offending `index` value is the text string at byte 7.
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 8), diag.col);
    try expectEqualStrings("byte 7: index: expected integer, found string", diag.message());

    diag = fresh_diag();
    const missing = "\xa1\x65index\x07";
    const absent = cbor.parse(Entry, &tree, missing, parse_options, &diag);
    try expectError(error.MissingField, absent);
    try expectEqual(@as(u32, 1), diag.col);
    try expectEqualStrings("byte 0: missing field \"payload\"", diag.message());
}

test "facade: reflect errors are located through indefinite maps, arrays, keys and tags" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    // {_ "ent" "ries": [_ {"index": 1, "payload": h'00'}, {_ "index": "x", "payload": h''}]}
    const input = "\xbf\x7f\x63ent\x64ries\xff\x9f" ++
        "\xa2\x65index\x01\x67payload\x41\x00" ++
        "\xbf\x65index\x61x\x67payload\x40\xff\xff\xff";
    const Log = struct { entries: []const Entry };
    var diag = fresh_diag();
    const result = cbor.parse(Log, &tree, input, parse_options, &diag);
    try expectError(error.TypeMismatch, result);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(@as(u32, 39), diag.col);
    try expectEqualStrings(
        "byte 38: entries[1].index: expected integer, found string",
        diag.message(),
    );
}

test "facade: stringify writes nothing when the conversion fails" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var diag = fresh_diag();
    const bad: struct { note: []const u8 } = .{ .note = "\xff" };
    const result = cbor.stringify(@TypeOf(bad), &tree, &aw.writer, bad, write_options, &diag);
    try expectError(error.InvalidUtf8, result);
    try expectEqual(@as(usize, 0), aw.written().len);
}

test "facade: the error sets are pinned" {
    try expectEqual(@as(usize, 17), @typeInfo(cbor.ParseValueError).error_set.?.len);
    try expectEqual(@as(usize, 5), @typeInfo(cbor.WriteValueError).error_set.?.len);
    try expect(!@hasDecl(cbor, "NotImplemented"));
}

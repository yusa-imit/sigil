//! path/pointer — JSON Pointer (RFC 6901) over `core.Value` (ADR 0004 section 2).
//!
//! `parse` splits a pointer text into `Segment`s that are sub-slices of the text, `~0`/`~1`
//! left undecoded; `resolve` walks a `Value` along them; `format` writes the text back. A
//! segment is a key or an array index depending on the node it meets, so the array-index
//! grammar (`0` or `[1-9][0-9]*`, the `-` end marker never naming a node) is applied at
//! `resolve` time through `index_of`, and keys are compared by decoding `~0`/`~1` on the fly.
//!
//! Invariants: `Pointer.segments.len <= segments_max`; every `Segment.raw` holds no `/` and
//! every `~` in it is followed by `0` or `1`; `format(parse(text)) == text`.
//! Allocation: none. `parse` writes into the caller's buffer, `resolve` and `format` read.
//! Cost: `parse` and `format` are O(text); `resolve` is O(segments x container width).
//! Results of `resolve` borrow from the tree they were found in.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Value = core.Value;

/// Most segments one pointer holds; the same boundary as every parser's depth limit, so a
/// pointer can name any node of a tree the parsers built.
pub const segments_max: u32 = core.value.nesting_max;

/// One reference token of a pointer, as written: a sub-slice of the pointer text.
pub const Segment = struct { raw: []const u8 };

/// A parsed pointer. `segments` is the filled prefix of the caller's buffer and `text` the
/// input; both stay valid only as long as the text and the buffer do.
pub const Pointer = struct {
    text: []const u8,
    segments: []const Segment,
};

pub const ParseError = error{ InvalidPointer, TooDeep };

const tilde_message = "'~' must be followed by '0' or '1'";
const start_message = "a pointer must be empty or start with '/'";

/// Splits `text` into segments, written to `buffer`. The empty text is the root: zero segments.
/// On error `diag` holds `1:col`, with `col` the 1-based byte column of the offending byte
/// (for `TooDeep`, of the `/` that opens the 129th segment); on success it is untouched.
/// Preconditions: `buffer.len >= segments_max`; `text.len <= maxInt(u32)`.
pub fn parse(text: []const u8, buffer: []Segment, diag: *Diagnostics) ParseError!Pointer {
    assert(buffer.len >= segments_max);
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return .{ .text = text, .segments = buffer[0..0] };
    if (text[0] != '/') {
        return fail(diag, text, 0, error.InvalidPointer, start_message);
    }

    var count: u32 = 0;
    var start: u32 = 1;
    for (text, 0..) |byte, offset_index| {
        const offset: u32 = @intCast(offset_index);
        switch (byte) {
            '/' => {
                if (offset > 0) {
                    buffer[count] = .{ .raw = text[start..offset] };
                    count += 1;
                    start = offset + 1;
                }
                if (count == segments_max) {
                    return fail(diag, text, offset, error.TooDeep, "more than 128 segments");
                }
            },
            '~' => {
                const next: u8 = if (offset + 1 < text.len) text[offset + 1] else 0;
                if (next != '0' and next != '1') {
                    return fail(diag, text, offset, error.InvalidPointer, tilde_message);
                }
            },
            else => {},
        }
    }
    buffer[count] = .{ .raw = text[start..] };
    count += 1;

    assert(count >= 1);
    assert(count <= segments_max);
    return .{ .text = text, .segments = buffer[0..count] };
}

/// The node `pointer` names under `root`, or null when it names nothing: a missing key, an
/// index at or past the end, the `-` end marker, a malformed index (sign, leading zero, wider
/// than `u32`), or a segment applied to a scalar. Absence is a result, not an error.
/// The result points into `root`'s tree. Precondition: `pointer.segments.len <= segments_max`.
pub fn resolve(root: *const Value, pointer: Pointer) ?*const Value {
    assert(pointer.segments.len <= segments_max);
    assert(pointer.text.len == 0 or pointer.text[0] == '/');

    var node = root;
    for (pointer.segments) |segment| {
        node = child_of(node, segment.raw) orelse return null;
    }
    return node;
}

/// Writes `pointer` as text: `/` before each segment, segments as parsed. Output equals
/// `pointer.text` for a pointer `parse` returned.
/// Preconditions: every segment is escaped (no `/`, `~` followed by `0` or `1`).
pub fn format(pointer: Pointer, w: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(pointer.segments.len <= segments_max);
    for (pointer.segments) |segment| {
        assert(std.mem.findScalar(u8, segment.raw, '/') == null);
        try w.writeByte('/');
        try w.writeAll(segment.raw);
    }
}

/// The array index a segment names: `0` or `[1-9][0-9]*` that fits in `u32`. Null for the `-`
/// end marker, the empty segment, a leading zero, a sign, any other byte, or overflow.
pub fn index_of(raw: []const u8) ?u32 {
    if (raw.len == 0) return null;
    if (raw.len > 1 and raw[0] == '0') return null;
    if (raw.len > 10) return null; // u32 holds at most 10 digits.

    var total: u64 = 0;
    for (raw) |byte| {
        if (byte < '0' or byte > '9') return null;
        total = total * 10 + (byte - '0');
    }
    if (total > std.math.maxInt(u32)) return null;
    return @intCast(total);
}

/// Whether the escaped segment `raw` names exactly `key` once `~0` is read as `~` and `~1` as
/// `/`. Allocation-free. Precondition: every `~` in `raw` is followed by `0` or `1`.
pub fn segment_eql(raw: []const u8, key: []const u8) bool {
    var raw_index: usize = 0;
    var key_index: usize = 0;
    while (raw_index < raw.len) {
        var byte = raw[raw_index];
        raw_index += 1;
        if (byte == '~') {
            assert(raw_index < raw.len);
            const code = raw[raw_index];
            assert(code == '0' or code == '1');
            raw_index += 1;
            byte = if (code == '0') '~' else '/';
        }
        if (key_index == key.len) return false;
        if (key[key_index] != byte) return false;
        key_index += 1;
    }
    return key_index == key.len;
}

fn child_of(node: *const Value, raw: []const u8) ?*const Value {
    switch (node.*) {
        .map => |*map| {
            for (map.items()) |*entry| {
                if (segment_eql(raw, entry.key)) return &entry.value;
            }
            return null;
        },
        .array => |items| {
            const index = index_of(raw) orelse return null;
            if (index >= items.len) return null;
            return &items[index];
        },
        else => return null,
    }
}

fn fail(
    diag: *Diagnostics,
    text: []const u8,
    offset: u32,
    err: ParseError,
    message: []const u8,
) ParseError {
    assert(offset < text.len);
    diag.* = Diagnostics.init(
        1,
        offset + 1,
        message,
        core.diagnostics.snippet_of(text, offset),
    );
    return err;
}

test {
    _ = @import("pointer_test.zig");
}

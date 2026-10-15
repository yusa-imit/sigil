//! path/patch — JSON Patch (RFC 6902) over `core.Value` (ADR 0004 sections 3 and 4).
//!
//! `apply` runs an array of operations (`add`, `remove`, `replace`, `move`, `copy`, `test`) on
//! `tree.root`. Each operation rebuilds only the spine from the root to the change (a copy of
//! every container on the path, siblings shared) and the next operation sees that result;
//! `tree.root` is assigned once, after the last operation succeeded, so a failing operation
//! leaves the tree exactly as it was. Nothing is changed in place, there is no recursion (the
//! walk uses fixed `nesting_max` arrays), and a pointer holds at most `segments_max` segments.
//!
//! Operand values (`value` of add/replace/test, the source of copy/move) are deep-copied into
//! the tree through `clone.deep`, so no byte of the tree aliases `ops`, and the tree never holds
//! one subtree twice (`copy` and `move` copy rather than share: a shared subtree would need a
//! depth walk per use, and doubling `copy`s would make that walk exponential).
//!
//! Invariants: after `apply` returns an error, `tree.root` is the value it held before; after
//! success the tree nests at most `nesting_max` levels; the diagnostics are written on every
//! error and left alone on success. An index past the end of an array is `IndexOutOfRange` at
//! any step of a path; `-` and malformed indices (sign, leading zero, wider than `u32`) name
//! nothing and are `PathNotFound`, except `add`'s final `-`, which appends.
//! Allocation: only `tree.arena`; replaced nodes stay as garbage until `deinit`. One operation
//! allocates O(sum of the widths of the containers on its path) plus the operand copy.
//! Cost: O(path length x container width) time per operation, O(nesting_max) stack.

const std = @import("std");
const core = @import("../core.zig");
const clone = @import("clone.zig");
const pointer = @import("pointer.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Segment = pointer.Segment;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;

pub const PatchError = error{
    InvalidPatch,
    UnknownOp,
    InvalidPointer,
    PathNotFound,
    IndexOutOfRange,
    TestFailed,
    InvalidMove,
    TooDeep,
    OutOfMemory,
};

const LookupError = error{ PathNotFound, IndexOutOfRange };

const Kind = enum { add, remove, replace, move, copy, check };

/// What `edit` does at the last segment of a path.
const Edit = enum { add, remove, replace };

/// The containers on the way down a path: `nodes[i]` is the node after `i` segments and
/// `slots[i]` the entry or index of segment `i` inside `nodes[i]`.
const Spine = struct {
    nodes: [nesting_max + 1]Value,
    slots: [nesting_max]u32,
};

/// Applies the RFC 6902 document `ops` (an array of operation maps) to `tree.root`, in order.
/// `ops` is borrowed for the call only; the tree copies what it keeps. On any error the root is
/// unchanged and `diag` holds `op <index>: <reason>` with no source position (the tree has
/// none); on success `diag` is untouched. Move and copy deep-copy; see the header for cost.
/// Preconditions: `tree` was initialized; `ops` and `tree.root` hold no map with a duplicate
/// key and nest at most `nesting_max`.
pub fn apply(tree: *ValueTree, ops: *const Value, diag: *Diagnostics) PatchError!void {
    assert(tree.root != .array or tree.root.array.len < std.math.maxInt(u32));
    assert(diag.message().len <= core.diagnostics.default_limits.message_len_max);
    if (ops.* != .array) return fail(diag, null, error.InvalidPatch);

    var current = tree.root;
    for (ops.array, 0..) |op, op_index| {
        current = apply_op(tree, current, op) catch |err| return fail(diag, op_index, err);
    }
    assert(ops.* == .array);
    tree.root = current;
}

fn apply_op(tree: *ValueTree, root: Value, op: Value) PatchError!Value {
    if (op != .map) return error.InvalidPatch;
    const kind = try kind_of(op.map);
    var path_buffer: [pointer.segments_max]Segment = undefined;
    const path = try parse_pointer(try string_member(op.map, "path"), &path_buffer);
    const segments = path.segments;

    switch (kind) {
        .add, .replace => {
            const operand = op.map.get("value") orelse return error.InvalidPatch;
            const copy = try clone.deep(tree, operand.*, @intCast(segments.len));
            return try edit(tree, root, segments, if (kind == .add) .add else .replace, copy);
        },
        .remove => return try edit(tree, root, segments, .remove, .null),
        .check => {
            const operand = op.map.get("value") orelse return error.InvalidPatch;
            const found = try locate(root, segments);
            if (!try core.value.eql(found, operand.*)) return error.TestFailed;
            return root;
        },
        .move, .copy => {
            var from_buffer: [pointer.segments_max]Segment = undefined;
            const from_text = try string_member(op.map, "from");
            const from = try parse_pointer(from_text, &from_buffer);
            return try move_or_copy(tree, root, from.segments, segments, kind);
        },
    }
}

fn kind_of(op: Map) PatchError!Kind {
    const name = try string_member(op, "op");
    const names = [_]struct { text: []const u8, kind: Kind }{
        .{ .text = "add", .kind = .add },
        .{ .text = "remove", .kind = .remove },
        .{ .text = "replace", .kind = .replace },
        .{ .text = "move", .kind = .move },
        .{ .text = "copy", .kind = .copy },
        .{ .text = "test", .kind = .check },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry.text, name)) return entry.kind;
    }
    return error.UnknownOp;
}

fn string_member(op: Map, key: []const u8) PatchError![]const u8 {
    const member = op.get(key) orelse return error.InvalidPatch;
    if (member.* != .string) return error.InvalidPatch;
    return member.string;
}

fn parse_pointer(
    text: []const u8,
    buffer: *[pointer.segments_max]Segment,
) PatchError!pointer.Pointer {
    // Text this long is data from a hand-built `Value`, not a contract violation.
    if (text.len > std.math.maxInt(u32)) return error.InvalidPointer;
    var parse_diag = Diagnostics.init(0, 0, "", null);
    return try pointer.parse(text, buffer, &parse_diag);
}

/// RFC 6902 sections 4.4 and 4.5: `copy` adds a copy of the value at `from`; `move` removes it
/// first. A `move` onto its own location changes nothing; into its own child is `InvalidMove`.
fn move_or_copy(
    tree: *ValueTree,
    root: Value,
    from: []const Segment,
    path: []const Segment,
    kind: Kind,
) PatchError!Value {
    assert(kind == .move or kind == .copy);
    assert(from.len <= pointer.segments_max and path.len <= pointer.segments_max);
    const source = try locate(root, from);
    if (kind == .move) {
        if (is_prefix(from, path)) {
            if (from.len == path.len) return root;
            return error.InvalidMove;
        }
    }
    const copy = try clone.deep(tree, source, @intCast(path.len));
    if (kind == .copy) return try edit(tree, root, path, .add, copy);

    const removed = try edit(tree, root, from, .remove, .null);
    return try edit(tree, removed, path, .add, copy);
}

fn is_prefix(prefix: []const Segment, whole: []const Segment) bool {
    if (prefix.len > whole.len) return false;
    for (prefix, whole[0..prefix.len]) |left, right| {
        // Escaping is canonical (`~0`, `~1` only), so equal raw text is equal decoded text.
        if (!std.mem.eql(u8, left.raw, right.raw)) return false;
    }
    return true;
}

/// The node `segments` names under `root`.
fn locate(root: Value, segments: []const Segment) LookupError!Value {
    var node = root;
    for (segments) |segment| {
        const slot = try slot_of(node, segment.raw);
        node = child_at(node, slot);
    }
    return node;
}

/// Fills `spine` for `segments` under `root`: `nodes[0..=segments.len]` and their slots.
fn descend(spine: *Spine, root: Value, segments: []const Segment) LookupError!void {
    assert(segments.len <= nesting_max);
    spine.nodes[0] = root;
    for (segments, 0..) |segment, index| {
        const slot = try slot_of(spine.nodes[index], segment.raw);
        spine.slots[index] = slot;
        spine.nodes[index + 1] = child_at(spine.nodes[index], slot);
    }
}

/// The entry index (map) or element index (array) a segment names inside `node`.
fn slot_of(node: Value, raw: []const u8) LookupError!u32 {
    switch (node) {
        .map => |map| return map_slot(map, raw) orelse error.PathNotFound,
        .array => |items| {
            const index = pointer.index_of(raw) orelse return error.PathNotFound;
            if (index >= items.len) return error.IndexOutOfRange;
            return index;
        },
        else => return error.PathNotFound,
    }
}

fn map_slot(map: Map, raw: []const u8) ?u32 {
    for (map.items(), 0..) |entry, index| {
        if (pointer.segment_eql(raw, entry.key)) return @intCast(index);
    }
    return null;
}

fn child_at(node: Value, slot: u32) Value {
    switch (node) {
        .map => |map| {
            assert(slot < map.count);
            return map.items()[slot].value;
        },
        .array => |items| {
            assert(slot < items.len);
            return items[slot];
        },
        else => unreachable, // proof: `slot_of` only returns a slot for containers.
    }
}

/// Applies `what` at the last segment of `segments` and returns the new root. `value` is read
/// by add and replace only, and must already belong to the tree. Rebuilds the spine; the
/// result nests exactly as deep as `root` plus whatever `value` brings.
fn edit(
    tree: *ValueTree,
    root: Value,
    segments: []const Segment,
    what: Edit,
    value: Value,
) PatchError!Value {
    if (segments.len == 0) {
        // The root can be replaced but not removed: a document without a root is no document.
        if (what == .remove) return error.InvalidPatch;
        return value;
    }
    const parent_segments = segments[0 .. segments.len - 1];
    var spine: Spine = undefined;
    try descend(&spine, root, parent_segments);
    const parent = spine.nodes[parent_segments.len];
    const last = segments[segments.len - 1].raw;

    var rebuilt = switch (parent) {
        .map => |map| try edit_map(tree, map, last, what, value),
        .array => |items| try edit_array(tree, items, last, what, value),
        else => return error.PathNotFound,
    };
    for (0..parent_segments.len) |step| {
        const index = parent_segments.len - 1 - step;
        rebuilt = try with_child(tree, spine.nodes[index], spine.slots[index], rebuilt);
    }
    return rebuilt;
}

fn edit_map(
    tree: *ValueTree,
    map: Map,
    raw: []const u8,
    what: Edit,
    value: Value,
) PatchError!Value {
    const slot = map_slot(map, raw);
    switch (what) {
        .add => {
            if (slot) |index| return try map_with_value(tree, map, index, value);
            return try map_appended(tree, map, raw, value);
        },
        .replace => {
            const index = slot orelse return error.PathNotFound;
            return try map_with_value(tree, map, index, value);
        },
        .remove => return try map_without(tree, map, slot orelse return error.PathNotFound),
    }
}

fn edit_array(
    tree: *ValueTree,
    items: []const Value,
    raw: []const u8,
    what: Edit,
    value: Value,
) PatchError!Value {
    switch (what) {
        .add => {
            const end = std.mem.eql(u8, raw, "-");
            const named = pointer.index_of(raw);
            if (!end and named == null) return error.PathNotFound;
            const index: usize = if (end) items.len else named.?;
            if (index > items.len) return error.IndexOutOfRange;
            return try array_inserted(tree, items, index, value);
        },
        .replace, .remove => {
            const index = try slot_of(.{ .array = items }, raw);
            if (what == .replace) return try array_with_value(tree, items, index, value);
            return try array_without(tree, items, index);
        },
    }
}

fn with_child(tree: *ValueTree, container: Value, slot: u32, child: Value) PatchError!Value {
    switch (container) {
        .map => |map| return try map_with_value(tree, map, slot, child),
        .array => |items| return try array_with_value(tree, items, slot, child),
        else => unreachable, // proof: a spine holds containers above the edit.
    }
}

fn map_with_value(tree: *ValueTree, map: Map, slot: u32, value: Value) PatchError!Value {
    assert(slot < map.count);
    var out = try tree.new_map(map.count);
    @memcpy(out.entries[0..map.count], map.items());
    out.count = map.count;
    out.entries[slot].value = value;
    assert(out.count == map.count);
    return .{ .map = out };
}

fn map_appended(tree: *ValueTree, map: Map, raw: []const u8, value: Value) PatchError!Value {
    const capacity = std.math.add(u32, map.count, 1) catch return error.OutOfMemory;
    var out = try tree.new_map(capacity);
    @memcpy(out.entries[0..map.count], map.items());
    out.entries[map.count] = .{ .key = try decode_key(tree, raw), .value = value };
    out.count = capacity;
    assert(out.entries[map.count].key.len <= raw.len);
    return .{ .map = out };
}

fn map_without(tree: *ValueTree, map: Map, slot: u32) PatchError!Value {
    assert(slot < map.count);
    var out = try tree.new_map(map.count - 1);
    @memcpy(out.entries[0..slot], map.items()[0..slot]);
    @memcpy(out.entries[slot .. map.count - 1], map.items()[slot + 1 ..]);
    out.count = map.count - 1;
    assert(out.count + 1 == map.count);
    return .{ .map = out };
}

fn array_with_value(
    tree: *ValueTree,
    items: []const Value,
    index: usize,
    value: Value,
) PatchError!Value {
    assert(index < items.len);
    const out = try tree.arena.allocator().alloc(Value, items.len);
    @memcpy(out, items);
    out[index] = value;
    assert(out.len == items.len);
    return .{ .array = out };
}

fn array_inserted(
    tree: *ValueTree,
    items: []const Value,
    index: usize,
    value: Value,
) PatchError!Value {
    assert(index <= items.len);
    const out = try tree.arena.allocator().alloc(Value, items.len + 1);
    @memcpy(out[0..index], items[0..index]);
    out[index] = value;
    @memcpy(out[index + 1 ..], items[index..]);
    assert(out.len == items.len + 1);
    return .{ .array = out };
}

fn array_without(tree: *ValueTree, items: []const Value, index: usize) PatchError!Value {
    assert(index < items.len);
    const out = try tree.arena.allocator().alloc(Value, items.len - 1);
    @memcpy(out[0..index], items[0..index]);
    @memcpy(out[index..], items[index + 1 ..]);
    assert(out.len + 1 == items.len);
    return .{ .array = out };
}

/// The key a segment names, `~1` read as `/` and `~0` as `~`, copied into the tree.
/// Precondition: every `~` in `raw` is followed by `0` or `1` (`pointer.parse` checked it).
fn decode_key(tree: *ValueTree, raw: []const u8) PatchError![]const u8 {
    var length: usize = 0;
    var raw_index: usize = 0;
    while (raw_index < raw.len) : (raw_index += 1) {
        if (raw[raw_index] == '~') raw_index += 1;
        length += 1;
    }
    assert(raw_index == raw.len);
    const key = try tree.arena.allocator().alloc(u8, length);
    var key_index: usize = 0;
    raw_index = 0;
    while (raw_index < raw.len) : (raw_index += 1) {
        const byte = raw[raw_index];
        if (byte == '~') {
            raw_index += 1;
            key[key_index] = if (raw[raw_index] == '0') '~' else '/';
        } else {
            key[key_index] = byte;
        }
        key_index += 1;
    }
    assert(key_index == length);
    return key;
}

const reasons = [_]struct { err: PatchError, text: []const u8 }{
    .{ .err = error.InvalidPatch, .text = "malformed operation (not an object, a member missing" ++
        " or of the wrong type, or the document root removed)" },
    .{ .err = error.UnknownOp, .text = "\"op\" is not add, remove, replace, move, copy or test" },
    .{ .err = error.InvalidPointer, .text = "\"path\" or \"from\" is not a JSON Pointer" },
    .{ .err = error.PathNotFound, .text = "the target location does not exist" },
    .{ .err = error.IndexOutOfRange, .text = "array index is past the end of the array" },
    .{ .err = error.TestFailed, .text = "the value found differs from the tested value" },
    .{ .err = error.InvalidMove, .text = "\"from\" is a proper prefix of \"path\"" },
    .{ .err = error.TooDeep, .text = "a pointer or the result nests past nesting_max" },
    .{ .err = error.OutOfMemory, .text = "out of memory" },
};

fn reason_of(err: PatchError) []const u8 {
    for (reasons) |entry| {
        if (entry.err == err) return entry.text;
    }
    unreachable; // proof: `reasons` lists every PatchError variant (a test pins the count).
}

/// Records `op <index>: <reason>` (`patch: <reason>` without an index) and returns `err`.
fn fail(diag: *Diagnostics, op_index: ?usize, err: PatchError) PatchError {
    var buffer: [core.diagnostics.default_limits.message_len_max]u8 = undefined;
    const reason = reason_of(err);
    const text = if (op_index) |index|
        std.fmt.bufPrint(&buffer, "op {d}: {s}", .{ index, reason }) catch reason
    else
        std.fmt.bufPrint(&buffer, "patch: {s}", .{reason}) catch reason;
    const none = core.diagnostics.position_none;
    diag.* = Diagnostics.init(none, none, text, null);
    assert(diag.message().len > 0);
    return err;
}

test {
    _ = @import("patch_test.zig");
}

test "patch: every PatchError variant has a reason" {
    try std.testing.expectEqual(@typeInfo(PatchError).error_set.?.len, reasons.len);
}

//! path/merge — JSON Merge Patch (RFC 7386) over `core.Value` (ADR 0004 sections 3 and 4).
//!
//! `apply` merges a borrowed patch into `tree.root`: an object patch merges key by key (`null`
//! deletes, an object recurses, anything else replaces), a non-object patch replaces the whole
//! target. Nothing is changed in place: every map on the path to a change is rebuilt (target
//! entries first, in order, then new keys in patch order) and untouched subtrees are shared,
//! so `tree.root` is assigned once, after the last step succeeded. The walk uses an explicit
//! stack of `nesting_max` frames, no recursion.
//!
//! Invariants: after `apply` returns `error`, `tree.root` is the value it held before; after
//! success the tree nests at most `nesting_max` levels and no byte of it aliases the patch.
//! Allocation: only `tree.arena`. Replaced and abandoned nodes stay as garbage until `deinit`
//! (an arena cannot free one allocation); a merge touching `k` maps of width `w` allocates up
//! to `k * (w + patch width) * 48` bytes plus a copy of every value the patch brings in.
//! Cost: O(patch size x width of the maps it touches) time, O(nesting_max) stack.

const std = @import("std");
const core = @import("../core.zig");
const clone = @import("clone.zig");
const assert = std.debug.assert;
const Map = core.Map;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;

pub const MergeError = error{ TooDeep, OutOfMemory };

/// A map being rebuilt. `out` starts as a copy of the target's entries (children shared), with
/// room for every key the patch could add; `patch` is read from `patch_index` on. While a
/// child frame runs, `pending_key`/`pending_slot` say where its result goes in `out`.
const Frame = struct {
    out: Map,
    patch: Map,
    patch_index: u32,
    pending_key: []const u8,
    pending_slot: ?u32,
};

/// Merges `patch` into `tree.root` per RFC 7386. `patch` is borrowed for the call only; the
/// tree copies what it keeps. On `error.TooDeep` (the result would nest past `nesting_max`) or
/// `error.OutOfMemory` the root is unchanged and still valid.
/// A patch nesting past `nesting_max` is data a hand-built `Value` can hold, so it is
/// `TooDeep`, not a contract violation. Preconditions: `tree` was initialized; `patch` and
/// `tree.root` hold no map with a duplicate key; `tree.root` nests at most `nesting_max`.
pub fn apply(tree: *ValueTree, patch: *const Value) MergeError!void {
    const root_before = tree.root;
    const merged = try merge(tree, root_before, patch.*);
    assert(patch.* != .map or merged == .map);
    assert(patch.* == .map or std.meta.activeTag(merged) == std.meta.activeTag(patch.*));
    tree.root = merged;
}

fn merge(tree: *ValueTree, target: Value, patch: Value) MergeError!Value {
    if (patch != .map) return try clone.deep(tree, patch, 0);

    var frames: [nesting_max]Frame = undefined;
    frames[0] = try open_frame(tree, target, patch.map);
    var depth: u32 = 1;
    var result: Value = .null;
    while (depth > 0) {
        assert(depth <= nesting_max);
        const top = &frames[depth - 1];
        if (top.patch_index == top.patch.count) {
            const done: Value = .{ .map = top.out };
            depth -= 1;
            if (depth == 0) {
                result = done;
            } else {
                try attach(tree, &frames[depth - 1], done);
            }
            continue;
        }
        if (try visit_entry(tree, top, depth)) |child| {
            frames[depth] = child;
            depth += 1;
        }
    }
    assert(result == .map);
    return result;
}

/// Applies the next patch entry of `top` (a frame at nesting level `depth`). Returns the frame
/// of the child merge to run first when the entry is an object, null when it is settled.
fn visit_entry(tree: *ValueTree, top: *Frame, depth: u32) MergeError!?Frame {
    assert(top.patch_index < top.patch.count);
    const entry = top.patch.items()[top.patch_index];
    top.patch_index += 1;
    const slot = top.out.index_of(entry.key);
    switch (entry.value) {
        .null => {
            if (slot) |index| remove_at(&top.out, index);
            return null;
        },
        .map => |child_patch| {
            if (depth == nesting_max) return error.TooDeep;
            const existing: Value = if (slot) |index| top.out.entries[index].value else .null;
            const child = try open_frame(tree, existing, child_patch);
            top.pending_key = entry.key;
            top.pending_slot = slot;
            return child;
        },
        else => {
            const copy = try clone.deep(tree, entry.value, depth);
            try store(tree, &top.out, slot, entry.key, copy);
            return null;
        },
    }
}

/// Starts rebuilding `target` for `patch`: a non-map target merges as the empty map.
fn open_frame(tree: *ValueTree, target: Value, patch: Map) MergeError!Frame {
    const kept: []const Map.Entry = if (target == .map) target.map.items() else &.{};
    // A map this large cannot be allocated anyway; report it as the allocation failure it is.
    const kept_count = std.math.cast(u32, kept.len) orelse return error.OutOfMemory;
    const capacity = std.math.add(u32, kept_count, patch.count) catch return error.OutOfMemory;
    var out = try tree.new_map(capacity);
    @memcpy(out.entries[0..kept.len], kept);
    out.count = kept_count;
    assert(out.count <= out.entries.len);
    assert(out.entries.len - out.count == patch.count);
    return .{
        .out = out,
        .patch = patch,
        .patch_index = 0,
        .pending_key = "",
        .pending_slot = null,
    };
}

/// Puts a finished child map where `parent` recorded it: over an existing slot, or appended
/// under a copy of the patch's key.
fn attach(tree: *ValueTree, parent: *Frame, done: Value) MergeError!void {
    assert(done == .map);
    try store(tree, &parent.out, parent.pending_slot, parent.pending_key, done);
}

fn store(
    tree: *ValueTree,
    out: *Map,
    slot: ?u32,
    key: []const u8,
    value: Value,
) MergeError!void {
    assert(out.count <= out.entries.len);
    if (slot) |index| {
        assert(index < out.count);
        out.entries[index].value = value;
        return;
    }
    // Capacity was reserved for every patch key (`open_frame`), and `slot == null` says the
    // key is absent, so the append cannot overflow or collide.
    assert(out.count < out.entries.len);
    assert(out.index_of(key) == null);
    const key_copy = try tree.dupe_key(key);
    out.entries[out.count] = .{ .key = key_copy, .value = value };
    out.count += 1;
}

/// Deletes the live entry at `index`, keeping the order of the rest.
fn remove_at(out: *Map, index: u32) void {
    assert(index < out.count);
    const count_before = out.count;
    const tail = out.entries[index + 1 .. count_before];
    std.mem.copyForwards(Map.Entry, out.entries[index .. count_before - 1], tail);
    out.count -= 1;
    assert(out.count == count_before - 1);
}

test {
    _ = clone;
    _ = @import("merge_test.zig");
}

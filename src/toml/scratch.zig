//! toml/scratch — the mutable table tree a TOML document is built in, and its one exact copy
//! into a `ValueTree` (ADR 0005 sections 3 and 4).
//!
//! TOML extends tables out of order (`[a.b]`, `[c]`, `[a.d]`) but a `core.Map` has a capacity
//! fixed at creation. So the parser first builds this scratch tree: every node is a table, an
//! array or a scalar with a first-child / last-child / next-sibling list, so appending is O(1)
//! and needs no capacity. `materialize` then walks it once and writes each table as a `Map` of
//! exactly its final size.
//!
//! Every container has one `State` (the ADR 0005 section 4 table) and the three navigation
//! calls apply its rows: `header_pass` / `header_end` for `[a.b]` and `[[a.b]]`, `dotted_pass`
//! for the non-last segments of `a.b.c = v`. A conflict returns a typed error and leaves the
//! byte offset of the earlier definition in `conflict_offset` for the parser's diagnostic.
//!
//! Lookup is a hash index over (parent, key), so a table with a million keys costs a million
//! probes, not a million squared. Keys are compared as decoded bytes. The hash is Wyhash seeded
//! with the parent index and not secret: crafted keys that collide can slow one parse down, which
//! `ParseOptions.bytes_max` bounds. A node is about 90 bytes, so scratch costs roughly 50 bytes
//! per input byte (plan 006 item 11 measures it).
//!
//! Allocation: `init` allocates two arrays from `gpa` bounded by the input length (nodes and
//! hash slots), `deinit` frees them; nothing is allocated from `gpa` in between. `materialize`
//! allocates only from the tree arena. Invariants: `node_count <= nodes.len`; node 0 is the
//! root table; every node's depth is at most `depth_max`; `check_invariants` re-derives each
//! child count from the sibling lists.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Map = core.Map;
const Segment = @import("../reflect/context.zig").Segment;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// How a container came to be; decides what a later header or dotted key may do to it.
pub const State = enum(u8) {
    /// An intermediate segment of a header: `a` in `[a.b]`.
    implicit,
    /// Named by a `[header]`, or an element of an `[[array]]`.
    header,
    /// Made by a dotted key: `a` in `a.b = 1`.
    dotted,
    /// An inline table `{ ... }`: frozen from the start, nothing reaches inside it later.
    inline_table,
    /// An array value `a = [ ... ]`.
    array_static,
    /// An `[[a]]` array; its children are the elements, each a `header` table.
    array_tables,
    /// A leaf value.
    scalar,
};

pub const Error = error{ DuplicateKey, TableRedefined, TypeConflict, TooDeep, OutOfMemory };

/// A decoded key plus where it was written. `owned` means `bytes` already lives in the tree
/// arena (a decoded escape); otherwise it borrows the input and `materialize` copies it.
pub const Key = struct {
    bytes: []const u8,
    offset: u32,
    owned: bool,
};

pub const root_index: u32 = 0;
const none: u32 = std.math.maxInt(u32);

const Node = struct {
    key: []const u8,
    value: Value,
    parent: u32,
    first_child: u32,
    last_child: u32,
    next_sibling: u32,
    child_count: u32,
    offset: u32,
    depth: u16,
    state: State,
    key_owned: bool,
};

pub const Scratch = struct {
    nodes: []Node,
    node_count: u32,
    slots: []u32,
    depth_max: u16,
    /// Definition offset of the node the last `DuplicateKey`, `TableRedefined`, `TypeConflict`
    /// or `TooDeep` ran into (for `TooDeep`: the offending key itself).
    conflict_offset: u32,

    /// Allocates the node and slot arrays for an input of `input_len` bytes. Every node but
    /// the root costs at least two input bytes (a one-byte key plus its `.`, `=` or `]`; an
    /// `[[a]]` element rides on the 5 bytes of its header), so `input_len / 2 + 2` nodes leave
    /// a margin of one. A `[` or `{` costs one byte until its closer arrives, so `depth_max`
    /// more nodes are allowed for containers still open at the end of the input.
    /// Precondition: `1 <= depth_max <= core.value.nesting_max`.
    pub fn init(
        scratch: *Scratch,
        gpa: Allocator,
        input_len: u32,
        depth_max: u16,
    ) error{OutOfMemory}!void {
        assert(depth_max >= 1);
        assert(depth_max <= core.value.nesting_max);
        const nodes_max = @as(usize, @divFloor(input_len, 2)) + 2 + depth_max;
        const doubled = std.math.mul(usize, nodes_max, 2) catch return error.OutOfMemory;
        const slot_count = std.math.ceilPowerOfTwo(usize, doubled) catch return error.OutOfMemory;
        const nodes = try gpa.alloc(Node, nodes_max);
        errdefer gpa.free(nodes);

        const slots = try gpa.alloc(u32, slot_count);
        errdefer gpa.free(slots);

        @memset(slots, none);
        scratch.* = .{
            .nodes = nodes,
            .node_count = 1,
            .slots = slots,
            .depth_max = depth_max,
            .conflict_offset = 0,
        };
        nodes[root_index] = new_node("", 0, root_index, .header, 1);
        assert(scratch.node_count == 1);
        assert(scratch.slots.len >= scratch.nodes.len * 2);
    }

    /// Frees both arrays. `gpa` must be the one given to `init`.
    pub fn deinit(scratch: *Scratch, gpa: Allocator) void {
        assert(scratch.node_count >= 1);
        gpa.free(scratch.slots);
        gpa.free(scratch.nodes);
        scratch.* = undefined;
    }

    pub fn state_of(scratch: *const Scratch, index: u32) State {
        assert(index < scratch.node_count);
        return scratch.nodes[index].state;
    }

    pub fn child_count(scratch: *const Scratch, index: u32) u32 {
        assert(index < scratch.node_count);
        return scratch.nodes[index].child_count;
    }

    /// The byte offset in the input of the node that `segments` names, or of the deepest node
    /// along it that exists (the root is offset 0). A keyed node is placed at its key, an
    /// array element at its first byte, a `[[array]]` element at its header key. A `.none`
    /// segment stays where it is. Used to put a reflect failure on a line:col.
    pub fn offset_of_path(scratch: *const Scratch, segments: []const Segment) u32 {
        assert(segments.len <= core.value.nesting_max);
        var current: u32 = root_index;
        for (segments) |segment| {
            const next: ?u32 = switch (segment) {
                .none => current,
                .key => |name| scratch.find(current, name),
                .index => |position| scratch.child_at(current, position),
            };
            current = next orelse break;
        }
        const offset = scratch.nodes[current].offset;
        assert(current < scratch.node_count);
        return offset;
    }

    /// The `position`-th element of an array node (`array_static` or `array_tables`), or null
    /// when `array` is not an array or `position` is past its end.
    fn child_at(scratch: *const Scratch, array: u32, position: u64) ?u32 {
        assert(array < scratch.node_count);
        switch (scratch.nodes[array].state) {
            .array_static, .array_tables => {},
            .implicit, .header, .dotted, .inline_table, .scalar => return null,
        }
        if (position >= scratch.nodes[array].child_count) return null;
        var child = scratch.nodes[array].first_child;
        for (0..@as(usize, @intCast(position))) |_| child = scratch.nodes[child].next_sibling;
        assert(child < scratch.node_count);
        return child;
    }

    /// `[a.b]` / `[[a.b]]`, a segment that is not the last: returns the table to continue in.
    /// An `[[array]]` continues in its newest element.
    pub fn header_pass(scratch: *Scratch, parent: u32, key: Key) Error!u32 {
        assert(parent < scratch.node_count);
        assert(scratch.nodes[parent].state != .scalar);
        const found = scratch.find(parent, key.bytes) orelse {
            return scratch.add_keyed(parent, key, .implicit);
        };
        switch (scratch.nodes[found].state) {
            .implicit, .header, .dotted => return found,
            .array_tables => {
                const element = scratch.nodes[found].last_child;
                assert(element != none);
                assert(scratch.nodes[element].state == .header);
                return element;
            },
            .inline_table => return scratch.conflict(error.TableRedefined, found),
            .array_static, .scalar => return scratch.conflict(error.TypeConflict, found),
        }
    }

    /// The last segment of `[a.b]` (`array == false`) or `[[a.b]]` (`array == true`): returns
    /// the table that the section's keys go into.
    pub fn header_end(scratch: *Scratch, parent: u32, key: Key, array: bool) Error!u32 {
        assert(parent < scratch.node_count);
        assert(scratch.nodes[parent].state != .scalar);
        const found = scratch.find(parent, key.bytes) orelse {
            if (!array) return scratch.add_keyed(parent, key, .header);
            const list = try scratch.add_keyed(parent, key, .array_tables);
            return scratch.add_element(list, key.offset);
        };
        const state = scratch.nodes[found].state;
        if (array) {
            if (state != .array_tables) return scratch.conflict(error.TypeConflict, found);
            return scratch.add_element(found, key.offset);
        }
        switch (state) {
            .implicit => {
                // The one legal reopening: a table made on the way to a deeper header.
                scratch.nodes[found].state = .header;
                scratch.nodes[found].offset = key.offset;
                return found;
            },
            .header, .dotted, .inline_table => {
                return scratch.conflict(error.TableRedefined, found);
            },
            .array_static, .array_tables, .scalar => {
                return scratch.conflict(error.TypeConflict, found);
            },
        }
    }

    /// A non-last segment of the dotted key `a.b.c = v`, inside table `parent`: returns the
    /// table to continue in. Only tables made by dotted keys may be extended this way.
    pub fn dotted_pass(scratch: *Scratch, parent: u32, key: Key) Error!u32 {
        assert(parent < scratch.node_count);
        assert(scratch.nodes[parent].state != .scalar);
        const found = scratch.find(parent, key.bytes) orelse {
            return scratch.add_keyed(parent, key, .dotted);
        };
        switch (scratch.nodes[found].state) {
            .dotted => return found,
            .implicit, .header, .inline_table => {
                return scratch.conflict(error.TableRedefined, found);
            },
            .array_static, .array_tables, .scalar => {
                return scratch.conflict(error.TypeConflict, found);
            },
        }
    }

    /// `key = value` with a scalar value: `DuplicateKey` when `parent` already holds `key`.
    pub fn insert_scalar(scratch: *Scratch, parent: u32, key: Key, value: Value) Error!void {
        assert(value != .map);
        assert(value != .array);
        const index = try scratch.insert_keyed(parent, key, .scalar);
        scratch.nodes[index].value = value;
        assert(scratch.nodes[index].state == .scalar);
    }

    /// `key = ...` with an inline table or an array value: `state` is `.inline_table` or
    /// `.array_static`. Returns the new container; `DuplicateKey` when `key` is taken.
    pub fn insert_container(scratch: *Scratch, parent: u32, key: Key, state: State) Error!u32 {
        assert(state == .inline_table or state == .array_static);
        return scratch.insert_keyed(parent, key, state);
    }

    /// A scalar element of the array `array` (state `array_static`).
    pub fn append_scalar(scratch: *Scratch, array: u32, value: Value, offset: u32) Error!void {
        assert(value != .map);
        assert(value != .array);
        assert(scratch.nodes[array].state == .array_static);
        const index = try scratch.link(array, offset, .scalar);
        scratch.nodes[index].value = value;
        assert(scratch.nodes[index].state == .scalar);
    }

    /// An inline table or array element of the array `array`; `state` is `.inline_table` or
    /// `.array_static`. Returns the new container.
    pub fn append_container(scratch: *Scratch, array: u32, state: State, offset: u32) Error!u32 {
        assert(state == .inline_table or state == .array_static);
        assert(scratch.nodes[array].state == .array_static);
        return scratch.link(array, offset, state);
    }

    fn insert_keyed(scratch: *Scratch, parent: u32, key: Key, state: State) Error!u32 {
        assert(parent < scratch.node_count);
        assert(scratch.nodes[parent].state != .scalar);
        if (scratch.find(parent, key.bytes)) |found| {
            return scratch.conflict(error.DuplicateKey, found);
        }
        return scratch.add_keyed(parent, key, state);
    }

    fn conflict(scratch: *Scratch, err: Error, found: u32) Error {
        assert(found < scratch.node_count);
        scratch.conflict_offset = scratch.nodes[found].offset;
        return err;
    }

    fn find(scratch: *const Scratch, parent: u32, key: []const u8) ?u32 {
        const mask = scratch.slots.len - 1;
        var slot = slot_start(parent, key) & mask;
        for (0..scratch.slots.len) |_| {
            const index = scratch.slots[slot];
            if (index == none) return null;
            const node = &scratch.nodes[index];
            if (node.parent == parent and std.mem.eql(u8, node.key, key)) return index;
            slot = (slot + 1) & mask;
        }
        unreachable; // proof: load factor is at most one half, so a probe reaches an empty slot.
    }

    fn add_keyed(scratch: *Scratch, parent: u32, key: Key, state: State) Error!u32 {
        assert(scratch.find(parent, key.bytes) == null);
        const index = try scratch.link(parent, key.offset, state);
        const node = &scratch.nodes[index];
        node.key = key.bytes;
        node.key_owned = key.owned;

        const mask = scratch.slots.len - 1;
        var slot = slot_start(parent, key.bytes) & mask;
        for (0..scratch.slots.len) |_| {
            if (scratch.slots[slot] == none) {
                scratch.slots[slot] = index;
                return index;
            }
            slot = (slot + 1) & mask;
        }
        unreachable; // proof: load factor is at most one half, so an empty slot exists.
    }

    /// A keyless child of an `[[array]]`: a `header` table.
    fn add_element(scratch: *Scratch, list: u32, offset: u32) Error!u32 {
        assert(scratch.nodes[list].state == .array_tables);
        return scratch.link(list, offset, .header);
    }

    /// Appends a fresh node to `parent`'s child list; checks depth and capacity.
    fn link(scratch: *Scratch, parent: u32, offset: u32, state: State) Error!u32 {
        assert(parent < scratch.node_count);
        assert(scratch.node_count <= scratch.nodes.len);
        const parent_depth = scratch.nodes[parent].depth;
        const depth: u16 = if (state == .scalar) parent_depth else parent_depth + 1;
        if (depth > scratch.depth_max) {
            scratch.conflict_offset = offset;
            return error.TooDeep;
        }
        const index = scratch.node_count;
        if (index == scratch.nodes.len) return error.OutOfMemory;
        scratch.nodes[index] = new_node("", offset, parent, state, depth);
        const owner = &scratch.nodes[parent];
        if (owner.last_child == none) {
            owner.first_child = index;
        } else {
            scratch.nodes[owner.last_child].next_sibling = index;
        }
        owner.last_child = index;
        owner.child_count += 1;
        scratch.node_count += 1;
        assert(owner.last_child == index);
        assert(scratch.nodes[index].parent == parent);
        return index;
    }

    /// Asserts the structure is sound: parents precede children, depths are in range, and
    /// every child count equals the length of its sibling list. O(nodes).
    pub fn check_invariants(scratch: *const Scratch) void {
        assert(scratch.node_count >= 1);
        assert(scratch.node_count <= scratch.nodes.len);
        assert(scratch.nodes[root_index].state == .header);
        for (scratch.nodes[0..scratch.node_count], 0..) |node, index| {
            assert(node.depth >= 1);
            assert(node.depth <= scratch.depth_max);
            if (index > 0) assert(node.parent < index);
            var walked: u32 = 0;
            var child = node.first_child;
            for (0..scratch.node_count) |_| {
                if (child == none) break;
                assert(scratch.nodes[child].parent == index);
                walked += 1;
                child = scratch.nodes[child].next_sibling;
            }
            assert(walked == node.child_count);
            if (node.state == .scalar) assert(node.child_count == 0);
        }
    }
};

fn new_node(key: []const u8, offset: u32, parent: u32, state: State, depth: u16) Node {
    return .{
        .key = key,
        .value = .null,
        .parent = parent,
        .first_child = none,
        .last_child = none,
        .next_sibling = none,
        .child_count = 0,
        .offset = offset,
        .depth = depth,
        .state = state,
        .key_owned = false,
    };
}

fn slot_start(parent: u32, key: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(parent, key));
}

// Zero-length buffers for the half of a `Frame` its kind does not use; nothing can write them.
var empty_entries: [0]Map.Entry = .{};
var empty_values: [0]Value = .{};

const Frame = struct {
    node: u32,
    cursor: u32,
    map: Map,
    items: []Value,
    filled: u32,
    is_map: bool,
};

/// Copies the scratch tree into `tree` and returns the root table. Each table becomes a `Map`
/// of exactly its child count, each array a slice of exactly its length, in document order.
/// Iterative: an explicit stack of at most `depth_max` frames, which the depth check in
/// `link` bounds. Allocates only from the tree arena.
pub fn materialize(scratch: *const Scratch, tree: *ValueTree) error{OutOfMemory}!Value {
    assert(scratch.node_count >= 1);
    var stack: [core.value.nesting_max]Frame = undefined;
    stack[0] = try open_frame(scratch, tree, root_index);
    var depth: u32 = 1;
    for (0..@as(usize, scratch.node_count) * 2 + 2) |_| {
        const top = &stack[depth - 1];
        if (top.cursor == none) {
            const finished = top.node;
            const value = close_frame(top);
            depth -= 1;
            if (depth == 0) return value;
            try deliver(scratch, tree, &stack[depth - 1], finished, value);
            continue;
        }
        const child = top.cursor;
        top.cursor = scratch.nodes[child].next_sibling;
        if (scratch.nodes[child].state == .scalar) {
            try deliver(scratch, tree, top, child, scratch.nodes[child].value);
        } else {
            assert(depth < stack.len);
            stack[depth] = try open_frame(scratch, tree, child);
            depth += 1;
        }
    }
    unreachable; // proof: each iteration visits a child or closes a frame; 2 * nodes bound both.
}

fn open_frame(scratch: *const Scratch, tree: *ValueTree, index: u32) error{OutOfMemory}!Frame {
    const node = &scratch.nodes[index];
    const count = node.child_count;
    const is_map = switch (node.state) {
        .implicit, .header, .dotted, .inline_table => true,
        .array_static, .array_tables => false,
        .scalar => unreachable, // proof: materialize delivers scalars without opening a frame.
    };
    var frame: Frame = .{
        .node = index,
        .cursor = node.first_child,
        .map = Map.init(&empty_entries),
        .items = &empty_values,
        .filled = 0,
        .is_map = is_map,
    };
    if (is_map) {
        frame.map = try tree.new_map(count);
    } else {
        frame.items = try tree.arena.allocator().alloc(Value, count);
    }
    if (is_map) assert(frame.items.len == 0);
    if (!is_map) assert(frame.map.entries.len == 0);
    return frame;
}

fn close_frame(frame: *const Frame) Value {
    if (frame.is_map) {
        assert(frame.map.count == frame.map.entries.len);
        return .{ .map = frame.map };
    }
    assert(frame.filled == frame.items.len);
    return .{ .array = frame.items };
}

/// Stores a finished child into its parent frame. A map entry is written directly rather than
/// through `Map.put`: the hash index already proved the keys unique, and `put`'s duplicate
/// scan is linear, which would make a large table quadratic.
fn deliver(
    scratch: *const Scratch,
    tree: *ValueTree,
    frame: *Frame,
    child: u32,
    value: Value,
) error{OutOfMemory}!void {
    const node = &scratch.nodes[child];
    if (frame.is_map) {
        assert(frame.map.count < frame.map.entries.len);
        const key = if (node.key_owned) node.key else try tree.dupe_key(node.key);
        frame.map.entries[frame.map.count] = .{ .key = key, .value = value };
        frame.map.count += 1;
    } else {
        assert(frame.filled < frame.items.len);
        frame.items[frame.filled] = value;
        frame.filled += 1;
    }
}

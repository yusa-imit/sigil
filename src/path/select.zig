//! path/select — JSONPath evaluation of a compiled `Program` over a `Value` (ADR 0004 section 6).
//!
//! `select` walks the document depth first with an explicit stack of `nesting_max` frames, one
//! per open container, so there is no recursion and a hostile document cannot overflow the
//! machine stack. A child segment applies its selectors to the children of one node; a
//! descendant segment (`..`) applies them to the node, then to each container child's own
//! descendants, in pre-order. Results are appended to the caller's `out` in document order
//! with duplicates kept (`$[0,0]` yields two); depth-first order equals the RFC 9535 section
//! 2.5 order because each segment maps one node to a list and the lists are concatenated.
//!
//! Invariants: every returned pointer aims into the `root` tree (array items and map entry
//! values), so results live as long as it does; scalar nodes never get a frame (a selector on a
//! scalar selects nothing); a frame exists only for a container, so the stack depth is at most
//! the container nesting of the visited path. Allocation: none; the stack is local, `out` is
//! the caller's. Cost: O(nodes visited x selectors); `$..*` visits each node once.

const std = @import("std");
const core = @import("../core.zig");
const jsonpath = @import("jsonpath.zig");
const assert = std.debug.assert;
const Program = jsonpath.Program;
const Selector = jsonpath.Selector;
const Slice = jsonpath.Slice;
const Value = core.Value;

const nesting_max = core.value.nesting_max;

pub const SelectError = error{ OutOfSpace, TooDeep };

/// Appends the nodes `program` selects from `root` to `out` in document order and returns the
/// filled prefix. An empty result is `out[0..0]`, never an error. `OutOfSpace` when a result
/// does not fit (`out` is then unspecified); `TooDeep` when the walk needs a frame for a
/// container nested more than `nesting_max` deep (a parser never builds such a tree, a
/// hand-built `Value` may). The results borrow from `root`'s tree. A program with no segments
/// (`$`) yields `root` itself, in `out[0]`.
pub fn select(
    program: *const Program,
    root: *const Value,
    out: []*const Value,
) SelectError![]*const Value {
    assert(program.segments_count <= jsonpath.segments_max);
    assert(program.segments_count == 0 or program.selectors_count >= 1);
    var found: u32 = 0;
    if (program.segments_count == 0) {
        try emit(out, &found, root);
        return out[0..found];
    }
    if (!is_container(root)) return out[0..0];

    var frames: [nesting_max]Frame = undefined;
    frames[0] = Frame.init(root, 0);
    var depth: u32 = 1;
    while (depth > 0) {
        assert(depth <= nesting_max);
        const top = &frames[depth - 1];
        const step = advance(top, program) orelse {
            depth -= 1;
            continue;
        };
        const next_segment = if (step.same_segment) top.segment else top.segment + 1;
        if (next_segment == program.segments_count) {
            assert(!step.same_segment);
            try emit(out, &found, step.child);
        } else if (is_container(step.child)) {
            if (depth == nesting_max) return error.TooDeep;
            frames[depth] = Frame.init(step.child, next_segment);
            depth += 1;
        }
    }
    assert(found <= out.len);
    return out[0..found];
}

/// One open container and how far its segment has progressed.
const Frame = struct {
    node: *const Value,
    segment: u32,
    /// Index of the selector being applied; `selectors_count` is the descendant child walk.
    selector: u32,
    /// True until the current selector has produced anything; slices compute bounds then.
    fresh: bool,
    /// Next child index (wildcard, descendant walk) or next slice index.
    position: i64,
    /// Slice stop: exclusive upper for a positive step, exclusive lower for a negative one.
    stop: i64,

    fn init(node: *const Value, segment: u32) Frame {
        assert(is_container(node));
        return .{
            .node = node,
            .segment = segment,
            .selector = 0,
            .fresh = true,
            .position = 0,
            .stop = 0,
        };
    }
};

/// A child to visit: with `same_segment` the child's own descendants are walked by the same
/// (descendant) segment, otherwise it is a result of this segment and feeds the next one.
const Step = struct { child: *const Value, same_segment: bool };

fn advance(frame: *Frame, program: *const Program) ?Step {
    const segment = program.segment_list()[frame.segment];
    const selectors = program.selector_list(segment);
    assert(frame.selector <= selectors.len);
    for (0..selectors.len + 1) |_| {
        if (frame.selector == selectors.len) {
            if (!segment.descendant) return null;
            const child = next_container_child(frame) orelse return null;
            return .{ .child = child, .same_segment = true };
        }
        if (next_selected(frame, selectors[frame.selector], program)) |child| {
            return .{ .child = child, .same_segment = false };
        }
        frame.selector += 1;
        frame.fresh = true;
        frame.position = 0;
    }
    // proof: each pass either returns or moves the selector index forward, and the last of the
    // selectors.len + 1 passes sees selector == len, which always returns.
    unreachable;
}

fn next_selected(frame: *Frame, selector: Selector, program: *const Program) ?*const Value {
    const node = frame.node;
    assert(is_container(node));
    // A slice position goes negative when a negative step passes index 0.
    if (selector != .slice) assert(frame.position >= 0);
    switch (selector) {
        .name => |name| {
            if (!frame.fresh) return null;
            frame.fresh = false;
            return switch (node.*) {
                .map => |*map| map.get(program.name_text(name)),
                else => null,
            };
        },
        .index => |index| {
            if (!frame.fresh) return null;
            frame.fresh = false;
            return switch (node.*) {
                .array => |items| index_item(items, index),
                else => null,
            };
        },
        .wildcard => {
            const child = child_at(node, frame.position) orelse return null;
            frame.position += 1;
            return child;
        },
        .slice => |slice| return next_slice(frame, slice),
    }
}

fn next_container_child(frame: *Frame) ?*const Value {
    assert(is_container(frame.node));
    assert(frame.position >= 0);
    while (child_at(frame.node, frame.position)) |child| {
        frame.position += 1;
        if (is_container(child)) return child;
    }
    assert(frame.position >= child_count(frame.node));
    return null;
}

fn next_slice(frame: *Frame, slice: Slice) ?*const Value {
    const items = switch (frame.node.*) {
        .array => |items| items,
        else => return null,
    };
    if (slice.step == 0) return null;
    const length: i64 = @intCast(items.len);
    if (frame.fresh) {
        frame.fresh = false;
        const bounds = slice_bounds(slice, length);
        frame.position = if (slice.step > 0) bounds.lower else bounds.upper;
        frame.stop = if (slice.step > 0) bounds.upper else bounds.lower;
    }
    const live = if (slice.step > 0) frame.position < frame.stop else frame.stop < frame.position;
    if (!live) return null;
    const index: usize = @intCast(frame.position);
    assert(index < items.len);
    frame.position += slice.step;
    return &items[index];
}

const Bounds = struct { lower: i64, upper: i64 };

/// RFC 9535 section 2.3.4.2.2 for a non-zero step: indices run over `[lower, upper)` for a
/// positive step and over `(lower, upper]` for a negative one, always inside `-1 .. length`.
fn slice_bounds(slice: Slice, length: i64) Bounds {
    assert(slice.step != 0);
    assert(length >= 0);
    const forward = slice.step > 0;
    const start = slice.start orelse if (forward) 0 else length - 1;
    const end = slice.end orelse if (forward) length else -length - 1;
    const start_norm = if (start >= 0) start else length + start;
    const end_norm = if (end >= 0) end else length + end;
    const bounds: Bounds = if (forward) .{
        .lower = @min(@max(start_norm, 0), length),
        .upper = @min(@max(end_norm, 0), length),
    } else .{
        .lower = @min(@max(end_norm, -1), length - 1),
        .upper = @min(@max(start_norm, -1), length - 1),
    };
    assert(bounds.lower >= -1);
    assert(bounds.lower <= length);
    assert(bounds.upper >= -1);
    assert(bounds.upper <= length);
    if (!forward) assert(bounds.upper <= length - 1);
    return bounds;
}

fn index_item(items: []const Value, index: i64) ?*const Value {
    const length: i64 = @intCast(items.len);
    assert(length >= 0);
    assert(@abs(index) <= jsonpath.integer_max);
    const resolved = if (index >= 0) index else length + index;
    if (resolved < 0 or resolved >= length) return null;
    return &items[@intCast(resolved)];
}

/// The number of members of a container, 0 for a scalar.
fn child_count(node: *const Value) i64 {
    return switch (node.*) {
        .array => |items| @intCast(items.len),
        .map => |*map| map.count,
        else => 0,
    };
}

fn child_at(node: *const Value, position: i64) ?*const Value {
    assert(position >= 0);
    assert(position <= std.math.maxInt(u32));
    const index: usize = @intCast(position);
    switch (node.*) {
        .array => |items| return if (index < items.len) &items[index] else null,
        .map => |*map| {
            const entries = map.items();
            return if (index < entries.len) &entries[index].value else null;
        },
        else => return null,
    }
}

fn emit(out: []*const Value, found: *u32, node: *const Value) SelectError!void {
    assert(found.* <= out.len);
    if (found.* == out.len) return error.OutOfSpace;
    out[found.*] = node;
    found.* += 1;
}

fn is_container(node: *const Value) bool {
    assert(@intFromPtr(node) != 0);
    return switch (node.*) {
        .array, .map => true,
        else => false,
    };
}

test {
    _ = @import("select_test.zig");
}

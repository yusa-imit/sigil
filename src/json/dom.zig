//! json/dom — bytes into a `Value` owned by a `ValueTree` (ADR 0003 section 4).
//!
//! Two passes over one complete slice, no recursion. Pass 1 runs a `Scanner` over the whole
//! document and records each container's child count in container-begin order, so every syntax
//! error is reported before any node exists. Pass 2 runs a second `Scanner` over the same
//! bytes; it cannot fail on syntax, and it gives each container one allocation of exactly its
//! counted size. Both passes keep their open containers on a fixed `nesting_max` frame stack.
//!
//! Numbers go through `core.number.parse_decimal`, so `i64`, `u64` and `f64` stay distinct and
//! range errors are typed. Strings and keys are copied and decoded into the tree, never
//! borrowed from `input`: the result has one lifetime, the tree.
//!
//! Allocation: everything comes from `tree.arena`, and nothing is freed before `deinit`. The
//! counting array is 4 bytes per bracket byte and is shrunk in place to the real container
//! count when the arena allows. Arena bytes are at most the sum of string and key raw lengths,
//! plus 32 per array element, 48 per object member and 4 per container, plus block overhead.
//! A duplicate key under `.last` leaves the replaced subtree in the arena, bounded by the input.
//! Cost: two scans, and O(n^2) key compares per object (`Map.index_of` per member).
//!
//! Every error return writes `diag` exactly once; success never does.

const std = @import("std");
const core = @import("../core.zig");
const scanner = @import("scanner.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Scanner = scanner.Scanner;
const Token = scanner.Token;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// What to do when an object repeats a key. The comparison is on decoded key bytes.
pub const DuplicateKeyPolicy = enum {
    /// `error.DuplicateKey` at the second key.
    reject,
    /// The last value, at the position of the first occurrence (as `JSON.parse`).
    last,
};

/// Every field is required: no defaults.
pub const ParseOptions = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
    duplicate_key: DuplicateKeyPolicy,
};

/// What building the tree adds to the scanner's errors.
pub const BuildError = core.number.Error || error{ DuplicateKey, OutOfMemory };

/// Every error `parse` can return (15 variants, ADR 0003 section 3).
pub const ParseValueError = scanner.ScanError || BuildError || error{InputTooLarge};

comptime {
    assert(@sizeOf(Value) == 32);
    assert(@sizeOf(Map.Entry) == 48);
    assert(@typeInfo(ParseValueError).error_set.?.len == 15);
}

/// Parses `input`, one complete JSON document, into `tree` and returns its root. The root is
/// not stored in `tree.root`, so one tree can hold several documents. Strings are copies; the
/// result lives until `tree.deinit()`, and `input` may be freed once this returns.
/// Preconditions: `tree` was initialized and `1 <= options.depth_max <= nesting_max`.
pub fn parse(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);

    // proof: `check_len` holds no I/O error, so `error.Canceled` cannot occur.
    _ = core.unicode.check_len(input.len) catch |err| switch (err) {
        error.InputTooLarge => return fail_input_too_large(diag),
    };
    const counts = try count_children(tree, input, options.depth_max, diag);
    return build(tree, input, options, counts, diag);
}

fn fail_input_too_large(diag: *Diagnostics) ParseValueError {
    const none = core.diagnostics.position_none;
    diag.* = Diagnostics.init(none, none, "input is too large", null);
    return error.InputTooLarge;
}

/// Writes `diag` for a tree-building failure at `offset` and returns `err`.
/// Precondition: `offset <= input.len <= maxInt(u32)`.
fn fail_build(diag: *Diagnostics, input: []const u8, offset: u32, err: BuildError) BuildError {
    assert(input.len <= std.math.maxInt(u32));
    assert(offset <= input.len);
    const position = core.diagnostics.position_of(input, offset);
    const snippet = core.diagnostics.snippet_of(input, offset);
    // proof: `BuildError` holds no I/O error, so `error.Canceled` cannot occur.
    const message = switch (err) {
        error.IntegerAboveMax => "integer is above the largest u64",
        error.IntegerBelowMin => "integer is below the smallest i64",
        error.FloatOutOfRange => "number is too large for a 64-bit float",
        error.DuplicateKey => "duplicate object key",
        error.OutOfMemory => "out of memory",
    };
    diag.* = Diagnostics.init(position.line, position.col, message, snippet);
    return err;
}

/// One open container of pass 1.
const Open = struct { ordinal: u32, is_object: bool };

/// Pass 1 state: child counts by container ordinal, and the open containers.
const Counter = struct {
    counts: []u32,
    open: [core.value.nesting_max]Open,
    depth: u32,
    ordinal: u32,

    fn observe(counter: *Counter, token: Token) void {
        assert(counter.depth <= counter.open.len);
        switch (token.kind) {
            .object_begin, .array_begin => {
                counter.add_value();
                counter.begin(token.kind == .object_begin);
            },
            .object_end, .array_end => {
                assert(counter.depth > 0);
                counter.depth -= 1;
            },
            .key => counter.add_child(),
            .string, .number, .literal_true, .literal_false, .literal_null => counter.add_value(),
            .end => unreachable, // proof: the caller returns on `.end` before observing it.
        }
    }

    fn begin(counter: *Counter, is_object: bool) void {
        assert(counter.depth < counter.open.len);
        assert(counter.ordinal < counter.counts.len);
        counter.open[counter.depth] = .{ .ordinal = counter.ordinal, .is_object = is_object };
        counter.depth += 1;
        counter.ordinal += 1;
    }

    /// A value counts as a child of an array parent; an object counts its keys instead.
    fn add_value(counter: *Counter) void {
        if (counter.depth == 0) return;
        if (counter.open[counter.depth - 1].is_object) return;
        counter.add_child();
    }

    fn add_child(counter: *Counter) void {
        assert(counter.depth > 0);
        const ordinal = counter.open[counter.depth - 1].ordinal;
        assert(ordinal < counter.counts.len);
        counter.counts[ordinal] += 1;
    }
};

/// Pass 1. Validates the whole document and returns the child count of every container, in
/// container-begin order. The slice is the newest arena allocation, shrunk in place if possible.
fn count_children(
    tree: *ValueTree,
    input: []const u8,
    depth_max: u16,
    diag: *Diagnostics,
) ParseValueError![]const u32 {
    var bound: usize = 0;
    for (input) |byte| bound += @intFromBool(byte == '[' or byte == '{');

    const arena = tree.arena.allocator();
    // proof: `alloc` holds no I/O error, so `error.Canceled` cannot occur.
    const counts = arena.alloc(u32, bound) catch |err| switch (err) {
        error.OutOfMemory => return fail_build(diag, input, 0, error.OutOfMemory),
    };
    @memset(counts, 0);

    var counter: Counter = .{
        .counts = counts,
        .open = @splat(.{ .ordinal = 0, .is_object = false }),
        .depth = 0,
        .ordinal = 0,
    };
    var scan: Scanner = undefined;
    // proof: `parse` ran `check_len` on this input, the only way `init` can fail.
    scan.init(input, .{ .depth_max = depth_max }) catch unreachable;
    for (0..input.len + 1) |_| {
        const token = try scan.next(diag);
        if (token.kind == .end) {
            assert(counter.depth == 0);
            assert(counter.ordinal <= counts.len);
            _ = arena.resize(counts, counter.ordinal);
            return counts[0..counter.ordinal];
        }
        counter.observe(token);
    }
    unreachable; // proof: every token but `.end` consumes a byte, so `.end` ends the loop.
}

/// One open container of pass 2.
const Frame = struct {
    array: []Value,
    map: Map,
    is_object: bool,
    /// Elements written to `array`.
    fill: u32,
    /// The key of the member being built, once seen.
    key: []const u8,
    /// Where `key` already lives in `map`, under `.last`.
    slot: ?u32,
};

const frame_empty: Frame = .{
    .array = &.{},
    .map = .{ .entries = &.{}, .count = 0 },
    .is_object = false,
    .fill = 0,
    .key = "",
    .slot = null,
};

/// Pass 2 state: the open containers, the next container ordinal, and the finished root.
const Builder = struct {
    arena: Allocator,
    tree: *ValueTree,
    counts: []const u32,
    policy: DuplicateKeyPolicy,
    frames: [core.value.nesting_max]Frame,
    depth: u32,
    ordinal: u32,
    root: Value,

    fn accept(builder: *Builder, token: Token) BuildError!void {
        assert(builder.depth <= builder.frames.len);
        switch (token.kind) {
            .object_begin => try builder.open(true),
            .array_begin => try builder.open(false),
            .object_end, .array_end => builder.attach(builder.close()),
            .key => try builder.take_key(token),
            .string => builder.attach(.{ .string = try builder.make_text(token) }),
            .number => builder.attach(try core.number.parse_decimal(token.raw)),
            .literal_true => builder.attach(.{ .bool = true }),
            .literal_false => builder.attach(.{ .bool = false }),
            .literal_null => builder.attach(.null),
            .end => unreachable, // proof: the caller returns on `.end` before accepting it.
        }
    }

    fn open(builder: *Builder, is_object: bool) BuildError!void {
        assert(builder.depth < builder.frames.len);
        assert(builder.ordinal < builder.counts.len);
        const size = builder.counts[builder.ordinal];
        var frame = frame_empty;
        frame.is_object = is_object;
        if (is_object) {
            frame.map = try builder.tree.new_map(size);
        } else {
            frame.array = try builder.arena.alloc(Value, size);
        }
        builder.frames[builder.depth] = frame;
        builder.depth += 1;
        builder.ordinal += 1;
    }

    fn close(builder: *Builder) Value {
        assert(builder.depth > 0);
        builder.depth -= 1;
        const frame = &builder.frames[builder.depth];
        if (frame.is_object) {
            assert(frame.map.count <= frame.map.entries.len);
            return .{ .map = frame.map };
        }
        assert(frame.fill == frame.array.len);
        return .{ .array = frame.array };
    }

    /// Records the key of the next member. Under `.reject` a repeated key fails here, before
    /// the value after it is read.
    fn take_key(builder: *Builder, token: Token) BuildError!void {
        assert(builder.depth > 0);
        const frame = &builder.frames[builder.depth - 1];
        assert(frame.is_object);
        const key = try builder.make_text(token);
        const slot = frame.map.index_of(key);
        if (slot != null and builder.policy == .reject) return error.DuplicateKey;
        frame.key = key;
        frame.slot = slot;
    }

    /// Stores a finished value in the open container, or as the root at depth zero.
    fn attach(builder: *Builder, value: Value) void {
        if (builder.depth == 0) {
            builder.root = value;
            return;
        }
        const frame = &builder.frames[builder.depth - 1];
        if (!frame.is_object) {
            assert(frame.fill < frame.array.len);
            frame.array[frame.fill] = value;
            frame.fill += 1;
            return;
        }
        if (frame.slot) |slot| {
            assert(slot < frame.map.count);
            frame.map.entries[slot].value = value;
            frame.slot = null;
            return;
        }
        // proof: `take_key` found the key absent and pass 1 sized the map by its key tokens.
        frame.map.put(frame.key, value) catch unreachable;
    }

    /// A decoded copy of a `.key`/`.string` token, in the arena.
    fn make_text(builder: *Builder, token: Token) BuildError![]const u8 {
        assert(token.kind == .key or token.kind == .string);
        const out = try builder.arena.alloc(u8, token.raw.len);
        if (!token.has_escapes) {
            @memcpy(out, token.raw);
            return out;
        }
        const decoded = scanner.decode_string(token.raw, out);
        assert(decoded.len > 0);
        assert(decoded.len <= out.len);
        _ = builder.arena.resize(out, decoded.len);
        return out[0..decoded.len];
    }
};

/// Pass 2. Builds the tree from tokens pass 1 already accepted.
fn build(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    counts: []const u32,
    diag: *Diagnostics,
) ParseValueError!Value {
    var builder: Builder = .{
        .arena = tree.arena.allocator(),
        .tree = tree,
        .counts = counts,
        .policy = options.duplicate_key,
        .frames = @splat(frame_empty),
        .depth = 0,
        .ordinal = 0,
        .root = .null,
    };
    var scan: Scanner = undefined;
    // proof: `parse` ran `check_len` on this input, the only way `init` can fail.
    scan.init(input, .{ .depth_max = options.depth_max }) catch unreachable;
    for (0..input.len + 1) |_| {
        // proof: pass 1 accepted these exact bytes with the same options.
        const token = scan.next(diag) catch unreachable;
        if (token.kind == .end) {
            assert(builder.depth == 0);
            assert(builder.ordinal == counts.len);
            return builder.root;
        }
        builder.accept(token) catch |err| return fail_build(diag, input, token.offset, err);
    }
    unreachable; // proof: every token but `.end` consumes a byte, so `.end` ends the loop.
}

test {
    _ = @import("dom_test.zig");
}

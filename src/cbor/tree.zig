//! cbor/tree — builds a `Value` from the pull reader's tokens (ADR 0006 sections 2-5, 8, 9).
//! `cbor/decoder.zig` re-exports `parse_value`, `ParseOptions` and the error sets.
//!
//! `parse_value` scans the input twice with the same `Reader`. Pass 1 (counting) validates the
//! whole grammar, UTF-8, depth and the bomb rule, and records for every indefinite item, in
//! open order, its child count (a map: its pair count) or, for a string, its total payload
//! length; those are the only sizes the wire does not state up front. Pass 2 (building) then
//! allocates each array, map and string once at its final size from the tree arena, so no
//! container grows. The counts array holds at most one `u32` per byte of `5f 7f 9f bf` in the
//! input, so it is bounded by four times the input size; the unused tail stays in the arena.
//!
//! Open containers sit on a fixed `[nesting_max]Frame` stack. Map keys must be text, definite or
//! indefinite (`NonStringKey`); a repeated key follows `core.DuplicateKeyPolicy`. Tags 0-3 are
//! decoded (ADR 0006 section 4): tag 0 text through `core.timestamp.parse`, tag 1 an integer or a
//! float, tags 2 and 3 a byte string of at most 64 significant bits; any other tag is
//! `UnsupportedTag` at its head, and a tag over the wrong content is `InvalidTimestamp` (0, 1) or
//! `InvalidTag` (2, 3) at the tag's head. Simple values other than false, true and null are
//! `UnsupportedSimple`. Bytes after the one item are `TrailingBytes`.
//!
//! Invariants: nothing is allocated before the declared sizes passed the bomb rule in pass 1, so
//! arena bytes are linear in the input; strings, byte strings and keys are copies, so the result
//! lives until `tree.deinit()` and `input` may be freed once `parse_value` returns. Positions: a
//! failure writes `diag` once, line 1, col = offset + 1, message "byte N: reason".

const std = @import("std");
const core = @import("../core.zig");
const decoder = @import("decoder.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

const Reader = decoder.Reader;
const ScanError = decoder.ScanError;
const Token = decoder.Token;

/// Every field is required: no defaults.
pub const ParseOptions = struct {
    /// Containers and tags may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
    /// Input longer than this is `error.InputTooLarge`, before any byte is read; at most
    /// `Reader.input_len_max`.
    bytes_max: u32,
    duplicate_key: core.DuplicateKeyPolicy,
};

/// What building the tree adds to the reader's errors.
pub const BuildError = error{
    NonStringKey,
    DuplicateKey,
    UnsupportedTag,
    UnsupportedSimple,
    InvalidTimestamp,
    InvalidTag,
    IntegerAboveMax,
    IntegerBelowMin,
    TrailingBytes,
    OutOfMemory,
};

/// Every error `parse_value` can return (17 variants, ADR 0006 section 8).
pub const ParseValueError = ScanError || BuildError || error{InputTooLarge};

comptime {
    assert(@sizeOf(Value) == 32);
    assert(@sizeOf(Map.Entry) == 48);
    assert(@typeInfo(ParseValueError).error_set.?.len == 17);
}

/// Parses `input`, exactly one CBOR item, into `tree` and returns its root. The root is not
/// stored in `tree.root`, so one tree can hold several documents. Strings, byte strings and keys
/// are copies; the result lives until `tree.deinit()` and `input` may be freed once this
/// returns. Every error writes `diag` once (`byte N: reason`); success never does.
/// Preconditions: `tree` was initialized, `1 <= options.depth_max <= nesting_max` and
/// `options.bytes_max <= Reader.input_len_max`.
pub fn parse_value(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    assert(options.bytes_max <= Reader.input_len_max);

    if (input.len > options.bytes_max) {
        const none = core.diagnostics.position_none;
        diag.* = Diagnostics.init(none, none, "input is too large", null);
        return error.InputTooLarge;
    }
    const bound = indefinite_bound(input);
    const counts = tree.arena.allocator().alloc(u32, bound) catch
        return fail_build(diag, 0, error.OutOfMemory);
    const used = try count_pass(input, options.depth_max, counts, diag);
    assert(used <= counts.len);
    return build_pass(tree, input, options, counts[0..used], diag);
}

/// How many indefinite items `input` can hold: the bytes `5f 7f 9f bf`. A payload byte of that
/// value only over-counts, so the result is an upper bound of the ordinals pass 1 hands out.
fn indefinite_bound(input: []const u8) u32 {
    assert(input.len <= Reader.input_len_max);
    var bound: u32 = 0;
    for (input) |byte| {
        switch (byte) {
            0x5f, 0x7f, 0x9f, 0xbf => bound += 1,
            else => {},
        }
    }
    assert(bound <= input.len);
    return bound;
}

/// What `fail_build` reports: the build errors and the one the reader cannot see (empty input).
const FailError = BuildError || error{UnexpectedEnd};

/// Writes `diag` for a tree-level failure at `offset` and returns `err`.
fn fail_build(diag: *Diagnostics, offset: u32, err: FailError) FailError {
    assert(offset <= Reader.input_len_max);
    // proof: the set holds no I/O error, so `error.Canceled` cannot occur.
    const reason = switch (err) {
        error.UnexpectedEnd => "unexpected end of input",
        error.NonStringKey => "map key is not a text string",
        error.DuplicateKey => "duplicate map key",
        error.UnsupportedTag => "unsupported tag",
        error.UnsupportedSimple => "unsupported simple value",
        error.InvalidTimestamp => "invalid timestamp",
        error.InvalidTag => "invalid tag content",
        error.IntegerAboveMax => "integer above maximum",
        error.IntegerBelowMin => "integer below minimum",
        error.TrailingBytes => "trailing bytes after the item",
        error.OutOfMemory => "out of memory",
    };
    decoder.set_diag(diag, offset, reason);
    return err;
}

// ---- Pass 1: grammar, limits and the sizes of indefinite items. ----

/// One open container as pass 1 sees it.
const CountFrame = struct {
    kind: enum(u8) { definite, indef_array, indef_map },
    /// Index into `counts` of an indefinite container; unused for a definite one.
    ordinal: u32,
    /// Items still due (a definite container; a map counts keys and values).
    left: u32,
    /// Items completed so far (a map counts keys and values).
    children: u32,
};

const count_frame_empty: CountFrame = .{
    .kind = .definite,
    .ordinal = 0,
    .left = 0,
    .children = 0,
};

/// Pass 1 state: the stack of open containers and the ordinal of the open indefinite string.
const Counter = struct {
    counts: []u32,
    used: u32,
    frames: [core.value.nesting_max]CountFrame,
    depth: u32,
    /// Ordinal of the indefinite string being read; its chunks add to `counts[ordinal]`.
    string: ?u32,
    /// The root item is complete.
    done: bool,

    fn accept(counter: *Counter, token: Token) void {
        assert(counter.depth <= counter.frames.len);
        assert(!counter.done);
        switch (token.item) {
            .tag => {},
            .null, .bool, .int, .uint, .float, .simple => counter.complete(),
            .text, .bytes => |data| {
                if (counter.string) |ordinal| {
                    counter.counts[ordinal] += @intCast(data.len);
                } else {
                    counter.complete();
                }
            },
            .array => |count| counter.open_definite(count),
            .map => |count| counter.open_definite(2 * count),
            .array_indef => counter.open_indefinite(.indef_array),
            .map_indef => counter.open_indefinite(.indef_map),
            .bytes_indef, .text_indef => counter.string = counter.take_ordinal(),
            .stop => counter.close(),
            .end => unreachable, // proof: `count_pass` returns on `.end` before accepting it.
        }
    }

    fn take_ordinal(counter: *Counter) u32 {
        assert(counter.used < counter.counts.len);
        const ordinal = counter.used;
        counter.used += 1;
        counter.counts[ordinal] = 0;
        return ordinal;
    }

    /// `items` is the number of child items due (`2 * entries` for a map); zero completes now.
    fn open_definite(counter: *Counter, items: u32) void {
        if (items == 0) return counter.complete();
        assert(counter.depth < counter.frames.len);
        counter.frames[counter.depth] = .{
            .kind = .definite,
            .ordinal = 0,
            .left = items,
            .children = 0,
        };
        counter.depth += 1;
    }

    fn open_indefinite(counter: *Counter, kind: @FieldType(CountFrame, "kind")) void {
        assert(kind != .definite);
        assert(counter.depth < counter.frames.len);
        counter.frames[counter.depth] = .{
            .kind = kind,
            .ordinal = counter.take_ordinal(),
            .left = 0,
            .children = 0,
        };
        counter.depth += 1;
    }

    /// A `stop`: the end of the open indefinite string, else of the innermost indefinite
    /// container, whose size is recorded.
    fn close(counter: *Counter) void {
        if (counter.string != null) {
            counter.string = null;
            return counter.complete();
        }
        assert(counter.depth > 0);
        const frame = counter.frames[counter.depth - 1];
        assert(frame.kind != .definite);
        counter.counts[frame.ordinal] = switch (frame.kind) {
            .indef_map => @divExact(frame.children, 2),
            .indef_array => frame.children,
            .definite => unreachable, // proof: asserted above.
        };
        counter.depth -= 1;
        counter.complete();
    }

    /// One whole item is done: it counts as a child of the open container, and a definite
    /// container that has received its last child is done in turn.
    fn complete(counter: *Counter) void {
        for (0..core.value.nesting_max + 1) |_| {
            if (counter.depth == 0) {
                counter.done = true;
                return;
            }
            const frame = &counter.frames[counter.depth - 1];
            frame.children += 1;
            if (frame.kind != .definite) return;
            assert(frame.left > 0);
            frame.left -= 1;
            if (frame.left != 0) return;
            counter.depth -= 1;
        }
        unreachable; // proof: each pass pops a frame and at most `nesting_max` are open.
    }
};

/// Reads the whole item once; returns how many `counts` entries it filled.
fn count_pass(
    input: []const u8,
    depth_max: u16,
    counts: []u32,
    diag: *Diagnostics,
) ParseValueError!u32 {
    var reader: Reader = undefined;
    // proof: `parse_value` checked `input.len <= bytes_max <= input_len_max`.
    reader.init(input, depth_max) catch unreachable;
    var counter: Counter = .{
        .counts = counts,
        .used = 0,
        .frames = @splat(count_frame_empty),
        .depth = 0,
        .string = null,
        .done = false,
    };
    for (0..input.len + 1) |_| {
        const token = try reader.next(diag);
        if (token.item == .end) {
            assert(input.len == 0);
            return fail_build(diag, 0, error.UnexpectedEnd);
        }
        counter.accept(token);
        if (!counter.done) continue;
        assert(counter.depth == 0);
        if (reader.offset < input.len) return fail_build(diag, reader.offset, error.TrailingBytes);
        return counter.used;
    }
    unreachable; // proof: every token but `.end` consumes a byte, so `.end` ends the loop.
}

// ---- Pass 2: the tree. ----

/// Container flavours the builder opens.
const Shape = enum {
    array,
    map,
    array_indef,
    map_indef,

    fn is_map(shape: Shape) bool {
        return shape == .map or shape == .map_indef;
    }

    fn is_indefinite(shape: Shape) bool {
        return shape == .array_indef or shape == .map_indef;
    }
};

/// One open container.
const Frame = struct {
    /// Offset of the container's head byte.
    head: u32,
    is_map: bool,
    /// Closed by a `stop` instead of by its last child.
    indef: bool,
    array: []Value,
    map: Map,
    /// Elements (array) or entries (map) still to be stored.
    left: u32,
    /// Elements written to `array`.
    fill: u32,
    /// The key of the entry being built, once seen.
    key: []const u8,
    /// Where `key` already lives in `map`, under `.last`.
    slot: ?u32,
    /// A key was read and its value is next.
    key_pending: bool,

    /// Stores the finished child: an array element, or the value of the pending key.
    fn store(frame: *Frame, value: Value) void {
        assert(frame.left > 0);
        if (frame.is_map) {
            assert(frame.key_pending);
            if (frame.slot) |slot| {
                assert(slot < frame.map.count);
                frame.map.entries[slot].value = value;
            } else {
                // proof: `set_key` found the key absent and the map holds one slot per entry.
                frame.map.put(frame.key, value) catch unreachable;
            }
            frame.key_pending = false;
            frame.slot = null;
        } else {
            assert(frame.fill < frame.array.len);
            frame.array[frame.fill] = value;
            frame.fill += 1;
        }
        frame.left -= 1;
    }

    /// The finished container as a `Value`.
    fn finished(frame: *const Frame) Value {
        assert(frame.left == 0);
        assert(!frame.key_pending);
        if (frame.is_map) {
            assert(frame.map.count <= frame.map.entries.len);
            return .{ .map = frame.map };
        }
        assert(frame.fill == frame.array.len);
        return .{ .array = frame.array };
    }
};

const frame_empty: Frame = .{
    .head = 0,
    .is_map = false,
    .indef = false,
    .array = &.{},
    .map = .{ .entries = &.{}, .count = 0 },
    .left = 0,
    .fill = 0,
    .key = "",
    .slot = null,
    .key_pending = false,
};

/// A tag waiting for its content item.
const Pending = struct { number: u8, head: u32 };

/// An indefinite string being assembled from its chunks.
const StringBuild = struct {
    buffer: []u8,
    fill: u32,
    head: u32,
    is_text: bool,
    as_key: bool,
};

/// Pass 2 state: open containers, the pending tag, the open string and the finished root.
const Builder = struct {
    tree: *ValueTree,
    counts: []const u32,
    next_ordinal: u32,
    depth_max: u32,
    policy: core.DuplicateKeyPolicy,
    frames: [core.value.nesting_max]Frame,
    depth: u32,
    pending: ?Pending,
    string: ?StringBuild,
    /// Where a failure is reported when it is not the current token's offset.
    blame: ?u32,
    root: Value,
    done: bool,

    fn accept(builder: *Builder, token: Token) BuildError!void {
        assert(builder.depth <= builder.depth_max);
        assert(!builder.done);
        builder.blame = null;
        if (builder.string != null) return builder.accept_chunk(token);
        if (token.item == .stop) return builder.close_indefinite();
        if (builder.key_due()) return builder.take_key(token);
        switch (token.item) {
            .tag => |number| try builder.begin_tag(number, token.offset),
            .null => try builder.leaf(.null),
            .bool => |flag| try builder.leaf(.{ .bool = flag }),
            .int => |number| try builder.leaf(.{ .int = number }),
            .uint => |number| try builder.leaf(.{ .uint = number }),
            .float => |number| try builder.leaf(.{ .float = number }),
            .simple => return error.UnsupportedSimple,
            .text => |text| try builder.leaf(try builder.tree.dupe_string(text)),
            .bytes => |data| try builder.leaf(try builder.tree.dupe_bytes(data)),
            .array => |count| try builder.open(token.offset, .array, count),
            .map => |count| try builder.open(token.offset, .map, count),
            .array_indef => try builder.open(token.offset, .array_indef, builder.take_count()),
            .map_indef => try builder.open(token.offset, .map_indef, builder.take_count()),
            .text_indef => try builder.begin_string(token.offset, true, false),
            .bytes_indef => try builder.begin_string(token.offset, false, false),
            .stop, .end => unreachable, // proof: `.stop` returned above, `.end` never arrives.
        }
    }

    /// The next entry of the pass 1 counts; ordinals follow token order in both passes.
    fn take_count(builder: *Builder) u32 {
        assert(builder.next_ordinal < builder.counts.len);
        const count = builder.counts[builder.next_ordinal];
        builder.next_ordinal += 1;
        return count;
    }

    /// The innermost open container is a map that waits for a key.
    fn key_due(builder: *const Builder) bool {
        if (builder.depth == 0) return false;
        const top = &builder.frames[builder.depth - 1];
        return top.is_map and !top.key_pending;
    }

    /// The token in key position: text, or the start of an indefinite text string.
    fn take_key(builder: *Builder, token: Token) BuildError!void {
        assert(builder.key_due());
        assert(builder.pending == null);
        switch (token.item) {
            .text => |text| try builder.set_key(text),
            .text_indef => try builder.begin_string(token.offset, true, true),
            else => return error.NonStringKey,
        }
    }

    /// Records the key of the next entry. Under `.reject` a repeated key fails here.
    fn set_key(builder: *Builder, text: []const u8) BuildError!void {
        assert(builder.key_due());
        const frame = &builder.frames[builder.depth - 1];
        const slot = frame.map.index_of(text);
        if (slot) |found| {
            if (builder.policy == .reject) return error.DuplicateKey;
            frame.key = frame.map.entries[found].key;
        } else {
            frame.key = try builder.tree.dupe_key(text);
        }
        frame.slot = slot;
        frame.key_pending = true;
    }

    /// Starts an indefinite string whose payload length is the next pass 1 count.
    fn begin_string(builder: *Builder, head: u32, is_text: bool, as_key: bool) BuildError!void {
        assert(builder.string == null);
        const length = builder.take_count();
        const buffer = try builder.tree.arena.allocator().alloc(u8, length);
        builder.string = .{
            .buffer = buffer,
            .fill = 0,
            .head = head,
            .is_text = is_text,
            .as_key = as_key,
        };
    }

    /// Inside an indefinite string: a chunk is copied, `stop` ends the string.
    fn accept_chunk(builder: *Builder, token: Token) BuildError!void {
        const open_string = &builder.string.?;
        switch (token.item) {
            .text, .bytes => |data| {
                assert(open_string.fill + data.len <= open_string.buffer.len);
                @memcpy(open_string.buffer[open_string.fill..][0..data.len], data);
                open_string.fill += @intCast(data.len);
            },
            .stop => {
                const done = open_string.*;
                builder.string = null;
                assert(done.fill == done.buffer.len);
                if (done.as_key) {
                    builder.blame = done.head;
                    return builder.set_key(done.buffer);
                }
                const value: Value = if (done.is_text)
                    .{ .string = done.buffer }
                else
                    .{ .bytes = done.buffer };
                try builder.leaf(value);
            },
            else => unreachable, // proof: the reader allows only chunks and `stop` here.
        }
    }

    /// A tag head; its content is the next item. Tags nest only to fail (content errors).
    fn begin_tag(builder: *Builder, number: u64, head: u32) BuildError!void {
        if (builder.pending) |outer| return builder.refuse_content(outer);
        if (number > 3) return error.UnsupportedTag;
        builder.pending = .{ .number = @intCast(number), .head = head };
    }

    /// A tag whose content is not a leaf of its kind: reported at the tag's head.
    fn refuse_content(builder: *Builder, tag: Pending) BuildError {
        assert(tag.number <= 3);
        builder.blame = tag.head;
        return if (tag.number <= 1) error.InvalidTimestamp else error.InvalidTag;
    }

    /// Attaches a finished leaf, converted first when a tag waits for it.
    fn leaf(builder: *Builder, value: Value) BuildError!void {
        const tag = builder.pending orelse return builder.finish(value);
        builder.pending = null;
        builder.blame = tag.head;
        builder.finish(try apply_tag(tag.number, value));
    }

    /// Pushes a container of `count` children. A definite one of size zero finishes at once;
    /// an indefinite one waits for its `stop`.
    fn open(builder: *Builder, head: u32, shape: Shape, count: u32) BuildError!void {
        assert(builder.depth <= builder.depth_max);
        assert(builder.depth < builder.frames.len);
        if (builder.pending) |tag| return builder.refuse_content(tag);
        var frame = frame_empty;
        frame.head = head;
        frame.is_map = shape.is_map();
        frame.indef = shape.is_indefinite();
        frame.left = count;
        if (frame.is_map) {
            frame.map = try builder.tree.new_map(count);
        } else {
            frame.array = try builder.tree.arena.allocator().alloc(Value, count);
        }
        if (count == 0 and !frame.indef) return builder.finish(frame.finished());
        builder.frames[builder.depth] = frame;
        builder.depth += 1;
    }

    /// A `stop` that ends the innermost indefinite container.
    fn close_indefinite(builder: *Builder) BuildError!void {
        assert(builder.depth > 0);
        assert(builder.pending == null);
        const frame = builder.frames[builder.depth - 1];
        assert(frame.indef);
        builder.depth -= 1;
        builder.finish(frame.finished());
    }

    /// Attaches a finished value to its parent, closing every definite parent that becomes full.
    fn finish(builder: *Builder, value: Value) void {
        var current = value;
        for (0..builder.frames.len + 1) |_| {
            if (builder.depth == 0) {
                builder.root = current;
                builder.done = true;
                return;
            }
            const frame = &builder.frames[builder.depth - 1];
            frame.store(current);
            if (frame.left > 0 or frame.indef) return;
            current = frame.finished();
            builder.depth -= 1;
        }
        unreachable; // proof: each pass pops one of at most `frames.len` frames.
    }
};

/// Reads the whole item again, now allocating, and returns the root.
fn build_pass(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    counts: []const u32,
    diag: *Diagnostics,
) ParseValueError!Value {
    var reader: Reader = undefined;
    // proof: `parse_value` checked `input.len <= bytes_max <= input_len_max`.
    reader.init(input, options.depth_max) catch unreachable;
    var builder: Builder = .{
        .tree = tree,
        .counts = counts,
        .next_ordinal = 0,
        .depth_max = options.depth_max,
        .policy = options.duplicate_key,
        .frames = @splat(frame_empty),
        .depth = 0,
        .pending = null,
        .string = null,
        .blame = null,
        .root = .null,
        .done = false,
    };
    for (0..input.len + 1) |_| {
        // proof: pass 1 read these same bytes through the end of the item without an error.
        const token = reader.next(diag) catch unreachable;
        assert(token.item != .end);
        builder.accept(token) catch |err| {
            return fail_build(diag, builder.blame orelse token.offset, err);
        };
        if (!builder.done) continue;
        assert(builder.depth == 0);
        assert(builder.next_ordinal == counts.len);
        return builder.root;
    }
    unreachable; // proof: every token but `.end` consumes a byte, so the item ends the loop.
}

// ---- Tags. ----

/// ADR 0006 section 4: the value a tag 0-3 gives to its content leaf.
fn apply_tag(number: u8, content: Value) BuildError!Value {
    assert(number <= 3);
    switch (number) {
        0 => switch (content) {
            .string => |text| return timestamp_of_text(text),
            else => return error.InvalidTimestamp,
        },
        1 => switch (content) {
            .int => |seconds| return instant(seconds, 0),
            .float => |number_f64| return .{ .timestamp = try timestamp_from_float(number_f64) },
            else => return error.InvalidTimestamp,
        },
        2, 3 => switch (content) {
            .bytes => |data| return bignum(number, data),
            else => return error.InvalidTag,
        },
        else => unreachable, // proof: `begin_tag` refuses numbers above 3.
    }
}

fn instant(seconds: i64, nanoseconds: u32) Value {
    const stamp: Timestamp = .{
        .kind = .instant,
        .seconds = seconds,
        .nanoseconds = nanoseconds,
        .offset_minutes = null,
    };
    stamp.check_invariants();
    return .{ .timestamp = stamp };
}

/// Tag 0: an RFC 3339 `instant`; the written offset is kept. A local kind or a bad calendar
/// field is `InvalidTimestamp`.
fn timestamp_of_text(text: []const u8) BuildError!Value {
    const stamp = core.timestamp.parse(text) catch return error.InvalidTimestamp;
    if (stamp.kind != .instant) return error.InvalidTimestamp;
    stamp.check_invariants();
    return .{ .timestamp = stamp };
}

/// Tag 1 with a float: seconds are the floor, nanoseconds the fraction times 1e9 rounded half to
/// even, with a carry into the seconds when that rounds up to a full second. The result has a
/// null offset. `InvalidTimestamp` for NaN, infinities and values outside `i64` seconds.
pub fn timestamp_from_float(number: f64) error{InvalidTimestamp}!Timestamp {
    const limit: f64 = 9223372036854775808.0; // 2^63, exact.
    if (!(number >= -limit and number < limit)) return error.InvalidTimestamp;
    const whole = @floor(number);
    var seconds: i64 = @intFromFloat(whole);
    const scaled = (number - whole) * 1e9;
    assert(scaled >= 0.0);
    assert(scaled <= 1e9);
    const down = @floor(scaled);
    const rest = scaled - down;
    var nanoseconds: u32 = @intFromFloat(down);
    const odd = nanoseconds % 2 == 1;
    if (rest > 0.5 or (rest == 0.5 and odd)) nanoseconds += 1;
    if (nanoseconds == 1_000_000_000) {
        // proof: `whole < 2^63`, so `seconds <= maxInt(i64) - 1023` and adding one cannot wrap.
        seconds += 1;
        nanoseconds = 0;
    }
    const stamp: Timestamp = .{
        .kind = .instant,
        .seconds = seconds,
        .nanoseconds = nanoseconds,
        .offset_minutes = null,
    };
    stamp.check_invariants();
    return stamp;
}

/// Tags 2 and 3: a big-endian byte string of at most eight significant bytes, as ADR 0006
/// section 4: `n`, or `-1 - n`, through the `int`-unless-above-`maxInt(i64)` rule.
fn bignum(number: u8, data: []const u8) BuildError!Value {
    assert(number == 2 or number == 3);
    var start: u32 = 0;
    for (data) |byte| {
        if (byte != 0) break;
        start += 1;
    }
    const significant = data[start..];
    if (significant.len > 8) {
        return if (number == 2) error.IntegerAboveMax else error.IntegerBelowMin;
    }
    const magnitude = std.mem.readVarInt(u64, significant, .big);
    if (number == 2) {
        if (magnitude > std.math.maxInt(i64)) return .{ .uint = magnitude };
        return .{ .int = @intCast(magnitude) };
    }
    if (magnitude > std.math.maxInt(i64)) return error.IntegerBelowMin;
    return .{ .int = -1 - @as(i64, @intCast(magnitude)) };
}

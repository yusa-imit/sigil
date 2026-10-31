//! msgpack/decoder — a pull reader over one complete input slice (ADR 0006 sections 2, 5, 8; ADR
//! 0003 section 1 for the shape).
//!
//! `next` yields one item head at a time: scalars whole, `str`/`bin`/`ext` with their payload
//! borrowed from the input, and `array`/`map` as a header carrying the element or entry count
//! (the elements follow as further tokens), then `.end` exactly once at `input.len`. The reader
//! keeps no container state; the tree build (a later item) owns the frame stack.
//!
//! Integers are normalized as in ADR 0006 section 2: a non-negative value that an `i64` holds is
//! `.int` whatever its head width, `.uint` appears only above `maxInt(i64)`. Floats widen to
//! `f64` bit-exactly, NaN payloads included. A `str` is checked as strict UTF-8 before it is
//! returned; `bin` and `ext` data are not interpreted.
//!
//! `parse_value` builds a `Value` from the same tokens in one pass (ADR 0006 sections 2-5). Open
//! containers sit on a fixed `[nesting_max]Frame` stack; every count is in the header and has
//! already passed the bomb rule, so each array and map is one arena allocation of its final size
//! (at most 32 bytes per input byte for arrays, 24 for maps, plus string and key copies).
//! Strings, byte strings and keys are copied into the tree. Map keys must be `str`
//! (`NonStringKey`); a repeated key follows `core.DuplicateKeyPolicy` (`.last` leaves the replaced
//! subtree in the arena, bounded by the input). Ext type -1 becomes an `instant` timestamp with a
//! null offset, any other ext is `UnsupportedExt`. Depth counts the root: every array and map is
//! one level, `depth_max` levels pass and the next is `TooDeep` at its head. Bytes after the one
//! item are `TrailingBytes`; input that ends inside an open container is `UnexpectedEnd` at the
//! innermost open container's head. Cost: one scan, O(n^2) key compares per map (`index_of`).
//!
//! Bomb rule (ADR 0006 section 5): a declared length or count is compared, in `u64`, with the
//! bytes left after the head before anything is returned: `len <= left` for `str`/`bin`/`ext`,
//! `n <= left` for an array, `2 * n <= left` for a map. Failure is `UnexpectedEnd` at the
//! item's first byte, so a returned count is always at most the input size.
//!
//! Invariants: `offset <= input.len < maxInt(u32)`; every returned slice is a sub-slice of
//! `input`. Calling `next` after `.end` or after an error is a contract violation (asserted).
//!
//! Positions: every error writes `diag` once as line 1, col = offset + 1 of the item's first
//! byte, with the byte offset in the message; success never writes it. Allocation: none.
//! Cost: one pass, O(1) state, one bounds check per head field.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Timestamp = core.Timestamp;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// One msgpack extension: the signed type byte and its data, borrowed from the input and not
/// interpreted.
pub const Ext = struct { type: i8, data: []const u8 };

/// One decoded item head; the payload of each variant is described on it.
pub const Item = union(enum) {
    /// The `nil` byte `0xc0`.
    nil,
    bool: bool,
    /// Every integer an `i64` holds, from any head.
    int: i64,
    /// Only values above `maxInt(i64)`.
    uint: u64,
    /// `float 32` widened exactly, or `float 64`; a NaN keeps its bits.
    float: f64,
    /// Strict UTF-8, borrowed from the input.
    str: []const u8,
    /// Raw bytes, borrowed from the input and not checked.
    bin: []const u8,
    /// Any ext or fixext form; the type is not validated here.
    ext: Ext,
    /// Element count; the elements are the next tokens.
    array: u32,
    /// Entry count; the next `2 * count` items are key, value, key, value, ...
    map: u32,
    end,
};

/// An item and where it starts.
pub const Token = struct {
    /// The item's first byte; `input.len` for `.end`.
    offset: u32,
    item: Item,
};

/// Why `Reader.next` failed; each is reported at the item's first byte.
pub const ScanError = error{
    /// A head or payload runs past the input, or a declared count cannot fit in what is left.
    UnexpectedEnd,
    /// The byte `0xc1`, which MessagePack never uses.
    ReservedByte,
    /// A `str` payload is not strict UTF-8.
    InvalidUtf8,
};

/// Pull reader over one slice; see the module doc. Construct with `init` only.
pub const Reader = struct {
    input: []const u8,
    offset: u32,
    state: State,

    pub const InitError = error{InputTooLarge};

    /// Longest input `init` accepts: one less than `maxInt(u32)`, so `col = offset + 1` cannot
    /// overflow a `u32` (ADR 0006 section 5).
    pub const input_len_max: u32 = std.math.maxInt(u32) - 1;

    const State = enum(u8) { active, finished, failed };

    comptime {
        assert(@sizeOf(Reader) <= 32);
        assert(@typeInfo(State).@"enum".fields.len == 3);
    }

    /// Starts reading `input`. `InputTooLarge` when it is longer than `input_len_max`.
    pub fn init(reader: *Reader, input: []const u8) InitError!void {
        if (input.len > input_len_max) return error.InputTooLarge;
        reader.* = .{ .input = input, .offset = 0, .state = .active };
        assert(reader.state == .active);
        assert(reader.offset == 0);
    }

    /// The next token. On error `diag` is written once and the reader is failed: calling `next`
    /// again is a contract violation. Slices in the result borrow the input.
    pub fn next(reader: *Reader, diag: *Diagnostics) ScanError!Token {
        assert(reader.state == .active);
        assert(reader.offset <= reader.input.len);
        errdefer assert(reader.state == .failed);

        const start = reader.offset;
        if (start == reader.input.len) {
            reader.state = .finished;
            return .{ .offset = start, .item = .end };
        }
        const item = reader.read_item(reader.input[start]) catch |err| {
            return reader.fail(diag, err, start);
        };
        assert(reader.offset > start);
        assert(reader.offset <= reader.input.len);
        return .{ .offset = start, .item = item };
    }

    /// Reads the item whose first byte is `byte` (not yet consumed) and advances `offset`.
    fn read_item(reader: *Reader, byte: u8) ScanError!Item {
        reader.offset += 1;
        return switch (byte) {
            0x00...0x7f => .{ .int = byte },
            0x80...0x8f => reader.container(.map, byte & 0x0f),
            0x90...0x9f => reader.container(.array, byte & 0x0f),
            0xa0...0xbf => reader.string(byte & 0x1f),
            0xc0 => .nil,
            0xc1 => error.ReservedByte,
            0xc2 => .{ .bool = false },
            0xc3 => .{ .bool = true },
            0xc4...0xc6 => .{ .bin = try reader.take(try reader.take_uint(len_width(byte))) },
            0xc7...0xc9 => try reader.ext(try reader.take_uint(len_width(byte))),
            0xca, 0xcb => try reader.float(byte),
            0xcc...0xcf => normalize_unsigned(try reader.take_uint(int_width(byte))),
            0xd0...0xd3 => reader.signed(byte),
            0xd4...0xd8 => try reader.ext(@as(u64, 1) << @intCast(byte - 0xd4)),
            0xd9...0xdb => try reader.string(try reader.take_uint(len_width(byte))),
            0xdc, 0xdd => reader.container(.array, try reader.take_uint(len_width(byte))),
            0xde, 0xdf => reader.container(.map, try reader.take_uint(len_width(byte))),
            0xe0...0xff => .{ .int = @as(i8, @bitCast(byte)) },
        };
    }

    /// Consumes `width` bytes (1, 2, 4 or 8) as a big-endian unsigned number.
    fn take_uint(reader: *Reader, width: u8) ScanError!u64 {
        assert(width == 1 or width == 2 or width == 4 or width == 8);
        const bytes = try reader.take(width);
        const value = std.mem.readVarInt(u64, bytes, .big);
        if (width < 8) assert(value >> @intCast(8 * width) == 0);
        return value;
    }

    /// Consumes `len` bytes; `UnexpectedEnd` when fewer are left.
    fn take(reader: *Reader, len: u64) ScanError![]const u8 {
        assert(reader.offset <= reader.input.len);
        const left: u64 = reader.input.len - reader.offset;
        if (len > left) return error.UnexpectedEnd;
        const bytes = reader.input[reader.offset..][0..@intCast(len)];
        reader.offset += @intCast(len);
        return bytes;
    }

    /// The ADR 0006 section 2 normal form of a non-negative integer.
    fn normalize_unsigned(value: u64) Item {
        if (value > std.math.maxInt(i64)) return .{ .uint = value };
        const item: Item = .{ .int = @intCast(value) };
        assert(item.int >= 0);
        return item;
    }

    /// `0xd0`..`0xd3`: int 8, 16, 32, 64, sign-extended.
    fn signed(reader: *Reader, byte: u8) ScanError!Item {
        assert(byte >= 0xd0 and byte <= 0xd3);
        const width = int_width(byte);
        const raw = try reader.take_uint(width);
        const shift: u6 = @intCast(64 - 8 * @as(u32, width));
        const value: i64 = @as(i64, @bitCast(raw << shift)) >> shift;
        return .{ .int = value };
    }

    fn float(reader: *Reader, byte: u8) ScanError!Item {
        assert(byte == 0xca or byte == 0xcb);
        if (byte == 0xcb) {
            const bits = try reader.take_uint(8);
            return .{ .float = @bitCast(bits) };
        }
        const bits: u32 = @intCast(try reader.take_uint(4));
        return .{ .float = widen_f32(bits) };
    }

    fn string(reader: *Reader, len: u64) ScanError!Item {
        const bytes = try reader.take(len);
        assert(bytes.len == len);
        // proof: the input is shorter than maxInt(u32) (`init`), and so is every sub-slice.
        const invalid = core.unicode.find_invalid(bytes) catch unreachable;
        if (invalid != null) return error.InvalidUtf8;
        return .{ .str = bytes };
    }

    /// Extension data after its length: one type byte, then `len` bytes.
    fn ext(reader: *Reader, len: u64) ScanError!Item {
        const type_byte = try reader.take(1);
        const data = try reader.take(len);
        assert(data.len == len);
        return .{ .ext = .{ .type = @bitCast(type_byte[0]), .data = data } };
    }

    /// An array or map header of `count` elements or entries; the bomb rule of the module doc.
    fn container(reader: *Reader, comptime kind: enum { array, map }, count: u64) ScanError!Item {
        assert(count <= std.math.maxInt(u32));
        const left: u64 = reader.input.len - reader.offset;
        const needed = if (kind == .map) 2 * count else count;
        if (needed > left) return error.UnexpectedEnd;
        assert(needed >= count);
        assert(count <= left);
        const count_u32: u32 = @intCast(count);
        return if (kind == .map) .{ .map = count_u32 } else .{ .array = count_u32 };
    }

    /// Writes `diag` for the item starting at `start` and fails the reader.
    fn fail(reader: *Reader, diag: *Diagnostics, err: ScanError, start: u32) ScanError {
        assert(start < reader.input.len);
        assert(reader.state == .active);
        set_diag(diag, start, reason_of(err));
        reader.state = .failed;
        return err;
    }
};

/// Writes `diag` as line 1, col `offset + 1`, message "byte N: reason".
fn set_diag(diag: *Diagnostics, offset: u32, reason: []const u8) void {
    assert(offset < std.math.maxInt(u32));
    assert(reason.len <= 40);
    var buffer: [64]u8 = undefined;
    // proof: the longest message is 6 + 10 + 2 + 40 bytes, well under 64.
    const message = std.fmt.bufPrint(&buffer, "byte {d}: {s}", .{ offset, reason }) catch
        unreachable;
    diag.* = Diagnostics.init(1, offset + 1, message, null);
}

fn reason_of(err: ScanError) []const u8 {
    // proof: `ScanError` holds no I/O error, so `error.Canceled` cannot occur.
    return switch (err) {
        error.UnexpectedEnd => "unexpected end of input",
        error.ReservedByte => "reserved byte 0xc1",
        error.InvalidUtf8 => "invalid UTF-8 in str",
    };
}

/// Byte width of the length field of `bin`/`ext`/`str`/array/map heads (0xc4..0xc9, 0xd9..0xdf).
fn len_width(byte: u8) u8 {
    return switch (byte) {
        0xc4, 0xc7, 0xd9 => 1,
        0xc5, 0xc8, 0xda, 0xdc, 0xde => 2,
        0xc6, 0xc9, 0xdb, 0xdd, 0xdf => 4,
        else => unreachable, // proof: callers pass only the bytes listed in the arms above.
    };
}

/// Byte width of the value of int/uint heads (0xcc..0xcf, 0xd0..0xd3).
fn int_width(byte: u8) u8 {
    assert((byte >= 0xcc and byte <= 0xcf) or (byte >= 0xd0 and byte <= 0xd3));
    const exponent: u3 = @intCast((byte - 0xcc) & 0x03);
    return @as(u8, 1) << exponent;
}

/// Widens f32 bits to `f64` exactly; a NaN keeps its payload shifted left, which `@floatCast`
/// does not promise.
fn widen_f32(bits: u32) f64 {
    const exponent_all = 0x7f80_0000;
    const is_nan = (bits & exponent_all) == exponent_all and (bits & 0x007f_ffff) != 0;
    if (!is_nan) {
        const exact: f64 = @floatCast(@as(f32, @bitCast(bits)));
        assert(!std.math.isNan(exact));
        return exact;
    }
    const sign: u64 = bits >> 31;
    const payload: u64 = bits & 0x007f_ffff;
    const widened: f64 = @bitCast((sign << 63) | (@as(u64, 0x7ff) << 52) | (payload << 29));
    assert(std.math.isNan(widened));
    return widened;
}

/// Every field is required: no defaults.
pub const ParseOptions = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
    /// Input longer than this is `error.InputTooLarge`, before any byte is read; at most
    /// `Reader.input_len_max`.
    bytes_max: u32,
    duplicate_key: core.DuplicateKeyPolicy,
};

/// What building the tree adds to the reader's errors.
pub const BuildError = error{
    UnexpectedEnd,
    TooDeep,
    NonStringKey,
    DuplicateKey,
    UnsupportedExt,
    InvalidTimestamp,
    TrailingBytes,
    OutOfMemory,
};

/// Every error `parse_value` can return (11 variants, ADR 0006 section 8).
pub const ParseValueError = ScanError || BuildError || error{InputTooLarge};

comptime {
    assert(@sizeOf(Value) == 32);
    assert(@sizeOf(Map.Entry) == 48);
    assert(@typeInfo(ParseValueError).error_set.?.len == 11);
}

/// Parses `input`, exactly one MessagePack item, into `tree` and returns its root. The root is
/// not stored in `tree.root`, so one tree can hold several documents. Strings, byte strings and
/// keys are copies; the result lives until `tree.deinit()` and `input` may be freed once this
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
    var reader: Reader = undefined;
    // proof: `input.len <= bytes_max <= input_len_max`, the only way `init` can fail.
    reader.init(input) catch unreachable;
    var builder: Builder = .{
        .tree = tree,
        .depth_max = options.depth_max,
        .policy = options.duplicate_key,
        .frames = @splat(frame_empty),
        .depth = 0,
        .root = .null,
        .done = false,
    };
    for (0..input.len + 1) |_| {
        const token = try reader.next(diag);
        if (token.item == .end) {
            assert(!builder.done);
            return fail_build(diag, builder.head_open(), error.UnexpectedEnd);
        }
        builder.accept(token) catch |err| return fail_build(diag, token.offset, err);
        if (!builder.done) continue;
        assert(builder.depth == 0);
        if (reader.offset < input.len) return fail_build(diag, reader.offset, error.TrailingBytes);
        return builder.root;
    }
    unreachable; // proof: every token but `.end` consumes a byte, so `.end` ends the loop.
}

/// Writes `diag` for a tree-building failure at `offset` and returns `err`.
fn fail_build(diag: *Diagnostics, offset: u32, err: BuildError) BuildError {
    assert(offset <= Reader.input_len_max);
    // proof: `BuildError` holds no I/O error, so `error.Canceled` cannot occur.
    const reason = switch (err) {
        error.UnexpectedEnd => "unexpected end of input",
        error.TooDeep => "nesting is too deep",
        error.NonStringKey => "map key is not a str",
        error.DuplicateKey => "duplicate map key",
        error.UnsupportedExt => "unsupported extension type",
        error.InvalidTimestamp => "invalid timestamp extension",
        error.TrailingBytes => "trailing bytes after the item",
        error.OutOfMemory => "out of memory",
    };
    set_diag(diag, offset, reason);
    return err;
}

/// One open container.
const Frame = struct {
    /// Offset of the container's head byte.
    head: u32,
    is_map: bool,
    array: []Value,
    map: Map,
    /// Elements (array) or entries (map) still to be stored; the container closes at zero.
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
                // proof: `take_key` found the key absent and the map holds one slot per entry.
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
    .array = &.{},
    .map = .{ .entries = &.{}, .count = 0 },
    .left = 0,
    .fill = 0,
    .key = "",
    .slot = null,
    .key_pending = false,
};

/// The tree build: open containers and the finished root.
const Builder = struct {
    tree: *ValueTree,
    depth_max: u32,
    policy: core.DuplicateKeyPolicy,
    frames: [core.value.nesting_max]Frame,
    depth: u32,
    root: Value,
    done: bool,

    /// Where an input that ends now is incomplete: the innermost open container's head, or 0.
    fn head_open(builder: *const Builder) u32 {
        assert(builder.depth <= builder.frames.len);
        if (builder.depth == 0) return 0;
        return builder.frames[builder.depth - 1].head;
    }

    fn accept(builder: *Builder, token: Token) BuildError!void {
        assert(builder.depth <= builder.frames.len);
        assert(!builder.done);
        if (builder.depth > 0) {
            const top = &builder.frames[builder.depth - 1];
            if (top.is_map and !top.key_pending) return builder.take_key(token);
        }
        switch (token.item) {
            .nil => builder.finish(.null),
            .bool => |flag| builder.finish(.{ .bool = flag }),
            .int => |number| builder.finish(.{ .int = number }),
            .uint => |number| builder.finish(.{ .uint = number }),
            .float => |number| builder.finish(.{ .float = number }),
            .str => |text| builder.finish(try builder.tree.dupe_string(text)),
            .bin => |data| builder.finish(try builder.tree.dupe_bytes(data)),
            .ext => |extension| builder.finish(try timestamp_of(extension)),
            .array => |count| try builder.open(token.offset, false, count),
            .map => |count| try builder.open(token.offset, true, count),
            .end => unreachable, // proof: `parse_value` returns on `.end` before accepting it.
        }
    }

    /// Records the key of the next entry. Under `.reject` a repeated key fails here.
    fn take_key(builder: *Builder, token: Token) BuildError!void {
        assert(builder.depth > 0);
        const frame = &builder.frames[builder.depth - 1];
        assert(frame.is_map);
        assert(!frame.key_pending);
        const text = switch (token.item) {
            .str => |text| text,
            else => return error.NonStringKey,
        };
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

    /// Pushes a container of `count` children, or finishes it at once when `count` is zero.
    fn open(builder: *Builder, head: u32, is_map: bool, count: u32) BuildError!void {
        assert(builder.depth <= builder.depth_max);
        if (builder.depth == builder.depth_max) return error.TooDeep;
        var frame = frame_empty;
        frame.head = head;
        frame.is_map = is_map;
        frame.left = count;
        if (is_map) {
            frame.map = try builder.tree.new_map(count);
        } else {
            frame.array = try builder.tree.arena.allocator().alloc(Value, count);
        }
        if (count == 0) return builder.finish(frame.finished());
        builder.frames[builder.depth] = frame;
        builder.depth += 1;
    }

    /// Attaches a finished value to its parent, closing every parent that becomes full.
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
            if (frame.left > 0) return;
            current = frame.finished();
            builder.depth -= 1;
        }
        unreachable; // proof: each pass pops one of at most `frames.len` frames.
    }
};

/// ADR 0006 section 4: ext type -1 in its 4, 8 and 12 byte forms is an `instant` with a null
/// offset; every other type is `UnsupportedExt`, every other length `InvalidTimestamp`.
fn timestamp_of(extension: Ext) error{ UnsupportedExt, InvalidTimestamp }!Value {
    if (extension.type != -1) return error.UnsupportedExt;
    const data = extension.data;
    const nanoseconds_max = 999_999_999;
    var seconds: i64 = 0;
    var nanoseconds: u64 = 0;
    switch (data.len) {
        4 => seconds = std.mem.readInt(u32, data[0..4], .big),
        8 => {
            const bits = std.mem.readInt(u64, data[0..8], .big);
            nanoseconds = bits >> 34;
            seconds = @intCast(bits & ((@as(u64, 1) << 34) - 1));
        },
        12 => {
            nanoseconds = std.mem.readInt(u32, data[0..4], .big);
            seconds = std.mem.readInt(i64, data[4..12], .big);
        },
        else => return error.InvalidTimestamp,
    }
    if (nanoseconds > nanoseconds_max) return error.InvalidTimestamp;
    const stamp: Timestamp = .{
        .kind = .instant,
        .seconds = seconds,
        .nanoseconds = @intCast(nanoseconds),
        .offset_minutes = null,
    };
    stamp.check_invariants();
    return .{ .timestamp = stamp };
}

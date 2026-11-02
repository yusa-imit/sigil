//! cbor/decoder — a pull reader over one complete input slice (ADR 0006 sections 2, 4, 5, 8, 9;
//! ADR 0003 section 1 for the shape).
//!
//! `next` yields one item head at a time: scalars whole, text and byte strings with their payload
//! borrowed from the input, definite `array`/`map` as a header carrying the element or entry
//! count, `tag` as a header whose content is the next item, and the indefinite forms as start
//! markers (`array_indef`, `map_indef`, `bytes_indef`, `text_indef`) closed by one `stop` token
//! (the break byte `0xff`). The elements follow as further tokens, then `.end` exactly once at
//! `input.len`.
//!
//! Unlike the msgpack reader this one keeps a bounded frame stack, because well-formedness
//! (RFC 8949 section 3) depends on where a `break` sits: it checks that a `stop` closes an
//! indefinite array or map, never a definite one, a tag or a map key (`UnexpectedBreak`,
//! `InvalidIndefinite`), that the chunks of an indefinite string are definite strings of the
//! same major type (`InvalidIndefinite`), and that input does not end inside an open container,
//! tag or string (`UnexpectedEnd` at the innermost open head). Each text chunk is strict UTF-8 on
//! its own. A completed root item resets the stack, so a second item may follow; the tree build
//! (a later item) owns the `TrailingBytes` rule.
//!
//! Integers are normalized as in ADR 0006 section 2: a non-negative value that an `i64` holds is
//! `.int` whatever its head width, `.uint` appears only above `maxInt(i64)`, and a negative
//! integer below `minInt(i64)` is `IntegerBelowMin`. Floats (half, single, double) widen to `f64`
//! bit-exactly, NaN payloads included. Simple values other than false, true and null are returned
//! as `.simple` (the tree build refuses them); a two-byte simple value below 32 is
//! `NotWellFormed`.
//!
//! Depth: every array, map and tag head is one level, `depth_max` levels pass and the next head is
//! `TooDeep`; an indefinite string is a leaf and does not count. Bomb rule (ADR 0006 section 5):
//! a declared length or count is compared, in `u64`, with the bytes left after the head before
//! anything is returned: `len <= left` for strings, `n <= left` for an array, `2 * n <= left`
//! for a map; failure is `UnexpectedEnd` at the item's first byte. Tags carry no length.
//!
//! Invariants: `offset <= input.len < maxInt(u32)`; `depth <= depth_max <= nesting_max`; every
//! returned slice is a sub-slice of `input`. Calling `next` after `.end` or after an error is a
//! contract violation (asserted).
//!
//! Positions: every error writes `diag` once as line 1, col = offset + 1 of the item's first
//! byte (the open head for input that ends early), with the byte offset in the message; success
//! never writes it. Allocation: none. Cost: one pass, O(depth_max) state, one bounds check per
//! head field.

const std = @import("std");
const core = @import("../core.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;

/// One decoded item head; the payload of each variant is described on it.
pub const Item = union(enum) {
    /// The `null` byte `0xf6`.
    null,
    bool: bool,
    /// Every integer an `i64` holds, from any head and either sign.
    int: i64,
    /// Only values above `maxInt(i64)`.
    uint: u64,
    /// Half, single or double widened exactly; a NaN keeps its bits.
    float: f64,
    /// Any simple value but false, true and null: 0-19, 23 (`undefined`) and 32-255.
    simple: u8,
    /// Strict UTF-8, borrowed from the input; a whole string or one chunk of an indefinite one.
    text: []const u8,
    /// Raw bytes, borrowed from the input; a whole string or one chunk of an indefinite one.
    bytes: []const u8,
    /// Element count; the elements are the next tokens.
    array: u32,
    /// Entry count; the next `2 * count` items are key, value, key, value, ...
    map: u32,
    /// Start of an indefinite array; its elements follow, then `stop`.
    array_indef,
    /// Start of an indefinite map; key, value pairs follow, then `stop`.
    map_indef,
    /// Start of an indefinite byte string; definite `bytes` chunks follow, then `stop`.
    bytes_indef,
    /// Start of an indefinite text string; definite `text` chunks follow, then `stop`.
    text_indef,
    /// A tag number; the tagged item is the next token.
    tag: u64,
    /// The break byte `0xff` closing the innermost indefinite item.
    stop,
    /// The whole input is consumed and nothing is left open; yielded exactly once.
    end,
};

/// An item and where it starts.
pub const Token = struct {
    /// The item's first byte; `input.len` for `.end`.
    offset: u32,
    item: Item,
};

/// Why `Reader.next` failed; each is reported at the item's first byte unless stated.
pub const ScanError = error{
    /// A head or payload runs past the input, a declared count cannot fit in what is left, or the
    /// input ends inside an open container, tag or indefinite string (reported at its head).
    UnexpectedEnd,
    /// Additional info 28-30, 31 on a major type that has no indefinite form, or `f8` below 32.
    NotWellFormed,
    /// A `stop` where no indefinite array or map is open, or a tag or definite container waits.
    UnexpectedBreak,
    /// A chunk of an indefinite string that is not a definite string of its type, or a `stop`
    /// between a map key and its value.
    InvalidIndefinite,
    /// A text payload is not strict UTF-8.
    InvalidUtf8,
    /// A container or tag head would open level `depth_max + 1`.
    TooDeep,
    /// A negative integer below `minInt(i64)`.
    IntegerBelowMin,
};

/// Pull reader over one slice; see the module doc. Construct with `init` only.
pub const Reader = struct {
    /// The whole document; borrowed, never modified.
    input: []const u8,
    /// The next byte to read; `input.len` once every item is consumed.
    offset: u32,
    /// The deepest container and tag nesting allowed, `1..nesting_max`.
    depth_max: u16,
    /// Open frames; `frames[0..depth]` are live.
    depth: u16,
    state: State,
    /// The open indefinite string, if any; its chunks are the only legal items until `stop`.
    string: StringMode,
    /// The first byte of the open indefinite string; meaningful when `string != .none`.
    string_head: u32,
    frames: [core.value.nesting_max]Frame,

    pub const InitError = error{InputTooLarge};

    /// Longest input `init` accepts: one less than `maxInt(u32)`, so `col = offset + 1` cannot
    /// overflow a `u32` (ADR 0006 section 5).
    pub const input_len_max: u32 = std.math.maxInt(u32) - 1;

    const State = enum(u8) { active, finished, failed };
    const StringMode = enum(u8) { none, bytes, text };

    /// What an open frame is waiting for. `left` counts the items still due for a definite
    /// container (a map counts keys and values), is unused for a tag, and for an indefinite map is
    /// 0 when a key is due and 1 when its value is.
    const Frame = struct {
        head: u32,
        left: u32,
        kind: enum(u8) { tag, definite, indef_array, indef_map },
    };

    comptime {
        assert(@sizeOf(Frame) == 12);
        assert(@typeInfo(State).@"enum".fields.len == 3);
    }

    /// Starts reading `input`. `InputTooLarge` when it is longer than `input_len_max`.
    /// Preconditions: `1 <= depth_max <= core.value.nesting_max`.
    pub fn init(reader: *Reader, input: []const u8, depth_max: u16) InitError!void {
        assert(depth_max >= 1);
        assert(depth_max <= core.value.nesting_max);
        if (input.len > input_len_max) return error.InputTooLarge;
        reader.input = input;
        reader.offset = 0;
        reader.depth_max = depth_max;
        reader.depth = 0;
        reader.state = .active;
        reader.string = .none;
        reader.string_head = 0;
        // Zeroed so no frame holds stale bytes; `push` overwrites a slot before exposing it.
        const frame_empty: Frame = .{ .head = 0, .left = 0, .kind = .tag };
        reader.frames = [_]Frame{frame_empty} ** core.value.nesting_max;
        assert(reader.state == .active);
        assert(reader.depth == 0);
    }

    /// The next token. On error `diag` is written once and the reader is failed: calling `next`
    /// again is a contract violation. Slices in the result borrow the input.
    pub fn next(reader: *Reader, diag: *Diagnostics) ScanError!Token {
        assert(reader.state == .active);
        assert(reader.offset <= reader.input.len);
        assert(reader.depth <= reader.depth_max);
        errdefer assert(reader.state == .failed);

        const start = reader.offset;
        if (start == reader.input.len) {
            if (reader.open_head()) |head| return reader.fail(diag, error.UnexpectedEnd, head);
            reader.state = .finished;
            return .{ .offset = start, .item = .end };
        }
        const item = reader.read_item(reader.input[start], start) catch |err| {
            return reader.fail(diag, err, start);
        };
        assert(reader.offset > start);
        assert(reader.offset <= reader.input.len);
        return .{ .offset = start, .item = item };
    }

    /// The first byte of the innermost open string, container or tag; null at the top level.
    fn open_head(reader: *const Reader) ?u32 {
        if (reader.string != .none) {
            assert(reader.string_head < reader.input.len);
            return reader.string_head;
        }
        if (reader.depth == 0) return null;
        const head = reader.frames[reader.depth - 1].head;
        assert(head < reader.input.len);
        return head;
    }

    /// Reads the item whose first byte `byte` is at `start` (not yet consumed) and advances.
    fn read_item(reader: *Reader, byte: u8, start: u32) ScanError!Item {
        assert(reader.input[start] == byte);
        assert(reader.offset == start);
        reader.offset += 1;
        const major = byte >> 5;
        const info: u8 = byte & 0x1f;
        if (reader.string != .none) return reader.chunk(major, info);
        return switch (major) {
            0 => reader.unsigned(info),
            1 => reader.negative(info),
            2, 3 => reader.string_item(major, info, start),
            4, 5 => reader.container(major, info, start),
            6 => reader.tag(info, start),
            7 => reader.simple(info),
            else => unreachable, // proof: `byte >> 5` of a u8 is at most 7.
        };
    }

    /// The argument of a head with additional info `info`: the info itself below 24, else the
    /// 1, 2, 4 or 8 bytes after the head. 28-31 are not arguments.
    fn argument(reader: *Reader, info: u8) ScanError!u64 {
        assert(info <= 0x1f);
        return switch (info) {
            0...23 => info,
            24 => reader.take_uint(1),
            25 => reader.take_uint(2),
            26 => reader.take_uint(4),
            27 => reader.take_uint(8),
            28...31 => error.NotWellFormed,
            else => unreachable, // proof: `info` is five bits.
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

    /// Major type 0: the ADR 0006 section 2 normal form of a non-negative integer.
    fn unsigned(reader: *Reader, info: u8) ScanError!Item {
        assert(reader.string == .none);
        const value = try reader.argument(info);
        if (value > std.math.maxInt(i64)) return reader.complete(.{ .uint = value });
        return reader.complete(.{ .int = @intCast(value) });
    }

    /// Major type 1: `-1 - n`.
    fn negative(reader: *Reader, info: u8) ScanError!Item {
        const n = try reader.argument(info);
        if (n > std.math.maxInt(i64)) return error.IntegerBelowMin;
        const value: i64 = -1 - @as(i64, @intCast(n));
        assert(value < 0);
        return reader.complete(.{ .int = value });
    }

    /// Major types 2 and 3: a definite string, or the start of an indefinite one.
    fn string_item(reader: *Reader, major: u8, info: u8, start: u32) ScanError!Item {
        assert(major == 2 or major == 3);
        if (info == 31) {
            reader.string = if (major == 2) .bytes else .text;
            reader.string_head = start;
            return if (major == 2) .bytes_indef else .text_indef;
        }
        const item = try reader.definite_string(major, info);
        return reader.complete(item);
    }

    /// A definite byte or text string whose head (`major`, `info`) has just been read.
    fn definite_string(reader: *Reader, major: u8, info: u8) ScanError!Item {
        assert(major == 2 or major == 3);
        assert(info != 31);
        const len = try reader.argument(info);
        const payload = try reader.take(len);
        assert(payload.len == len);
        if (major == 2) return .{ .bytes = payload };
        // proof: the input is shorter than maxInt(u32) (`init`), and so is every sub-slice.
        const invalid = core.unicode.find_invalid(payload) catch unreachable;
        if (invalid != null) return error.InvalidUtf8;
        return .{ .text = payload };
    }

    /// Inside an indefinite string only a definite chunk of its type or `stop` may appear.
    fn chunk(reader: *Reader, major: u8, info: u8) ScanError!Item {
        assert(reader.string != .none);
        const wanted: u8 = if (reader.string == .bytes) 2 else 3;
        if (major == 7 and info == 31) {
            reader.string = .none;
            return reader.complete(.stop);
        }
        if (major != wanted) return error.InvalidIndefinite;
        if (info == 31) return error.InvalidIndefinite;
        return reader.definite_string(major, info);
    }

    /// Major types 4 and 5: a definite container (bomb rule), or the start of an indefinite one.
    fn container(reader: *Reader, major: u8, info: u8, start: u32) ScanError!Item {
        assert(major == 4 or major == 5);
        const is_map = major == 5;
        if (info == 31) {
            try reader.push(start, if (is_map) .indef_map else .indef_array, 0);
            return if (is_map) .map_indef else .array_indef;
        }
        const count = try reader.argument(info);
        const left: u64 = reader.input.len - reader.offset;
        if (count > left) return error.UnexpectedEnd;
        if (is_map and 2 * count > left) return error.UnexpectedEnd;
        const count_u32: u32 = @intCast(count);
        const item: Item = if (is_map) .{ .map = count_u32 } else .{ .array = count_u32 };
        if (count == 0) {
            if (reader.depth == reader.depth_max) return error.TooDeep;
            return reader.complete(item);
        }
        try reader.push(start, .definite, if (is_map) 2 * count_u32 else count_u32);
        return item;
    }

    /// Major type 6: the tag number; the tagged item is the next token.
    fn tag(reader: *Reader, info: u8, start: u32) ScanError!Item {
        assert(reader.string == .none);
        const number = try reader.argument(info);
        try reader.push(start, .tag, 0);
        assert(reader.frames[reader.depth - 1].kind == .tag);
        return .{ .tag = number };
    }

    /// Major type 7: simple values, floats and the break code.
    fn simple(reader: *Reader, info: u8) ScanError!Item {
        assert(info <= 0x1f);
        assert(reader.string == .none);
        const item: Item = switch (info) {
            20 => .{ .bool = false },
            21 => .{ .bool = true },
            22 => .null,
            24 => blk: {
                const value: u8 = @intCast(try reader.take_uint(1));
                if (value < 32) return error.NotWellFormed;
                break :blk .{ .simple = value };
            },
            25 => .{ .float = widen_f16(@intCast(try reader.take_uint(2))) },
            26 => .{ .float = widen_f32(@intCast(try reader.take_uint(4))) },
            27 => .{ .float = @bitCast(try reader.take_uint(8)) },
            28...30 => return error.NotWellFormed,
            31 => return reader.break_code(),
            0...19, 23 => .{ .simple = info },
            else => unreachable, // proof: `info` is five bits and every value is an arm above.
        };
        return reader.complete(item);
    }

    /// The `stop` byte outside an indefinite string: it must close an indefinite array, or an
    /// indefinite map at a key boundary.
    fn break_code(reader: *Reader) ScanError!Item {
        if (reader.depth == 0) return error.UnexpectedBreak;
        const frame = &reader.frames[reader.depth - 1];
        switch (frame.kind) {
            .tag, .definite => return error.UnexpectedBreak,
            .indef_array => {},
            .indef_map => if (frame.left != 0) return error.InvalidIndefinite,
        }
        assert(frame.kind == .indef_array or frame.kind == .indef_map);
        const depth_before = reader.depth;
        reader.depth -= 1;
        defer assert(reader.depth < depth_before);

        return reader.complete(.stop);
    }

    /// Opens a frame for a container or tag head at `head`; `TooDeep` at `depth_max` levels.
    fn push(reader: *Reader, head: u32, kind: @FieldType(Frame, "kind"), left: u32) ScanError!void {
        assert(reader.depth <= reader.depth_max);
        if (reader.depth == reader.depth_max) return error.TooDeep;
        reader.frames[reader.depth] = .{ .head = head, .left = left, .kind = kind };
        reader.depth += 1;
        assert(reader.depth <= reader.depth_max);
    }

    /// Marks one whole item done: a tag it was the content of is done too, a definite container
    /// loses one pending item and closes at zero (which completes the parent in turn), an
    /// indefinite map flips between key and value. Returns `item` so callers can `return` it.
    fn complete(reader: *Reader, item: Item) Item {
        for (0..core.value.nesting_max + 1) |_| {
            if (reader.depth == 0) return item;
            const frame = &reader.frames[reader.depth - 1];
            switch (frame.kind) {
                .tag => reader.depth -= 1,
                .definite => {
                    assert(frame.left > 0);
                    frame.left -= 1;
                    if (frame.left != 0) return item;
                    reader.depth -= 1;
                },
                .indef_array => return item,
                .indef_map => {
                    frame.left ^= 1;
                    return item;
                },
            }
        }
        unreachable; // proof: each pass pops a frame and at most `nesting_max` are open.
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
pub fn set_diag(diag: *Diagnostics, offset: u32, reason: []const u8) void {
    assert(offset < std.math.maxInt(u32));
    assert(reason.len <= 40);
    var buffer: [64]u8 = undefined;
    // proof: the longest message is 5 + 10 + 2 + 40 bytes, well under 64.
    const message = std.fmt.bufPrint(&buffer, "byte {d}: {s}", .{ offset, reason }) catch
        unreachable;
    diag.* = Diagnostics.init(1, offset + 1, message, null);
}

fn reason_of(err: ScanError) []const u8 {
    // proof: `ScanError` holds no I/O error, so `error.Canceled` cannot occur.
    return switch (err) {
        error.UnexpectedEnd => "unexpected end of input",
        error.NotWellFormed => "not well-formed",
        error.UnexpectedBreak => "unexpected break",
        error.InvalidIndefinite => "invalid indefinite-length item",
        error.InvalidUtf8 => "invalid UTF-8 in text",
        error.TooDeep => "nesting is too deep",
        error.IntegerBelowMin => "integer below minimum",
    };
}

/// Widens half-precision bits to `f64` exactly; a NaN keeps its payload shifted left.
fn widen_f16(bits: u16) f64 {
    const exponent_all = 0x7c00;
    const is_nan = (bits & exponent_all) == exponent_all and (bits & 0x03ff) != 0;
    if (!is_nan) {
        const exact: f64 = @floatCast(@as(f16, @bitCast(bits)));
        assert(!std.math.isNan(exact));
        return exact;
    }
    const sign: u64 = bits >> 15;
    const payload: u64 = bits & 0x03ff;
    const widened: f64 = @bitCast((sign << 63) | (@as(u64, 0x7ff) << 52) | (payload << 42));
    assert(std.math.isNan(widened));
    return widened;
}

/// Widens single-precision bits to `f64` exactly; a NaN keeps its payload shifted left, which
/// `@floatCast` does not promise.
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

const tree = @import("tree.zig");

/// The tree build over this reader; see `cbor/tree.zig`.
pub const parse_value = tree.parse_value;
pub const ParseOptions = tree.ParseOptions;
pub const BuildError = tree.BuildError;
pub const ParseValueError = tree.ParseValueError;

//! msgpack/encoder — a `Value` onto a `std.Io.Writer` as MessagePack (ADR 0006 sections 6, 8).
//!
//! Fixed policy, no options but the depth: every integer takes the shortest head (a non-negative
//! `.int` and a `.uint` use the unsigned forms, so `.uint = 5` is the byte `05`); a float is
//! `float 32` when widening it back gives the same bits and `float 64` otherwise; every NaN is
//! the one quiet positive NaN `ca 7fc00000`; strings take the shortest `str` form after a strict
//! UTF-8 check, `.bytes` the shortest `bin` form; containers the shortest array or map head. A
//! map is written in insertion order. A `.timestamp` is the `ext -1` form: only an `instant`
//! with a null offset has one (seconds `0..2^32-1` with no nanoseconds is ext 4, seconds
//! `0..2^34-1` ext 8, everything else ext 12); an offset or a local kind cannot come back, so it
//! is `Unrepresentable`, and so is a string, byte string, array or map longer than `maxInt(u32)`.
//!
//! No recursion: the open containers live on a fixed `nesting_max` frame stack and `step` runs
//! until it is empty. `InputTooLarge` is part of the shared `WriteValueError` set but this
//! writer never returns it: an over-long item is `Unrepresentable` here (the CBOR encoder, whose
//! lengths are 64-bit, reaches it through the UTF-8 check).
//!
//! Allocation: none. Output goes to the caller's writer as it is produced, so a failure leaves a
//! prefix in it. Every error return writes `diag` once (the key path of the failing member, ADR
//! 0002 grammar); success never does.

const std = @import("std");
const core = @import("../core.zig");
const context = @import("../reflect/context.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Path = context.Path;
const Segment = context.Segment;
const Timestamp = core.Timestamp;
const Value = core.Value;
const nesting_max = core.value.nesting_max;

/// Every field is required: no defaults.
pub const StringifyOptions = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
};

/// Every way `write` can fail (5 variants). `WriteFailed` is the caller's writer failing.
pub const WriteValueError = core.unicode_escape.WriteError || error{ Unrepresentable, TooDeep };

comptime {
    assert(@typeInfo(WriteValueError).error_set.?.len == 5);
}

/// The longest length any msgpack head can carry.
const length_max: u64 = std.math.maxInt(u32);
/// Seconds an ext 4 timestamp holds, inclusive.
const seconds_ext4_max: i64 = std.math.maxInt(u32);
/// Seconds an ext 8 timestamp holds, inclusive (34 bits).
const seconds_ext8_max: i64 = (1 << 34) - 1;
/// The one NaN the encoder writes, as `float 32` bits.
const nan_bits: u32 = 0x7fc00000;

/// Writes `value` to `w` as one MessagePack item. The `Value` is only read; it may be any tree,
/// not just one a parser built. On error `diag` holds the key path and the reason, and `w` holds
/// whatever was written before the failure.
/// Preconditions: `1 <= options.depth_max <= nesting_max`; every `Map` in `value` obeys its
/// invariant (no duplicate key).
pub fn write(
    w: *std.Io.Writer,
    value: Value,
    options: StringifyOptions,
    diag: *Diagnostics,
) WriteValueError!void {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= nesting_max);

    var emitter: Emitter = undefined;
    emitter.init(w, options);
    emitter.run(value) catch |err| {
        emitter.record_failure(diag, err);
        return err;
    };
    assert(emitter.depth == 0);
}

/// What `Unrepresentable` refused, so the failure message can name it.
const Refusal = enum { none, offset, local_kind, too_long };

/// The members of one open container.
const Members = union(enum) {
    array: []const Value,
    map: []const Map.Entry,
};

/// One open container: how many members were started and which one is being written.
const Frame = struct {
    members: Members,
    /// Members started so far, `<=` the member count.
    emitted: u64,

    fn member_count(frame: *const Frame) u64 {
        return switch (frame.members) {
            .array => |items| items.len,
            .map => |entries| entries.len,
        };
    }

    /// The path segment of the member written last, or `.none` before the first one.
    fn segment(frame: *const Frame) Segment {
        assert(frame.emitted <= frame.member_count());
        if (frame.emitted == 0) return .none;
        const current = frame.emitted - 1;
        return switch (frame.members) {
            .array => .{ .index = current },
            .map => |entries| .{ .key = entries[current].key },
        };
    }
};

const Emitter = struct {
    w: *std.Io.Writer,
    options: StringifyOptions,
    frames: [nesting_max]Frame,
    /// Open containers: `frames[0..depth]`, `depth <= options.depth_max`.
    depth: u32,
    refusal: Refusal,

    fn init(emitter: *Emitter, w: *std.Io.Writer, options: StringifyOptions) void {
        assert(options.depth_max <= nesting_max);
        emitter.w = w;
        emitter.options = options;
        emitter.depth = 0;
        emitter.refusal = .none;
        assert(emitter.depth == 0);
    }

    fn run(emitter: *Emitter, root: Value) WriteValueError!void {
        assert(emitter.depth == 0);
        try emitter.begin_value(root);
        // Each step starts one member or closes one frame, so there are at most twice as many
        // steps as nodes; a tree is memory-resident at 32 bytes a node, far below maxInt(usize).
        for (0..std.math.maxInt(usize)) |_| {
            if (emitter.depth == 0) return;
            try emitter.step();
        }
        unreachable; // proof: the tree is finite and every step consumes one member or frame.
    }

    fn begin_value(emitter: *Emitter, value: Value) WriteValueError!void {
        switch (value) {
            .array => |items| {
                try emitter.open(.{ .array = items });
                try emitter.write_head(.array, items.len);
            },
            .map => |map| {
                map.check_invariants();
                try emitter.open(.{ .map = map.items() });
                try emitter.write_head(.map, map.count);
            },
            else => try emitter.write_scalar(value),
        }
    }

    /// Pushes the frame; the head follows, so a failure inside it names the container.
    fn open(emitter: *Emitter, members: Members) WriteValueError!void {
        assert(emitter.depth <= emitter.options.depth_max);
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
        emitter.frames[emitter.depth] = .{ .members = members, .emitted = 0 };
        emitter.depth += 1;
        // An empty container is complete as soon as its head is out.
        if (emitter.frames[emitter.depth - 1].member_count() == 0) emitter.depth -= 1;
    }

    fn step(emitter: *Emitter) WriteValueError!void {
        assert(emitter.depth > 0);
        const frame = &emitter.frames[emitter.depth - 1];
        assert(frame.emitted <= frame.member_count());
        if (frame.emitted == frame.member_count()) {
            emitter.depth -= 1;
            return;
        }
        const index = frame.emitted;
        frame.emitted += 1;
        switch (frame.members) {
            .array => |items| try emitter.begin_value(items[index]),
            .map => |entries| {
                try emitter.write_str(entries[index].key);
                try emitter.begin_value(entries[index].value);
            },
        }
    }

    fn write_head(emitter: *Emitter, kind: enum { array, map }, count: u64) WriteValueError!void {
        if (count > length_max) return emitter.refuse(.too_long);
        const w = emitter.w;
        const small: u8 = if (kind == .array) 0x90 else 0x80;
        if (count <= 15) {
            try w.writeByte(small | @as(u8, @intCast(count)));
        } else if (count <= std.math.maxInt(u16)) {
            try w.writeByte(if (kind == .array) 0xdc else 0xde);
            try w.writeInt(u16, @intCast(count), .big);
        } else {
            try w.writeByte(if (kind == .array) 0xdd else 0xdf);
            try w.writeInt(u32, @intCast(count), .big);
        }
    }

    fn write_scalar(emitter: *Emitter, value: Value) WriteValueError!void {
        const w = emitter.w;
        switch (value) {
            .null => try w.writeByte(0xc0),
            .bool => |flag| try w.writeByte(if (flag) 0xc3 else 0xc2),
            .int => |number| try write_int(w, number),
            .uint => |number| try write_uint(w, number),
            .float => |number| try write_float(w, number),
            .string => |text| try emitter.write_str(text),
            .bytes => |data| try emitter.write_bin(data),
            .timestamp => |stamp| try emitter.write_timestamp(stamp),
            // proof: `begin_value` routes containers to `open`.
            .array, .map => unreachable,
        }
    }

    fn write_str(emitter: *Emitter, text: []const u8) WriteValueError!void {
        if (text.len > length_max) return emitter.refuse(.too_long);
        // proof: the length check above left the only error of `find_invalid` impossible.
        const invalid = core.unicode.find_invalid(text) catch unreachable;
        if (invalid != null) return error.InvalidUtf8;
        const w = emitter.w;
        const len: u32 = @intCast(text.len);
        if (len <= 31) {
            try w.writeByte(0xa0 | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try w.writeAll(&.{ 0xd9, @as(u8, @intCast(len)) });
        } else if (len <= std.math.maxInt(u16)) {
            try w.writeByte(0xda);
            try w.writeInt(u16, @intCast(len), .big);
        } else {
            try w.writeByte(0xdb);
            try w.writeInt(u32, len, .big);
        }
        try w.writeAll(text);
    }

    fn write_bin(emitter: *Emitter, data: []const u8) WriteValueError!void {
        if (data.len > length_max) return emitter.refuse(.too_long);
        const w = emitter.w;
        const len: u32 = @intCast(data.len);
        if (len <= std.math.maxInt(u8)) {
            try w.writeAll(&.{ 0xc4, @as(u8, @intCast(len)) });
        } else if (len <= std.math.maxInt(u16)) {
            try w.writeByte(0xc5);
            try w.writeInt(u16, @intCast(len), .big);
        } else {
            try w.writeByte(0xc6);
            try w.writeInt(u32, len, .big);
        }
        try w.writeAll(data);
    }

    fn write_timestamp(emitter: *Emitter, stamp: Timestamp) WriteValueError!void {
        stamp.check_invariants();
        if (stamp.kind != .instant) return emitter.refuse(.local_kind);
        if (stamp.offset_minutes != null) return emitter.refuse(.offset);
        const w = emitter.w;
        const seconds = stamp.seconds;
        if (stamp.nanoseconds == 0 and seconds >= 0 and seconds <= seconds_ext4_max) {
            try w.writeAll(&.{ 0xd6, 0xff });
            try w.writeInt(u32, @intCast(seconds), .big);
        } else if (seconds >= 0 and seconds <= seconds_ext8_max) {
            const packed_bits = (@as(u64, stamp.nanoseconds) << 34) | @as(u64, @intCast(seconds));
            try w.writeAll(&.{ 0xd7, 0xff });
            try w.writeInt(u64, packed_bits, .big);
        } else {
            try w.writeAll(&.{ 0xc7, 0x0c, 0xff });
            try w.writeInt(u32, stamp.nanoseconds, .big);
            try w.writeInt(i64, seconds, .big);
        }
    }

    fn refuse(emitter: *Emitter, refusal: Refusal) error{Unrepresentable} {
        assert(refusal != .none);
        assert(emitter.refusal == .none);
        emitter.refusal = refusal;
        return error.Unrepresentable;
    }

    /// Writes `diag` for `err`: the key path of the member being written and the reason.
    fn record_failure(emitter: *const Emitter, diag: *Diagnostics, err: WriteValueError) void {
        var path: Path = undefined;
        path.init();
        for (emitter.frames[0..emitter.depth]) |*frame| path.push(frame.segment());
        const reason = failure_reason(err, emitter.refusal);
        context.write_diagnostic(diag, &path, "{s}", .{reason});
        assert(diag.message().len > 0);
    }
};

/// The shortest head of a signed integer. Pure over the writer: the kernel of the hot path.
fn write_int(w: *std.Io.Writer, number: i64) std.Io.Writer.Error!void {
    if (number >= 0) return write_uint(w, @intCast(number));
    if (number >= -32) {
        try w.writeByte(@bitCast(@as(i8, @intCast(number))));
    } else if (number >= std.math.minInt(i8)) {
        try w.writeAll(&.{ 0xd0, @bitCast(@as(i8, @intCast(number))) });
    } else if (number >= std.math.minInt(i16)) {
        try w.writeByte(0xd1);
        try w.writeInt(i16, @intCast(number), .big);
    } else if (number >= std.math.minInt(i32)) {
        try w.writeByte(0xd2);
        try w.writeInt(i32, @intCast(number), .big);
    } else {
        try w.writeByte(0xd3);
        try w.writeInt(i64, number, .big);
    }
}

/// The shortest unsigned head: positive fixint, then uint 8, 16, 32, 64.
fn write_uint(w: *std.Io.Writer, number: u64) std.Io.Writer.Error!void {
    if (number <= 127) {
        try w.writeByte(@intCast(number));
    } else if (number <= std.math.maxInt(u8)) {
        try w.writeAll(&.{ 0xcc, @as(u8, @intCast(number)) });
    } else if (number <= std.math.maxInt(u16)) {
        try w.writeByte(0xcd);
        try w.writeInt(u16, @intCast(number), .big);
    } else if (number <= std.math.maxInt(u32)) {
        try w.writeByte(0xce);
        try w.writeInt(u32, @intCast(number), .big);
    } else {
        try w.writeByte(0xcf);
        try w.writeInt(u64, number, .big);
    }
}

/// `float 32` when it keeps the value bit for bit, else `float 64`; any NaN is `nan_bits`.
fn write_float(w: *std.Io.Writer, number: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(number)) {
        try w.writeByte(0xca);
        return w.writeInt(u32, nan_bits, .big);
    }
    const narrow: f32 = @floatCast(number);
    const widened: f64 = narrow;
    if (@as(u64, @bitCast(widened)) == @as(u64, @bitCast(number))) {
        try w.writeByte(0xca);
        try w.writeInt(u32, @bitCast(narrow), .big);
    } else {
        try w.writeByte(0xcb);
        try w.writeInt(u64, @bitCast(number), .big);
    }
}

/// The reason text of `err`; `refusal` says what `Unrepresentable` refused.
fn failure_reason(err: WriteValueError, refusal: Refusal) []const u8 {
    // proof: the five variants of `WriteValueError` are all handled; none is a cancelation.
    switch (err) {
        error.Unrepresentable => return switch (refusal) {
            .offset => "timestamp with an offset cannot be written as MessagePack",
            .local_kind => "local timestamp cannot be written as MessagePack",
            .too_long => "length exceeds the MessagePack limit of 2^32-1",
            // proof: `refuse` sets the refusal before it returns the error.
            .none => unreachable,
        },
        error.TooDeep => return "exceeds the depth limit",
        error.InvalidUtf8 => return "string is not valid UTF-8",
        error.InputTooLarge => return "string is too large",
        error.WriteFailed => return "output writer failed",
    }
}

test {
    _ = @import("encoder_test.zig");
}

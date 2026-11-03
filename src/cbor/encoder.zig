//! cbor/encoder — a `Value` onto a `std.Io.Writer` as CBOR (ADR 0006 sections 6, 7, 8).
//!
//! Preferred serialization (RFC 8949 section 4.1) with no policy knobs but two options: every
//! integer takes the shortest head (a non-negative `.int` and a `.uint` are major type 0, so
//! `.uint = 5` is the byte `05`); a float is the shortest of f16, f32 and f64 that keeps the
//! value bit for bit (`inf`, `-inf` and `-0.0` included); every NaN is the one quiet positive
//! NaN `f9 7e00`; lengths are always definite. A string is a text string after a strict UTF-8
//! check, `.bytes` a byte string. `deterministic` (section 4.2.1) additionally writes every map
//! with its keys sorted shorter-first, equal lengths bytewise, by repeated selection over the
//! `Map` (no allocation, O(n^2) compares); without it a map is written in insertion order.
//!
//! A `.timestamp` is tag 0 with `core.timestamp.format` text when it has an offset, else tag 1
//! with the integer seconds, or with an f64 when nanoseconds are not zero and decoding that
//! float returns the same seconds and nanoseconds; a local kind, a year outside 0000-9999 and an
//! inexact fraction are `Unrepresentable`. A tag is one nesting level, as the decoder counts it,
//! so a timestamp needs `depth < depth_max` or it is `TooDeep`.
//!
//! No recursion: the open containers live on a fixed `nesting_max` frame stack and `step` runs
//! until it is empty. `InputTooLarge` is reached through the UTF-8 check on a string longer
//! than `maxInt(u32)`. Allocation: none. Output goes to the caller's writer as it is produced,
//! so a failure leaves a prefix in it. Every error return writes `diag` once (the key path of
//! the failing member, ADR 0002 grammar); success never does.

const std = @import("std");
const core = @import("../core.zig");
const context = @import("../reflect/context.zig");
const tree = @import("tree.zig");
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
    /// Containers and tags may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
    /// Sort map keys by their encoded bytes (RFC 8949 section 4.2.1); insertion order if false.
    deterministic: bool,
};

/// Every way `write` can fail (5 variants). `WriteFailed` is the caller's writer failing.
pub const WriteValueError = core.unicode_escape.WriteError || error{ Unrepresentable, TooDeep };

comptime {
    assert(@typeInfo(WriteValueError).error_set.?.len == 5);
}

/// The one NaN the encoder writes, as half-precision bits.
const nan_bits: u16 = 0x7e00;

/// Writes `value` to `w` as one CBOR item. The `Value` is only read; it may be any tree, not
/// just one a parser built. On error `diag` holds the key path and the reason, and `w` holds
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
const Refusal = enum { none, local_kind, text_range, fraction };

/// The members of one open container.
const Members = union(enum) {
    array: []const Value,
    map: []const Map.Entry,
};

/// One open container: how many members were started and which key is being written.
const Frame = struct {
    members: Members,
    /// Members started so far, `<=` the member count.
    emitted: u64,
    /// The key of the map entry started last; meaningful for a map with `emitted > 0`.
    key_current: []const u8,

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
        return switch (frame.members) {
            .array => .{ .index = frame.emitted - 1 },
            .map => .{ .key = frame.key_current },
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
                try write_head(emitter.w, 4, items.len);
            },
            .map => |map| {
                map.check_invariants();
                try emitter.open(.{ .map = map.items() });
                try write_head(emitter.w, 5, map.count);
            },
            else => try emitter.write_scalar(value),
        }
    }

    /// Pushes the frame; the head follows, so a failure inside it names the container.
    fn open(emitter: *Emitter, members: Members) WriteValueError!void {
        assert(emitter.depth <= emitter.options.depth_max);
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
        emitter.frames[emitter.depth] = .{ .members = members, .emitted = 0, .key_current = "" };
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
        switch (frame.members) {
            .array => |items| {
                frame.emitted += 1;
                try emitter.begin_value(items[index]);
            },
            .map => |entries| {
                const entry = if (emitter.options.deterministic)
                    select_next(entries, frame.key_current, index > 0)
                else
                    &entries[index];
                frame.emitted += 1;
                frame.key_current = entry.key;
                try emitter.write_text(entry.key);
                try emitter.begin_value(entry.value);
            },
        }
    }

    fn write_scalar(emitter: *Emitter, value: Value) WriteValueError!void {
        const w = emitter.w;
        switch (value) {
            .null => try w.writeByte(0xf6),
            .bool => |flag| try w.writeByte(if (flag) 0xf5 else 0xf4),
            .int => |number| try write_int(w, number),
            .uint => |number| try write_head(w, 0, number),
            .float => |number| try write_float(w, number),
            .string => |text| try emitter.write_text(text),
            .bytes => |data| {
                try write_head(w, 2, data.len);
                try w.writeAll(data);
            },
            .timestamp => |stamp| try emitter.write_timestamp(stamp),
            // proof: `begin_value` routes containers to `open`.
            .array, .map => unreachable,
        }
    }

    fn write_text(emitter: *Emitter, text: []const u8) WriteValueError!void {
        const invalid = core.unicode.find_invalid(text) catch return error.InputTooLarge;
        if (invalid != null) return error.InvalidUtf8;
        try write_head(emitter.w, 3, text.len);
        try emitter.w.writeAll(text);
    }

    fn write_timestamp(emitter: *Emitter, stamp: Timestamp) WriteValueError!void {
        stamp.check_invariants();
        if (stamp.kind != .instant) return emitter.refuse(.local_kind);
        // The tag is a nesting level for the decoder (ADR 0006 section 5).
        if (emitter.depth >= emitter.options.depth_max) return error.TooDeep;
        const w = emitter.w;
        if (stamp.offset_minutes != null) {
            var buffer: [core.timestamp.text_max]u8 = undefined;
            const text = core.timestamp.format(stamp, &buffer) catch
                return emitter.refuse(.text_range);
            try w.writeByte(0xc0);
            try write_head(w, 3, text.len);
            return w.writeAll(text);
        }
        if (stamp.nanoseconds == 0) {
            try w.writeByte(0xc1);
            return write_int(w, stamp.seconds);
        }
        const whole: f64 = @floatFromInt(stamp.seconds);
        const fraction: f64 = @floatFromInt(stamp.nanoseconds);
        const number = whole + fraction / 1e9;
        const back = tree.timestamp_from_float(number) catch return emitter.refuse(.fraction);
        if (back.seconds != stamp.seconds) return emitter.refuse(.fraction);
        if (back.nanoseconds != stamp.nanoseconds) return emitter.refuse(.fraction);
        try w.writeByte(0xc1);
        try write_float(w, number);
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

/// The entry with the smallest key above `last` in the section 4.2.1 order, or the smallest of
/// all when `has_last` is false. Precondition: keys are unique and `last` is a key of `entries`
/// when `has_last`; so an entry above `last` exists while members remain.
fn select_next(entries: []const Map.Entry, last: []const u8, has_last: bool) *const Map.Entry {
    assert(entries.len > 0);
    var best: ?*const Map.Entry = null;
    for (entries) |*entry| {
        if (has_last and key_order(entry.key, last) != .gt) continue;
        if (best) |current| {
            if (key_order(entry.key, current.key) != .lt) continue;
        }
        best = entry;
    }
    // proof: the caller started this member only while one key above `last` is still unwritten.
    return best.?;
}

/// Encoded-form order of two text keys: the head grows with the length, so shorter sorts first.
fn key_order(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

/// A head of `major` (0-7) with the shortest argument form. The kernel of the hot path.
fn write_head(w: *std.Io.Writer, major: u8, argument: u64) std.Io.Writer.Error!void {
    assert(major <= 7);
    const lead: u8 = major << 5;
    if (argument < 24) {
        try w.writeByte(lead | @as(u8, @intCast(argument)));
    } else if (argument <= std.math.maxInt(u8)) {
        try w.writeAll(&.{ lead | 24, @as(u8, @intCast(argument)) });
    } else if (argument <= std.math.maxInt(u16)) {
        try w.writeByte(lead | 25);
        try w.writeInt(u16, @intCast(argument), .big);
    } else if (argument <= std.math.maxInt(u32)) {
        try w.writeByte(lead | 26);
        try w.writeInt(u32, @intCast(argument), .big);
    } else {
        try w.writeByte(lead | 27);
        try w.writeInt(u64, argument, .big);
    }
}

/// Major type 0 for a non-negative number, major type 1 with `-1 - n` for a negative one.
fn write_int(w: *std.Io.Writer, number: i64) std.Io.Writer.Error!void {
    if (number >= 0) return write_head(w, 0, @intCast(number));
    // proof: `number < 0`, so `-1 - number` is in `0..maxInt(i64)` and cannot overflow.
    const magnitude: u64 = @intCast(-1 - number);
    return write_head(w, 1, magnitude);
}

/// f16, f32 or f64: the first that keeps the value bit for bit; any NaN is `nan_bits`.
fn write_float(w: *std.Io.Writer, number: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(number)) {
        try w.writeByte(0xf9);
        return w.writeInt(u16, nan_bits, .big);
    }
    const number_bits: u64 = @bitCast(number);
    const half: f16 = @floatCast(number);
    const half_wide: f64 = half;
    if (@as(u64, @bitCast(half_wide)) == number_bits) {
        try w.writeByte(0xf9);
        return w.writeInt(u16, @bitCast(half), .big);
    }
    const narrow: f32 = @floatCast(number);
    const narrow_wide: f64 = narrow;
    if (@as(u64, @bitCast(narrow_wide)) == number_bits) {
        try w.writeByte(0xfa);
        return w.writeInt(u32, @bitCast(narrow), .big);
    }
    try w.writeByte(0xfb);
    try w.writeInt(u64, number_bits, .big);
}

/// The reason text of `err`; `refusal` says what `Unrepresentable` refused.
fn failure_reason(err: WriteValueError, refusal: Refusal) []const u8 {
    // proof: the five variants of `WriteValueError` are all handled; none is a cancelation.
    switch (err) {
        error.Unrepresentable => return switch (refusal) {
            .local_kind => "local timestamp cannot be written as CBOR",
            .text_range => "timestamp year is outside 0000-9999 for CBOR tag 0",
            .fraction => "timestamp fraction is not exact as a CBOR float",
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

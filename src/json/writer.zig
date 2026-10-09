//! json/writer — a `Value` onto a `std.Io.Writer` as RFC 8259 text (ADR 0003 section 7).
//!
//! No recursion: the open containers live on a fixed `nesting_max` frame stack, and `step` runs
//! until it is empty. `Layout.minified` writes no whitespace; `Layout.pretty` puts every member
//! and element on its own line, `indent_spaces` per level, `"key": value`, and keeps empty
//! containers as `{}` and `[]`. No final newline. `sort_keys` emits members in ascending byte
//! order of the key by selection (each step scans for the smallest key above the last one
//! written): no allocation, O(n^2) key compares per object. It is not RFC 8785.
//!
//! Round-trip: `.int` and `.uint` are written in decimal; a `.float` is shortest round-trip
//! digits that always carry a `.` or an exponent, so it re-parses as `.float` with the same bits.
//! A `.bytes`, a `.timestamp`, NaN and infinity have no JSON form that re-parses as the same
//! `Value`, so they are `Unrepresentable`; the caller converts them on purpose.
//!
//! Allocation: none. The output goes to the caller's writer; floats are formatted in a
//! `float_text_len_max` stack buffer. Output is written as it is produced, so a failure leaves
//! a prefix in the writer. Every error return writes `diag` exactly once (the key path of the
//! failing member, ADR 0002 grammar); success never does.

const std = @import("std");
const core = @import("../core.zig");
const context = @import("../reflect/context.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Map = core.Map;
const Path = context.Path;
const Segment = context.Segment;
const Value = core.Value;
const nesting_max = core.value.nesting_max;

/// The widest indent `Layout.pretty` accepts.
pub const indent_spaces_max: u8 = 8;

/// The longest text of one float: `-1.2345678901234567e-308` is 24 bytes, `.0` makes 26.
pub const float_text_len_max: u32 = 32;

/// Whitespace of the output.
pub const Layout = union(enum) {
    minified,
    pretty: Pretty,
};

/// `1 <= indent_spaces <= indent_spaces_max`.
pub const Pretty = struct { indent_spaces: u8 };

/// Every field is required: no defaults.
pub const StringifyOptions = struct {
    layout: Layout,
    /// Members in ascending byte order of the key instead of insertion order.
    sort_keys: bool,
    /// Whether non-ASCII text is written through or as `\uXXXX`.
    escape: core.unicode_escape.EscapePolicy,
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
};

/// Every way `write` can fail (5 variants). `WriteFailed` is the caller's writer failing.
pub const WriteValueError = core.unicode_escape.WriteError || error{ Unrepresentable, TooDeep };

comptime {
    assert(@typeInfo(WriteValueError).error_set.?.len == 5);
    assert(float_text_len_max >= 26);
}

/// Writes `value` to `w` as one JSON document. The `Value` is only read; it may be any tree,
/// not just one a parser built. On error `diag` holds the key path and the reason, and `w` holds
/// whatever was written before the failure.
/// Preconditions: `1 <= options.depth_max <= nesting_max`; under `.pretty`,
/// `1 <= indent_spaces <= indent_spaces_max`; every `Map` in `value` obeys its invariant
/// (no duplicate key), which `sort_keys` relies on.
pub fn write(
    w: *std.Io.Writer,
    value: Value,
    options: StringifyOptions,
    diag: *Diagnostics,
) WriteValueError!void {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= nesting_max);
    switch (options.layout) {
        .minified => {},
        .pretty => |layout| {
            assert(layout.indent_spaces >= 1);
            assert(layout.indent_spaces <= indent_spaces_max);
        },
    }

    var emitter: Emitter = undefined;
    emitter.init(w, options);
    emitter.run(value) catch |err| {
        emitter.record_failure(diag, err);
        return err;
    };
    assert(emitter.depth == 0);
}

/// What `write_scalar` refused, so the failure message can name it.
const Refusal = enum { none, bytes, timestamp, nan, infinity };

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
    /// Index of the member being written; read only when `emitted > 0`.
    current: u64,
    /// The key of the member started last; `sort_keys` selects the next one above it.
    last_key: ?[]const u8,

    fn member_count(frame: *const Frame) u64 {
        return switch (frame.members) {
            .array => |items| items.len,
            .map => |entries| entries.len,
        };
    }

    /// The path segment of the member being written, or `.none` before the first one.
    fn segment(frame: *const Frame) Segment {
        assert(frame.emitted <= frame.member_count());
        if (frame.emitted == 0) return .none;
        assert(frame.current < frame.member_count());
        return switch (frame.members) {
            .array => .{ .index = frame.current },
            .map => |entries| .{ .key = entries[frame.current].key },
        };
    }
};

/// The smallest key above `last` (or the smallest key, when null). Keys are unique, so exactly
/// one entry qualifies while members remain.
fn select_sorted(entries: []const Map.Entry, last: ?[]const u8) u64 {
    assert(entries.len > 0);
    var best: ?u64 = null;
    for (entries, 0..) |entry, index| {
        if (last) |floor| {
            if (std.mem.order(u8, entry.key, floor) != .gt) continue;
        }
        if (best) |chosen| {
            if (std.mem.order(u8, entry.key, entries[chosen].key) != .lt) continue;
        }
        best = index;
    }
    // proof: unique keys leave one key above `last` while members remain.
    return best orelse unreachable;
}

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
        // Each step starts one member or closes one container, so there are at most twice as many
        // steps as nodes; a tree is memory-resident at 32 bytes a node, far below maxInt(usize).
        for (0..std.math.maxInt(usize)) |_| {
            if (emitter.depth == 0) return;
            try emitter.step();
        }
        unreachable; // proof: the tree is finite and every step consumes one member or frame.
    }

    fn begin_value(emitter: *Emitter, value: Value) WriteValueError!void {
        switch (value) {
            .array => |items| try emitter.open('[', .{ .array = items }),
            .map => |map| {
                map.check_invariants();
                try emitter.open('{', .{ .map = map.items() });
            },
            else => try emitter.write_scalar(value),
        }
    }

    fn open(emitter: *Emitter, bracket: u8, members: Members) WriteValueError!void {
        assert(emitter.depth <= emitter.options.depth_max);
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
        try emitter.w.writeByte(bracket);
        emitter.frames[emitter.depth] = .{
            .members = members,
            .emitted = 0,
            .current = 0,
            .last_key = null,
        };
        emitter.depth += 1;
    }

    fn step(emitter: *Emitter) WriteValueError!void {
        assert(emitter.depth > 0);
        const frame = &emitter.frames[emitter.depth - 1];
        assert(frame.emitted <= frame.member_count());
        const first = frame.emitted == 0;
        switch (frame.members) {
            .array => |items| {
                if (frame.emitted == items.len) return emitter.close(']');
                frame.current = frame.emitted;
                frame.emitted += 1;
                try emitter.separate(first);
                try emitter.begin_value(items[frame.current]);
            },
            .map => |entries| {
                if (frame.emitted == entries.len) return emitter.close('}');
                frame.current = if (emitter.options.sort_keys)
                    select_sorted(entries, frame.last_key)
                else
                    frame.emitted;
                frame.emitted += 1;
                frame.last_key = entries[frame.current].key;
                try emitter.separate(first);
                try emitter.write_string(entries[frame.current].key);
                try emitter.write_colon();
                try emitter.begin_value(entries[frame.current].value);
            },
        }
    }

    fn close(emitter: *Emitter, bracket: u8) WriteValueError!void {
        assert(emitter.depth > 0);
        const frame = &emitter.frames[emitter.depth - 1];
        assert(frame.emitted == frame.member_count());
        // The frame is popped first, so a failure below names the container, not its last member.
        const depth_before = emitter.depth;
        emitter.depth -= 1;
        if (frame.emitted > 0) try emitter.newline_indent(emitter.depth);
        try emitter.w.writeByte(bracket);
        assert(emitter.depth + 1 == depth_before);
    }

    /// Before a member: a comma unless it is the first, then the line break of `.pretty`.
    fn separate(emitter: *Emitter, first: bool) WriteValueError!void {
        if (!first) try emitter.w.writeByte(',');
        try emitter.newline_indent(emitter.depth);
    }

    fn newline_indent(emitter: *Emitter, levels: u32) WriteValueError!void {
        assert(levels <= nesting_max);
        switch (emitter.options.layout) {
            .minified => {},
            .pretty => |layout| {
                try emitter.w.writeByte('\n');
                try emitter.w.splatByteAll(' ', @as(usize, levels) * layout.indent_spaces);
            },
        }
    }

    fn write_colon(emitter: *Emitter) WriteValueError!void {
        try emitter.w.writeByte(':');
        if (emitter.options.layout == .pretty) try emitter.w.writeByte(' ');
    }

    fn write_string(emitter: *Emitter, text: []const u8) WriteValueError!void {
        try emitter.w.writeByte('"');
        try core.unicode_escape.write_escaped(emitter.w, text, emitter.options.escape);
        try emitter.w.writeByte('"');
    }

    fn write_scalar(emitter: *Emitter, value: Value) WriteValueError!void {
        switch (value) {
            .null => try emitter.w.writeAll("null"),
            .bool => |flag| try emitter.w.writeAll(if (flag) "true" else "false"),
            .int => |number| try emitter.w.print("{d}", .{number}),
            .uint => |number| try emitter.w.print("{d}", .{number}),
            .float => |number| try emitter.write_float(number),
            .string => |text| try emitter.write_string(text),
            .bytes => return emitter.refuse(.bytes),
            .timestamp => return emitter.refuse(.timestamp),
            // proof: `begin_value` routes containers to `open`.
            .array, .map => unreachable,
        }
    }

    fn refuse(emitter: *Emitter, refusal: Refusal) error{Unrepresentable} {
        assert(refusal != .none);
        assert(emitter.refusal == .none);
        emitter.refusal = refusal;
        return error.Unrepresentable;
    }

    fn write_float(emitter: *Emitter, number: f64) WriteValueError!void {
        if (std.math.isNan(number)) return emitter.refuse(.nan);
        if (std.math.isInf(number)) return emitter.refuse(.infinity);
        var buffer: [float_text_len_max]u8 = undefined;
        try emitter.w.writeAll(format_float(&buffer, number));
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

/// The reason text of `err`; `refusal` says what `Unrepresentable` refused.
fn failure_reason(err: WriteValueError, refusal: Refusal) []const u8 {
    // proof: the five variants of `WriteValueError` are all handled; none is a cancelation.
    switch (err) {
        error.Unrepresentable => return switch (refusal) {
            .bytes => "bytes cannot be written as JSON",
            .timestamp => "timestamp cannot be written as JSON",
            .nan => "NaN cannot be written as JSON",
            .infinity => "infinity cannot be written as JSON",
            // proof: `refuse` sets the refusal before it returns the error.
            .none => unreachable,
        },
        error.TooDeep => return "exceeds the depth limit",
        error.InvalidUtf8 => return "string is not valid UTF-8",
        error.InputTooLarge => return "string is too large",
        error.WriteFailed => return "output writer failed",
    }
}

/// Shortest round-trip digits of a finite `number`, always with a `.` or an exponent so the text
/// re-parses as a float. `{d}` when `number` is zero or `1e-6 <= |number| < 1e21`, else `{e}`:
/// `{d}` of `5e-324` would be over 300 bytes.
/// Preconditions: `number` is finite.
fn format_float(buffer: *[float_text_len_max]u8, number: f64) []const u8 {
    assert(std.math.isFinite(number));
    const magnitude = @abs(number);
    const plain = magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21);
    const text = if (plain) format_plain(buffer, number) else format_exponent(buffer, number);
    if (std.mem.findAny(u8, text, ".e") != null) return text;
    assert(text.len + 2 <= buffer.len);
    buffer[text.len] = '.';
    buffer[text.len + 1] = '0';
    return buffer[0 .. text.len + 2];
}

fn format_plain(buffer: *[float_text_len_max]u8, number: f64) []const u8 {
    // proof: 17 digits, 5 zeros, a sign and a point (25 bytes) fit in float_text_len_max - 2.
    return std.fmt.bufPrint(buffer, "{d}", .{number}) catch unreachable;
}

fn format_exponent(buffer: *[float_text_len_max]u8, number: f64) []const u8 {
    // proof: at most 17 digits, a sign, a point and "e-308" fit in float_text_len_max - 2.
    return std.fmt.bufPrint(buffer, "{e}", .{number}) catch unreachable;
}

test {
    _ = @import("writer_test.zig");
}

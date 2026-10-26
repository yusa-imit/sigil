//! toml/writer — a `Value` onto a `std.Io.Writer` as TOML 1.0 text (ADR 0005 section 8).
//!
//! Order-preserving: entries come out in insertion order, so parse -> write -> parse is `eql`
//! for every tree the writer accepts. TOML wants the key/value lines of a table before its
//! sub-tables, so an entry is written in header form (`[a.b]`, `[[a]]`) only when every later
//! entry of the same map is a map or a non-empty array of maps (the trailing run); an earlier
//! map, and every map inside an array that is not a pure array of maps, is written inline
//! (`k = { a = 1 }`). No dotted keys, no comments, no pretty-print option. A blank line
//! precedes every header that is not the first output.
//!
//! No recursion: header-form tables live on a fixed `nesting_max` frame stack and inline values
//! on a second one. Depth counts containers on the path including the root, the same count the
//! parser uses (127 header segments pass, 128 are `TooDeep`; `[[a]]` is an array and an element).
//!
//! Strings are basic strings (`core.unicode_escape.write_escaped`, non-ASCII raw); keys are bare
//! when they match `[A-Za-z0-9_-]+`, else basic-quoted. A float always carries a `.` or an
//! exponent, or is `inf`, `-inf` or `nan`. A `.uint` up to `maxInt(i64)` is an integer. `.null`,
//! `.bytes`, a `.uint` above `maxInt(i64)` and a timestamp with no four-digit year are
//! `Unrepresentable`; a root that is not a map is `RootNotTable`.
//!
//! Allocation: none. Output is written as it is produced, so a failure leaves a prefix in the
//! writer. Every error return writes `diag` exactly once (the key path of the failing member,
//! ADR 0002 grammar); success never does.

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

/// Every field is required: no defaults.
pub const StringifyOptions = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
};

/// Every way `write` can fail (6 variants). `WriteFailed` is the caller's writer failing.
pub const WriteValueError = core.unicode_escape.WriteError ||
    error{ Unrepresentable, TooDeep, RootNotTable };

comptime {
    assert(@typeInfo(WriteValueError).error_set.?.len == 6);
}

/// Writes `value`, which must be a map, to `w` as one TOML document. The `Value` is only read;
/// it may be any tree, not just one a parser built. On error `diag` holds the key path and the
/// reason, and `w` holds whatever was written before the failure.
/// Preconditions: `1 <= options.depth_max <= nesting_max`; every `Map` in `value` obeys its
/// invariant (no duplicate key), and every timestamp obeys `Timestamp.check_invariants`.
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
    assert(emitter.inline_depth == 0);
}

/// What `write_scalar` refused, so the failure message can name it.
const Refusal = enum { none, null, bytes, uint, timestamp };

/// The members of one open container. `table` and `tables` are header-form frames, `array` and
/// `map` inline ones.
const Members = union(enum) {
    table: []const Map.Entry,
    tables: []const Value,
    array: []const Value,
    map: []const Map.Entry,
};

/// One open container: how many members were started (the one being written is `next - 1`).
const Frame = struct {
    members: Members,
    /// Members started so far, `<=` the member count.
    next: u32,
    /// `table` frames only: entries from this index on are written in header form.
    run_start: u32,

    fn member_count(frame: *const Frame) u32 {
        const count = switch (frame.members) {
            .table, .map => |entries| entries.len,
            .tables, .array => |items| items.len,
        };
        assert(count <= std.math.maxInt(u32));
        return @intCast(count);
    }

    /// The path segment of the member being written, or `.none` before the first one.
    fn segment(frame: *const Frame) Segment {
        assert(frame.next <= frame.member_count());
        if (frame.next == 0) return .none;
        return switch (frame.members) {
            .table, .map => |entries| .{ .key = entries[frame.next - 1].key },
            .tables, .array => .{ .index = frame.next - 1 },
        };
    }
};

/// A map, or a non-empty array of maps: the entries that may be written in header form.
fn is_table_like(value: Value) bool {
    switch (value) {
        .map => return true,
        .array => |items| {
            if (items.len == 0) return false;
            for (items) |item| {
                if (item != .map) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// The index from which every entry is table-like; `entries.len` when the last one is not.
fn trailing_run_start(entries: []const Map.Entry) u32 {
    assert(entries.len <= std.math.maxInt(u32));
    var index: u32 = @intCast(entries.len);
    while (index > 0 and is_table_like(entries[index - 1].value)) index -= 1;
    return index;
}

fn is_bare_key(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

const Emitter = struct {
    w: *std.Io.Writer,
    options: StringifyOptions,
    /// Open header-form containers: `frames[0..depth]`.
    frames: [nesting_max]Frame,
    depth: u32,
    /// Open inline containers of the value being written: `inline_frames[0..inline_depth]`.
    inline_frames: [nesting_max]Frame,
    inline_depth: u32,
    wrote_any: bool,
    refusal: Refusal,

    fn init(emitter: *Emitter, w: *std.Io.Writer, options: StringifyOptions) void {
        assert(options.depth_max <= nesting_max);
        emitter.w = w;
        emitter.options = options;
        emitter.depth = 0;
        emitter.inline_depth = 0;
        emitter.wrote_any = false;
        emitter.refusal = .none;
        assert(emitter.depth == 0);
        assert(emitter.inline_depth == 0);
    }

    fn run(emitter: *Emitter, root: Value) WriteValueError!void {
        assert(emitter.depth == 0);
        if (root != .map) return error.RootNotTable;
        try emitter.push_table(root.map);
        // Each step starts one member or closes one frame, so there are at most twice as many
        // steps as nodes; a tree is memory-resident at 32 bytes a node, far below maxInt(usize).
        for (0..std.math.maxInt(usize)) |_| {
            if (emitter.depth == 0) return;
            try emitter.step();
        }
        unreachable; // proof: the tree is finite and every step consumes one member or frame.
    }

    fn push_table(emitter: *Emitter, map: Map) WriteValueError!void {
        assert(emitter.depth <= emitter.options.depth_max);
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
        map.check_invariants();
        const entries = map.items();
        emitter.frames[emitter.depth] = .{
            .members = .{ .table = entries },
            .next = 0,
            .run_start = trailing_run_start(entries),
        };
        emitter.depth += 1;
    }

    fn push_tables(emitter: *Emitter, items: []const Value) WriteValueError!void {
        assert(emitter.depth <= emitter.options.depth_max);
        assert(items.len > 0);
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
        emitter.frames[emitter.depth] = .{
            .members = .{ .tables = items },
            .next = 0,
            .run_start = 0,
        };
        emitter.depth += 1;
    }

    fn step(emitter: *Emitter) WriteValueError!void {
        assert(emitter.depth > 0);
        const frame = &emitter.frames[emitter.depth - 1];
        assert(frame.next <= frame.member_count());
        if (frame.next == frame.member_count()) {
            emitter.depth -= 1;
            return;
        }
        const index = frame.next;
        frame.next += 1;
        switch (frame.members) {
            .table => |entries| {
                const entry = entries[index];
                if (index < frame.run_start) return emitter.write_pair(entry);
                switch (entry.value) {
                    .map => |map| {
                        try emitter.check_header_depth();
                        try emitter.write_header(false);
                        try emitter.push_table(map);
                    },
                    .array => |items| try emitter.push_tables(items),
                    // proof: `run_start` is the start of the trailing run of table-like values.
                    else => unreachable,
                }
            },
            .tables => |items| {
                try emitter.check_header_depth();
                try emitter.write_header(true);
                try emitter.push_table(items[index].map);
            },
            // proof: inline frames live on `inline_frames`, never on `frames`.
            .array, .map => unreachable,
        }
    }

    /// A header for a table that `push_table` would refuse is not written: the check comes first.
    fn check_header_depth(emitter: *const Emitter) WriteValueError!void {
        if (emitter.depth == emitter.options.depth_max) return error.TooDeep;
    }

    /// `[a.b]` or `[[a.b]]` for the table the open frames lead to: the keys of the members being
    /// written, array indexes skipped.
    fn write_header(emitter: *Emitter, double: bool) WriteValueError!void {
        if (emitter.wrote_any) try emitter.w.writeByte('\n');
        try emitter.w.writeAll(if (double) "[[" else "[");
        var first = true;
        for (emitter.frames[0..emitter.depth]) |*frame| {
            switch (frame.segment()) {
                .key => |key| {
                    if (!first) try emitter.w.writeByte('.');
                    try emitter.write_key(key);
                    first = false;
                },
                .index, .none => {},
            }
        }
        assert(!first);
        try emitter.w.writeAll(if (double) "]]\n" else "]\n");
        emitter.wrote_any = true;
    }

    fn write_pair(emitter: *Emitter, entry: Map.Entry) WriteValueError!void {
        try emitter.write_key(entry.key);
        try emitter.w.writeAll(" = ");
        try emitter.write_inline(entry.value);
        try emitter.w.writeByte('\n');
        emitter.wrote_any = true;
    }

    fn write_key(emitter: *Emitter, key: []const u8) WriteValueError!void {
        if (is_bare_key(key)) return emitter.w.writeAll(key);
        try emitter.write_string(key);
    }

    fn write_string(emitter: *Emitter, text: []const u8) WriteValueError!void {
        try emitter.w.writeByte('"');
        try core.unicode_escape.write_escaped(emitter.w, text, .minimal);
        try emitter.w.writeByte('"');
    }

    /// One value on the current line: a scalar, or a container with its members on an explicit
    /// stack. Precondition: no inline container is open.
    fn write_inline(emitter: *Emitter, value: Value) WriteValueError!void {
        assert(emitter.inline_depth == 0);
        try emitter.begin_inline(value);
        for (0..std.math.maxInt(usize)) |_| {
            if (emitter.inline_depth == 0) return;
            try emitter.inline_step();
        }
        unreachable; // proof: the tree is finite and every step consumes one member or frame.
    }

    fn begin_inline(emitter: *Emitter, value: Value) WriteValueError!void {
        switch (value) {
            .array => |items| try emitter.open_inline(.{ .array = items }, "["),
            .map => |map| {
                map.check_invariants();
                try emitter.open_inline(.{ .map = map.items() }, "{");
            },
            else => try emitter.write_scalar(value),
        }
    }

    fn open_inline(emitter: *Emitter, members: Members, bracket: []const u8) WriteValueError!void {
        const open_count = emitter.depth + emitter.inline_depth;
        assert(open_count <= emitter.options.depth_max);
        if (open_count == emitter.options.depth_max) return error.TooDeep;
        try emitter.w.writeAll(bracket);
        emitter.inline_frames[emitter.inline_depth] = .{
            .members = members,
            .next = 0,
            .run_start = 0,
        };
        emitter.inline_depth += 1;
    }

    fn inline_step(emitter: *Emitter) WriteValueError!void {
        assert(emitter.inline_depth > 0);
        const frame = &emitter.inline_frames[emitter.inline_depth - 1];
        assert(frame.next <= frame.member_count());
        if (frame.next == frame.member_count()) {
            const closer: []const u8 = switch (frame.members) {
                .array => "]",
                .map => if (frame.next == 0) "}" else " }",
                // proof: header-form frames live on `frames`, never on `inline_frames`.
                .table, .tables => unreachable,
            };
            emitter.inline_depth -= 1;
            return emitter.w.writeAll(closer);
        }
        const index = frame.next;
        frame.next += 1;
        switch (frame.members) {
            .array => |items| {
                if (index > 0) try emitter.w.writeAll(", ");
                try emitter.begin_inline(items[index]);
            },
            .map => |entries| {
                try emitter.w.writeAll(if (index > 0) ", " else " ");
                try emitter.write_key(entries[index].key);
                try emitter.w.writeAll(" = ");
                try emitter.begin_inline(entries[index].value);
            },
            // proof: header-form frames live on `frames`, never on `inline_frames`.
            .table, .tables => unreachable,
        }
    }

    fn write_scalar(emitter: *Emitter, value: Value) WriteValueError!void {
        switch (value) {
            .null => return emitter.refuse(.null),
            .bytes => return emitter.refuse(.bytes),
            .bool => |flag| try emitter.w.writeAll(if (flag) "true" else "false"),
            .int => |number| try emitter.w.print("{d}", .{number}),
            .uint => |number| {
                if (number > std.math.maxInt(i64)) return emitter.refuse(.uint);
                try emitter.w.print("{d}", .{number});
            },
            .float => |number| try emitter.write_float(number),
            .string => |text| try emitter.write_string(text),
            .timestamp => |stamp| {
                var buffer: [core.timestamp.text_max]u8 = undefined;
                const text = core.timestamp.format(stamp, &buffer) catch
                    return emitter.refuse(.timestamp);
                try emitter.w.writeAll(text);
            },
            // proof: `begin_inline` routes containers to `open_inline`.
            .array, .map => unreachable,
        }
    }

    fn write_float(emitter: *Emitter, number: f64) WriteValueError!void {
        if (std.math.isNan(number)) return emitter.w.writeAll("nan");
        if (std.math.isInf(number)) return emitter.w.writeAll(if (number < 0) "-inf" else "inf");
        var buffer: [core.number.float_text_len_max]u8 = undefined;
        try emitter.w.writeAll(core.number.format_float(&buffer, number));
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
        for (emitter.inline_frames[0..emitter.inline_depth]) |*frame| path.push(frame.segment());
        const reason = failure_reason(err, emitter.refusal);
        context.write_diagnostic(diag, &path, "{s}", .{reason});
        assert(diag.message().len > 0);
    }
};

/// The reason text of `err`; `refusal` says what `Unrepresentable` refused.
fn failure_reason(err: WriteValueError, refusal: Refusal) []const u8 {
    // proof: the six variants of `WriteValueError` are all handled; none is a cancelation.
    switch (err) {
        error.Unrepresentable => return switch (refusal) {
            .null => "null cannot be written as TOML",
            .bytes => "bytes cannot be written as TOML",
            .uint => "integer above 9223372036854775807 cannot be written as TOML",
            .timestamp => "timestamp has no four-digit year, so TOML cannot hold it",
            // proof: `refuse` sets the refusal before it returns the error.
            .none => unreachable,
        },
        error.RootNotTable => return "the root of a TOML document must be a table",
        error.TooDeep => return "exceeds the depth limit",
        error.InvalidUtf8 => return "string is not valid UTF-8",
        error.InputTooLarge => return "string is too large",
        error.WriteFailed => return "output writer failed",
    }
}

test {
    _ = @import("writer_test.zig");
}

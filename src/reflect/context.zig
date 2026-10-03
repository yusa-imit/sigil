//! reflect/context — the error sets, the key `Path` and the `Context` that every `reflect.parse`
//! call and every `sigilParse` hook runs under (ADR 0002 sections 1-3). `Context.fail` renders
//! `"{path}: {reason}"` into the one `Diagnostics` of the call; `Context.parse_child` continues
//! the path and the depth of the caller, so recursion through a hook is bounded by
//! `core.value.nesting_max`. Allocation: none. `Path` is an inline stack of `nesting_max`
//! segments that lives on the stack of `reflect.parse`; every message is built in fixed buffers:
//! the reason first (cut at `reason_len_max`), then the path from its last segment backwards into
//! the remaining budget, so a long path keeps its most specific tail behind a leading `...`.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("../core.zig");
const parse_mod = @import("parse.zig");
const stringify_mod = @import("stringify.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const nesting_max = core.value.nesting_max;
const position_none = core.diagnostics.position_none;
const truncation_marker = core.diagnostics.truncation_marker;
const message_len_max = core.diagnostics.default_limits.message_len_max;

/// Every way `reflect.parse` can fail. A hook returns these and nothing else; its specifics
/// go into the diagnostics message.
pub const ParseError = error{
    TypeMismatch,
    IntegerOutOfRange,
    InexactNumber,
    FloatOutOfRange,
    UnknownEnumValue,
    MissingField,
    UnknownField,
    LengthMismatch,
    InvalidValue,
    TooDeep,
    OutOfMemory,
};

/// Every way `reflect.stringify` can fail.
pub const StringifyError = error{ InvalidUtf8, InputTooLarge, TooDeep, OutOfMemory };

/// One step of a key path: a map key, an array index, or nothing (renders as no text).
pub const Segment = union(enum) { key: []const u8, index: u64, none };

/// The longest reason text; a longer reason is cut and `truncation_marker` is appended.
pub const reason_len_max: u32 = 128;

/// The stack of segments from the root to the value being parsed.
pub const Path = struct {
    segments: [nesting_max]Segment,
    /// Live segments are `segments[0..count]`. Invariant: `count <= nesting_max`.
    count: u32,

    /// Empties `path` in place.
    pub fn init(path: *Path) void {
        path.count = 0;
        assert(path.count == 0);
        assert(path.segments.len == nesting_max);
    }

    /// Precondition: `path.count < nesting_max`.
    pub fn push(path: *Path, segment: Segment) void {
        assert(path.count < nesting_max);
        const before = path.count;
        path.segments[path.count] = segment;
        path.count += 1;
        assert(path.count == before + 1);
    }

    /// Precondition: `path.count > 0`.
    pub fn pop(path: *Path) void {
        assert(path.count > 0);
        assert(path.count <= nesting_max);
        path.count -= 1;
    }
};

/// What a parse call threads through itself and through hooks. Hooks read `tree` and call
/// `fail` and `parse_child`; the rest is reflect-owned.
pub const Context = struct {
    tree: *ValueTree,
    diag: *Diagnostics,
    path: *Path,
    /// Invariant: `path.count <= depth <= nesting_max`.
    depth: u32,
    /// True once `diag` holds this call's message; reflect then does not write a fallback.
    diag_written: bool,

    /// Initializes `context` in place: depth 0, nothing written.
    /// Precondition: `path` is empty.
    pub fn init(context: *Context, tree: *ValueTree, diag: *Diagnostics, path: *Path) void {
        assert(path.count == 0);
        assert(@intFromPtr(tree) != 0);
        context.* = .{
            .tree = tree,
            .diag = diag,
            .path = path,
            .depth = 0,
            .diag_written = false,
        };
        assert(context.depth == 0);
    }

    /// Writes `"{path}: {reason}"` to the diagnostics at `position_none`, marks the diagnostics
    /// written, and returns `err` so a caller can `return context.fail(...)`.
    /// Precondition: `path.count <= depth <= nesting_max`.
    pub fn fail(
        context: *Context,
        err: ParseError,
        comptime format: []const u8,
        args: anytype,
    ) ParseError {
        assert(context.path.count <= context.depth);
        assert(context.depth <= nesting_max);
        context.write_message(format, args);
        return err;
    }

    /// `fail` for the stringify direction: the same message grammar, a `StringifyError`.
    /// Precondition: `path.count <= depth <= nesting_max`.
    pub fn fail_stringify(
        context: *Context,
        err: StringifyError,
        comptime format: []const u8,
        args: anytype,
    ) StringifyError {
        assert(context.path.count <= context.depth);
        assert(context.depth <= nesting_max);
        context.write_message(format, args);
        return err;
    }

    fn write_message(context: *Context, comptime format: []const u8, args: anytype) void {
        assert(context.path.count <= context.depth);
        assert(context.depth <= nesting_max);
        var reason_buffer: [reason_len_max + 1]u8 = @splat(0);
        const reason = format_reason(&reason_buffer, format, args);
        var out: [message_len_max]u8 = undefined;
        const message = render_message(context.path, reason, &out);
        context.diag.* = Diagnostics.init(position_none, position_none, message, null);
        context.diag_written = true;
    }

    /// Stringifies `value` as `U` one level below the current one, under `segment`; the mirror of
    /// `parse_child`. On return the path and the depth are what they were on entry.
    /// Fails with `TooDeep` when the depth is already `nesting_max`.
    /// Precondition: `path.count <= depth <= nesting_max`.
    pub fn stringify_child(
        context: *Context,
        comptime U: type,
        segment: Segment,
        value: *const U,
    ) StringifyError!Value {
        assert(context.path.count <= context.depth);
        assert(context.depth <= nesting_max);
        if (context.depth >= nesting_max) {
            const text = "exceeds nesting depth limit {d}";
            return context.fail_stringify(error.TooDeep, text, .{nesting_max});
        }
        context.path.push(segment);
        context.depth += 1;
        defer context.leave_child();

        return stringify_mod.stringify_value(U, context, value);
    }

    /// Parses `value` as `U` one level below the current one, under `segment`. On return the
    /// path and the depth are what they were on entry, whether or not it failed.
    /// Fails with `TooDeep` when the depth is already `nesting_max`.
    /// Precondition: `path.count <= depth <= nesting_max`.
    pub fn parse_child(
        context: *Context,
        comptime U: type,
        segment: Segment,
        value: Value,
    ) ParseError!U {
        assert(context.path.count <= context.depth);
        assert(context.depth <= nesting_max);
        if (context.depth >= nesting_max) {
            const text = "exceeds nesting depth limit {d}";
            return context.fail(error.TooDeep, text, .{nesting_max});
        }
        context.path.push(segment);
        context.depth += 1;
        defer context.leave_child();

        return parse_mod.parse_value(U, context, value);
    }

    /// Undoes the push and the depth step of `parse_child`.
    fn leave_child(context: *Context) void {
        assert(context.depth > 0);
        assert(context.path.count > 0);
        context.path.pop();
        context.depth -= 1;
    }
};

/// Formats the reason into `buffer`; one byte more than `reason_len_max` tells a reason that
/// fits exactly from one that does not. A longer reason is cut to `reason_len_max` bytes
/// ending in `truncation_marker`.
fn format_reason(
    buffer: *[reason_len_max + 1]u8,
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    assert(buffer.len == reason_len_max + 1);
    assert(reason_len_max > truncation_marker.len);
    var writer = std.Io.Writer.fixed(buffer);
    const fitted = if (writer.print(format, args)) |_| true else |_| false;
    if (fitted and writer.end <= reason_len_max) return buffer[0..writer.end];
    const keep = reason_len_max - truncation_marker.len;
    @memcpy(buffer[keep..reason_len_max], truncation_marker);
    return buffer[0..reason_len_max];
}

/// The right-aligned tail of a path text: `buffer[start..]` is live and `filled <= budget`.
/// Text is only ever prepended, so what survives is always the most specific suffix.
const Tail = struct {
    buffer: [message_len_max]u8,
    start: u32,
    budget: u32,
    /// True once a prepend had to drop bytes; later prepends are dropped whole.
    overflow: bool,

    fn init(tail: *Tail, budget: u32) void {
        assert(budget >= truncation_marker.len);
        assert(budget <= message_len_max);
        tail.start = message_len_max;
        tail.budget = budget;
        tail.overflow = false;
    }

    fn len(tail: *const Tail) u32 {
        assert(tail.start <= message_len_max);
        return message_len_max - tail.start;
    }

    /// Puts `text` in front of the live bytes, keeping the end of `text` when it does not fit.
    fn prepend(tail: *Tail, text: []const u8) void {
        assert(tail.len() <= tail.budget);
        assert(tail.budget <= message_len_max);
        if (tail.overflow) return;
        const room = tail.budget - tail.len();
        const take: u32 = @intCast(@min(text.len, room));
        tail.start -= take;
        @memcpy(tail.buffer[tail.start..][0..take], text[text.len - take ..]);
        if (take < text.len) tail.overflow = true;
    }

    fn live(tail: *const Tail) []const u8 {
        assert(tail.start <= message_len_max);
        return tail.buffer[tail.start..];
    }
};

/// True for a key that is written bare: one or more of `[A-Za-z0-9_-]`.
fn is_bare_key(key: []const u8) bool {
    assert(key.len <= std.math.maxInt(u32));
    if (key.len == 0) return false;
    for (key) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

/// Prepends `["..."]` with `"`, `\`, bytes below 0x20 and 0x7f escaped, walking `key` backwards.
fn prepend_quoted_key(tail: *Tail, key: []const u8) void {
    assert(key.len <= std.math.maxInt(u32));
    assert(!tail.overflow);
    tail.prepend("\"]");
    for (0..key.len) |back| {
        if (tail.overflow) return;
        const index = key.len - 1 - back;
        const byte = key[index];
        if (byte == '"' or byte == '\\') {
            tail.prepend(&.{ '\\', byte });
        } else if (byte < 0x20 or byte == 0x7f) {
            const hex = "0123456789abcdef";
            tail.prepend(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
        } else {
            tail.prepend(key[index..][0..1]);
        }
    }
    tail.prepend("[\"");
}

/// Prepends the text of one segment. `first` is true when no earlier segment renders text, so
/// a bare key needs no leading dot.
fn prepend_segment(tail: *Tail, segment: Segment, first: bool) void {
    assert(tail.len() <= tail.budget);
    assert(tail.budget <= message_len_max);
    switch (segment) {
        .none => {},
        .index => |number| {
            var digits: [20]u8 = undefined;
            // proof: a u64 has at most 20 decimal digits, so a 20-byte buffer always fits.
            const text = std.fmt.bufPrint(&digits, "{d}", .{number}) catch unreachable;
            tail.prepend("]");
            tail.prepend(text);
            tail.prepend("[");
        },
        .key => |key| if (is_bare_key(key)) {
            tail.prepend(key);
            if (!first) tail.prepend(".");
        } else prepend_quoted_key(tail, key),
    }
}

/// Renders the path of `path` into `tail`, last segment first, until the budget is spent.
fn render_path(path: *const Path, tail: *Tail) void {
    assert(path.count <= nesting_max);
    assert(tail.len() == 0);
    var first_text: u32 = 0;
    while (first_text < path.count and path.segments[first_text] == .none) first_text += 1;
    var remaining = path.count;
    while (remaining > 0) {
        remaining -= 1;
        if (tail.overflow) break;
        prepend_segment(tail, path.segments[remaining], remaining == first_text);
    }
}

/// Builds `"{path}: {reason}"` (or `"{reason}"` for an empty path) into `out`, within
/// `message_len_max`. A path over its budget keeps its tail behind a leading marker.
fn render_message(path: *const Path, reason: []const u8, out: *[message_len_max]u8) []const u8 {
    assert(reason.len <= reason_len_max);
    assert(path.count <= nesting_max);
    const budget: u32 = message_len_max - @as(u32, @intCast(reason.len)) - 2;
    var tail: Tail = undefined;
    tail.init(budget);
    render_path(path, &tail);
    var writer = std.Io.Writer.fixed(out);
    if (tail.len() > 0) {
        const live = tail.live();
        if (tail.overflow) {
            // proof: the writer holds message_len_max bytes and the parts sum to at most that.
            writer.writeAll(truncation_marker) catch unreachable;
            // proof: same budget as the marker above, live.len == budget.
            writer.writeAll(live[truncation_marker.len..]) catch unreachable;
        } else {
            writer.writeAll(live) catch unreachable; // proof: len <= budget < out.len.
        }
        writer.writeAll(": ") catch unreachable; // proof: budget reserves 2 bytes for it.
    }
    writer.writeAll(reason) catch unreachable; // proof: budget reserves reason.len bytes.
    assert(writer.end <= message_len_max);
    return writer.buffered();
}

test {
    _ = @import("context_test.zig");
}

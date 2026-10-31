//! sigil.msgpack — MessagePack decoder and encoder over `core.Value` (ADR 0006).
//!
//! Landed: `msgpack/decoder.zig` (pull `Reader` and the tree build) and `msgpack/encoder.zig`
//! (shortest-head writer). `parse_value` and `write_value` are the Value-level entry points;
//! `parse(T)` runs `parse_value`, then `reflect.parse`, and `stringify(T)` runs
//! `reflect.stringify`, then the writer. A `[]const u8` field is a `str` unless the struct lists
//! it in `sigil_options.bytes`, which makes it a `bin` (ADR 0006 section 10). There are no
//! file helpers in v0.6.0.
//!
//! Ownership: nothing is allocated outside the `ValueTree`: strings, byte strings, keys and
//! containers go to its arena, and every result slice lives until `tree.deinit()`. Every error
//! return writes `diag` exactly once; success never. Positions are byte offsets: `line` is 1 and
//! `col` is the offset of the item's first byte plus 1 (ADR 0006 section 8).

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core.zig");
const reflect = @import("reflect.zig");

pub const decoder = @import("msgpack/decoder.zig");
pub const encoder = @import("msgpack/encoder.zig");
pub const locate = @import("msgpack/locate.zig");

const Io = std.Io;
const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// Module-level error set: everything any function of this module can return.
pub const Error = ParseError || StringifyError;

/// Every field is required: no defaults. `deny_unknown_fields` lives on the target type.
pub const ParseOptions = decoder.ParseOptions;

/// Why the bytes are not one MessagePack item, or why a `Value` could not be built from them
/// (11 variants).
pub const ParseValueError = decoder.ParseValueError;

/// `parse_value`'s errors plus `reflect.ParseError`; the shared names merge.
pub const ParseError = ParseValueError || reflect.ParseError;

/// Every field is required: no defaults.
pub const StringifyOptions = encoder.StringifyOptions;

/// Why a `Value` is not MessagePack (5 variants); `WriteFailed` is the caller's writer.
pub const WriteValueError = encoder.WriteValueError;

/// `reflect.StringifyError` plus `WriteValueError`; the shared names merge.
pub const StringifyError = reflect.StringifyError || WriteValueError;

comptime {
    assert(@typeInfo(ParseValueError).error_set.?.len == 11);
    assert(@typeInfo(WriteValueError).error_set.?.len == 5);
}

/// Parses `input`, exactly one MessagePack item, into `tree` and returns its root, which is not
/// stored in `tree.root`. Strings, byte strings and keys are copies; the result lives until
/// `tree.deinit()`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= core.value.nesting_max`.
pub fn parse_value(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    return decoder.parse_value(tree, input, options, diag);
}

/// Parses MessagePack into `T`: the item, then `reflect.parse`. A decoding error carries the
/// byte position the decoder gave. A reflect error (`TypeMismatch`, `MissingField`, ...) is
/// re-located: `diag` gets line 1, col = offset + 1 of the item the key path names (a missing or
/// unknown field names the map) and the message `byte N: ` followed by reflect's key-path
/// message (ADR 0006 section 8). Result slices live until `tree.deinit()` and never borrow from
/// `input`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= nesting_max`.
pub fn parse(
    comptime T: type,
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseError!T {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    const root = try parse_value(tree, input, options, diag);
    var trace: reflect.Path = undefined;
    trace.init();
    return reflect.parse.parse_traced(T, tree, root, diag, &trace) catch |err| {
        relocate(input, &trace, diag);
        return err;
    };
}

/// Upgrades `diag` from position-less to the byte position of the item `trace` names, keeping
/// reflect's message after a `byte N: ` prefix. Precondition: `diag` holds a reflect message at
/// `position_none`.
fn relocate(input: []const u8, trace: *const reflect.Path, diag: *Diagnostics) void {
    assert(diag.line == core.diagnostics.position_none);
    assert(diag.message().len > 0);
    const offset = locate.locate(input, trace);
    var buffer: [core.diagnostics.default_limits.message_len_max + 32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "byte {d}: {s}", .{ offset, diag.message() }) catch
        diag.message();
    const located = Diagnostics.init(1, offset + 1, text, null);
    assert(located.line == 1);
    diag.* = located;
}

/// Writes `value` to `w` as one MessagePack item; allocates nothing. See `encoder.write`.
/// Preconditions: `1 <= options.depth_max <= nesting_max`.
pub fn write_value(
    w: *Io.Writer,
    value: Value,
    options: StringifyOptions,
    diag: *Diagnostics,
) WriteValueError!void {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    return encoder.write(w, value, options, diag);
}

/// Writes `value` as MessagePack: `reflect.stringify` into `tree`, then the writer. Nothing is
/// written to `w` when the conversion fails; the tree holds the converted copy until
/// `tree.deinit()`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= nesting_max`.
pub fn stringify(
    comptime T: type,
    tree: *ValueTree,
    w: *Io.Writer,
    value: T,
    options: StringifyOptions,
    diag: *Diagnostics,
) StringifyError!void {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    const converted = try reflect.stringify.stringify(T, tree, value, diag);
    return write_value(w, converted, options, diag);
}

test "msgpack: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("msgpack/decoder_test.zig");
    _ = @import("msgpack/tree_test.zig");
    _ = @import("msgpack/encoder.zig");
    _ = @import("msgpack/locate.zig");
    _ = @import("msgpack/facade_test.zig");
}

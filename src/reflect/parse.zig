//! reflect/parse — `parse(T, tree, value, diag)` maps a `core.Value` onto the Zig type `T` at
//! comptime (ADR 0002 sections 1-5). This file covers the scalars: `bool`, sized integers, `f32`
//! and `f64`, `[]const u8`, exhaustive enums by wire name, `?T`, `core.Timestamp` and
//! `core.Value`. Every failure is a typed `ParseError` and writes the one `Diagnostics` of the
//! call exactly once, at `position_none`, with the key path in the message; success never
//! writes it. A numeric coercion is exact or an error; a `.float` never becomes an integer.
//! Any other `T` is a `@compileError` naming the type. Allocation: none for scalars. A parsed
//! `[]const u8` borrows from `value` and lives as long as the `ValueTree` that owns `value`.
//! `parse_value` recurses only at comptime-known depth (`?T` to `T`), so the machine stack is
//! bounded by the type, not by the data.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const options = @import("options.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Context = context_mod.Context;
const Path = context_mod.Path;
const ParseError = context_mod.ParseError;
const nesting_max = core.value.nesting_max;

/// An integer is exact in `f64` up to this magnitude (ADR 0002 section 4).
const f64_integer_exact_max: u64 = 1 << 53;
/// An integer is exact in `f32` up to this magnitude (ADR 0002 section 4).
const f32_integer_exact_max: u64 = 1 << 24;

/// Parses `value` as `T`. Result slices borrow from `value`, or were allocated from `tree`;
/// both die at `tree.deinit()`. Precondition: `value` belongs to `tree` or outlives it.
/// On error `diag` holds a position-less message naming the key path and the reason.
pub fn parse(
    comptime T: type,
    tree: *ValueTree,
    value: Value,
    diag: *Diagnostics,
) ParseError!T {
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(tree, diag, &path);
    assert(context.depth == 0);
    assert(!context.diag_written);
    return parse_value(T, &context, value);
}

/// The same parse under a caller's `Context`: the path and the depth continue where they are.
/// Does not push a path segment of its own; `Context.parse_child` does.
/// Precondition: `context.path.count <= context.depth <= nesting_max`.
pub fn parse_value(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    return parse_kind(T, context, value) catch |err| {
        if (!context.diag_written) write_fallback(T, context, err);
        return err;
    };
}

/// Writes `"{path}: parse of {T} failed: {errorName}"` for an error that came back without
/// `context.diag_written`, so every error return writes the diagnostics exactly once.
/// Precondition: the diagnostics of `context` are not written yet.
pub fn write_fallback(comptime T: type, context: *Context, err: ParseError) void {
    assert(!context.diag_written);
    assert(context.depth <= nesting_max);
    const text = "parse of {s} failed: {s}";
    const returned = context.fail(err, text, .{ @typeName(T), @errorName(err) });
    assert(returned == err);
    assert(context.diag_written);
}

/// Picks the parser of `T`; every unsupported type is a `@compileError` naming it.
fn parse_kind(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(context.depth <= nesting_max);
    assert(context.path.count <= context.depth);
    comptime assert_supported(T);
    if (T == Value) return value;
    if (T == core.Timestamp) return parse_timestamp(context, value);
    return switch (@typeInfo(T)) {
        .bool => parse_bool(context, value),
        .int => parse_int(T, context, value),
        .float => parse_float(T, context, value),
        .optional => |info| parse_optional(T, info.child, context, value),
        .@"enum" => parse_enum(T, context, value),
        .pointer => parse_string(context, value),
        else => comptime unreachable, // proof: `assert_supported` rejected every other kind.
    };
}

/// `@compileError` naming `T` unless `parse_kind` has a parser for it.
fn assert_supported(comptime T: type) void {
    if (T == Value or T == core.Timestamp) return;
    const supported = switch (@typeInfo(T)) {
        .bool => true,
        .int => |info| info.bits <= 64,
        .float => T == f32 or T == f64,
        .optional => |info| @typeInfo(info.child) != .optional,
        .@"enum" => |info| info.is_exhaustive,
        .pointer => T == []const u8,
        else => false,
    };
    if (!supported) @compileError(@typeName(T) ++ " is not supported");
    if (@typeInfo(T) == .optional) assert_supported(@typeInfo(T).optional.child);
}

/// `TypeMismatch`: "expected {kind}, found {tag}".
fn mismatch(context: *Context, comptime kind: []const u8, value: Value) ParseError {
    assert(kind.len > 0);
    assert(context.depth <= nesting_max);
    return context.fail(error.TypeMismatch, "expected {s}, found {s}", .{ kind, @tagName(value) });
}

fn parse_bool(context: *Context, value: Value) ParseError!bool {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    return switch (value) {
        .bool => |flag| flag,
        else => mismatch(context, "bool", value),
    };
}

fn parse_string(context: *Context, value: Value) ParseError![]const u8 {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    return switch (value) {
        .string => |text| text,
        else => mismatch(context, "string", value),
    };
}

fn parse_timestamp(context: *Context, value: Value) ParseError!core.Timestamp {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    return switch (value) {
        .timestamp => |stamp| stamp,
        else => mismatch(context, "timestamp", value),
    };
}

fn parse_int(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(@typeInfo(T) == .int);
    assert(context.depth <= nesting_max);
    return switch (value) {
        .int => |number| narrow_int(T, context, number),
        .uint => |number| narrow_int(T, context, number),
        else => mismatch(context, "integer", value),
    };
}

fn narrow_int(comptime T: type, context: *Context, number: anytype) ParseError!T {
    assert(@typeInfo(T) == .int);
    assert(@typeInfo(@TypeOf(number)) == .int);
    return std.math.cast(T, number) orelse {
        const text = "{d} is out of range for {s}";
        return context.fail(error.IntegerOutOfRange, text, .{ number, @typeName(T) });
    };
}

fn parse_float(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(T == f32 or T == f64);
    assert(context.depth <= nesting_max);
    return switch (value) {
        .int => |number| float_from_int(T, context, number),
        .uint => |number| float_from_int(T, context, number),
        .float => |number| if (T == f64) number else narrow_float(context, number),
        else => mismatch(context, "float", value),
    };
}

/// A range rule: `|number| <= 2^53` (`f64`) or `2^24` (`f32`) is exact, anything else is not.
fn float_from_int(comptime T: type, context: *Context, number: anytype) ParseError!T {
    assert(@typeInfo(@TypeOf(number)) == .int);
    assert(T == f32 or T == f64);
    const exact_max = if (T == f64) f64_integer_exact_max else f32_integer_exact_max;
    if (@abs(number) > exact_max) {
        const text = "{d} is not exactly representable as {s}";
        return context.fail(error.InexactNumber, text, .{ number, @typeName(T) });
    }
    return @floatFromInt(number);
}

/// Rounds to nearest-even. A finite value that rounds to infinity is out of range; NaN and
/// infinity pass through.
fn narrow_float(context: *Context, number: f64) ParseError!f32 {
    assert(context.depth <= nesting_max);
    assert(context.path.count <= context.depth);
    const narrowed: f32 = @floatCast(number);
    if (std.math.isFinite(number) and !std.math.isFinite(narrowed)) {
        const text = "{d} is out of range for f32";
        return context.fail(error.FloatOutOfRange, text, .{number});
    }
    return narrowed;
}

fn parse_optional(
    comptime T: type,
    comptime Child: type,
    context: *Context,
    value: Value,
) ParseError!T {
    assert(@typeInfo(T) == .optional);
    assert(context.depth <= nesting_max);
    assert(@typeInfo(Child) != .optional);
    return switch (value) {
        .null => null,
        else => try parse_value(Child, context, value),
    };
}

fn parse_enum(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(@typeInfo(T).@"enum".is_exhaustive);
    assert(context.depth <= nesting_max);
    const table = comptime options.resolve(T);
    const text = switch (value) {
        .string => |text| text,
        else => return mismatch(context, "enum " ++ @typeName(T), value),
    };
    const index = options.find_wire(table, text) orelse {
        const format = "unknown {s} \"{s}\"";
        return context.fail(error.UnknownEnumValue, format, .{ @typeName(T), text });
    };
    return std.enums.values(T)[index];
}

test {
    _ = @import("parse_test.zig");
}

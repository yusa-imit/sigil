//! reflect/parse — `parse(T, tree, value, diag)` maps a `core.Value` onto the Zig type `T` at
//! comptime (ADR 0002 sections 1-5). It covers `bool`, sized integers, `f32` and `f64`,
//! `[]const u8`, exhaustive enums by wire name, `?T`, `core.Timestamp`, `core.Value`, plain
//! structs (through the options table), `[N]T`, `[]T`, tagged unions, `array_hash_map.String(V)`
//! and any type that declares the `sigilParse`/`sigilStringify` hook pair. Every failure is a
//! typed `ParseError` and writes the one `Diagnostics` of the call exactly once, at
//! `position_none`, with the key path in the message; success never writes it. A numeric
//! coercion is exact or an error; a `.float` never becomes an integer. Any other `T` is a
//! `@compileError` naming the type. Allocation: only `[]T` slices and string maps, one
//! allocation each of exactly `array.len` or `map.count` entries from the tree arena (a hook
//! may allocate there too). A parsed `[]const u8` borrows from `value`; every result slice
//! lives as long as the `ValueTree`. Recursion follows the data (a struct of slices of itself),
//! but each container entered adds one depth level and the 129th is `TooDeep`, so the machine
//! stack holds at most `nesting_max` frames of at most `array_bytes_max` bytes of array value each.

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
const StringifyError = context_mod.StringifyError;
const nesting_max = core.value.nesting_max;

/// The largest `[N]T` a parse target may contain by value; it lives on the machine stack, up to
/// `nesting_max` frames deep.
const array_bytes_max: u32 = 1 << 16;
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
    const text = if (comptime has_hook(T))
        "sigilParse of {s} failed: {s}"
    else
        "parse of {s} failed: {s}";
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
    if (comptime has_hook(T)) return T.sigilParse(context, value);
    return switch (@typeInfo(T)) {
        .bool => parse_bool(context, value),
        .int => parse_int(T, context, value),
        .float => parse_float(T, context, value),
        .optional => |info| parse_optional(T, info.child, context, value),
        .@"enum" => parse_enum(T, context, value),
        .pointer => |info| if (T == []const u8)
            parse_string(context, value)
        else
            parse_slice(T, info.child, context, value),
        .array => parse_array(T, context, value),
        .@"struct" => if (comptime string_map_value(T)) |Item|
            parse_string_map(T, Item, context, value)
        else
            parse_struct(T, context, value),
        .@"union" => parse_union(T, context, value),
        else => comptime unreachable, // proof: `assert_supported` rejected every other kind.
    };
}

/// True when `T` declares the `sigilParse`/`sigilStringify` pair. A hook is the escape hatch
/// of ADR 0002 section 1: it replaces the default mapping, so it also admits a type that
/// `assert_supported` would reject. Comptime only; an unpaired or mistyped hook, or a hook
/// next to `sigil_options`, is a `@compileError`.
pub fn has_hook(comptime T: type) bool {
    comptime assert(@typeName(T).len > 0);
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => {},
        else => return false,
    }
    const parse_declared = @hasDecl(T, "sigilParse");
    const stringify_declared = @hasDecl(T, "sigilStringify");
    if (parse_declared and !stringify_declared) {
        @compileError(@typeName(T) ++ " declares sigilParse without sigilStringify");
    }
    if (stringify_declared and !parse_declared) {
        @compileError(@typeName(T) ++ " declares sigilStringify without sigilParse");
    }
    if (!parse_declared) return false;
    if (@TypeOf(T.sigilParse) != fn (*Context, Value) ParseError!T) {
        @compileError(@typeName(T) ++ ": sigilParse must be fn (*Context, Value) ParseError!T");
    }
    if (@TypeOf(T.sigilStringify) != fn (*const T, *Context) StringifyError!Value) {
        @compileError(@typeName(T) ++
            ": sigilStringify must be fn (*const T, *Context) StringifyError!Value");
    }
    if (@hasDecl(T, "sigil_options")) {
        @compileError(@typeName(T) ++ ": the options would be dead; remove one");
    }
    comptime assert(@hasDecl(T, "sigilParse"));
    comptime assert(@hasDecl(T, "sigilStringify"));
    return true;
}

/// The value type `V` when `T` is exactly `std.array_hash_map.String(V)`, else null.
pub fn string_map_value(comptime T: type) ?type {
    comptime assert(@typeName(T).len > 0);
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "KV")) return null;
    if (@TypeOf(T.KV) != type) return null;
    if (@typeInfo(T.KV) != .@"struct") return null;
    if (!@hasField(T.KV, "value")) return null;
    const Item = @FieldType(T.KV, "value");
    comptime assert(@typeInfo(T.KV) == .@"struct");
    return if (T == std.array_hash_map.String(Item)) Item else null;
}

/// `@compileError` naming `T` unless `parse_kind` has a parser for it.
pub fn assert_supported(comptime T: type) void {
    comptime assert(@typeName(T).len > 0);
    if (T == Value or T == core.Timestamp) return;
    if (has_hook(T)) return;
    const supported = switch (@typeInfo(T)) {
        .bool => true,
        .int => |info| info.bits <= 64,
        .float => T == f32 or T == f64,
        .optional => |info| @typeInfo(info.child) != .optional,
        .@"enum" => |info| info.is_exhaustive,
        .pointer => |info| T == []const u8 or slice_supported(info),
        .array => |info| info.sentinel_ptr == null and @sizeOf(T) <= array_bytes_max,
        .@"struct" => |info| string_map_value(T) != null or struct_supported(info),
        .@"union" => |info| info.tag_type != null and info.layout == .auto,
        else => false,
    };
    if (!supported) @compileError(@typeName(T) ++ " is not supported");
    comptime assert(supported);
    // Only `?T` is checked eagerly: a struct, array or slice checks its element types when it
    // parses them, because a recursive type (`children: []Node`) would never finish otherwise.
    if (@typeInfo(T) == .optional) assert_supported(@typeInfo(T).optional.child);
}

/// A plain `[]T` or `[]const T`, `T != u8`: the arena returns naturally aligned memory.
fn slice_supported(comptime info: std.builtin.Type.Pointer) bool {
    if (info.size != .slice) return false;
    if (info.sentinel_ptr != null) return false;
    if (info.child == u8) return false;
    if (info.alignment) |alignment| {
        if (alignment != @alignOf(info.child)) return false;
    }
    if (info.is_allowzero or info.is_volatile) return false;
    return info.address_space == .generic;
}

/// Plain structs only: no packed layout, no tuple, no `comptime` field.
fn struct_supported(comptime info: std.builtin.Type.Struct) bool {
    if (info.layout == .@"packed") return false;
    if (info.is_tuple) return false;
    for (info.fields) |field| {
        if (field.is_comptime) return false;
    }
    return true;
}

/// Fails with `TooDeep` when a container would be entered past `nesting_max`: 128 nested
/// containers pass, the 129th fails (the boundary of `core.value.eql`).
fn enter_container(context: *Context) ParseError!void {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    if (context.depth >= nesting_max) {
        return context.fail(error.TooDeep, "exceeds nesting depth limit {d}", .{nesting_max});
    }
}

/// A struct from a `.map`, fields looked up by wire name through the options table.
/// Unknown keys are checked first (map order), then fields in declaration order.
fn parse_struct(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(@typeInfo(T) == .@"struct");
    assert(context.depth <= nesting_max);
    const map = switch (value) {
        .map => |map| map,
        else => return mismatch(context, "map", value),
    };
    try enter_container(context);
    const table = comptime options.resolve(T);
    if (table.deny_unknown_fields) try check_unknown(table, context, &map);
    var result: T = undefined; // Every field is assigned below, or an error is returned.
    inline for (@typeInfo(T).@"struct".fields, table.entries) |field, entry| {
        if (map.get(entry.wire_name)) |found| {
            const segment: context_mod.Segment = .{ .key = entry.wire_name };
            @field(result, field.name) = try context.parse_child(field.type, segment, found.*);
        } else if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else {
            return context.fail(error.MissingField, "missing field \"{s}\"", .{entry.wire_name});
        }
    }
    return result;
}

fn check_unknown(
    comptime table: options.Table,
    context: *Context,
    map: *const core.Map,
) ParseError!void {
    assert(map.count <= map.entries.len);
    assert(context.depth <= nesting_max);
    for (map.items()) |entry| {
        if (options.find_wire(table, entry.key) == null) {
            return context.fail(error.UnknownField, "unknown field \"{s}\"", .{entry.key});
        }
    }
}

/// A tagged union, externally tagged (ADR 0002 section 5): a void variant is its tag as a
/// `.string`, any other variant is a one-entry `.map` `{tag: payload}`. The payload path
/// segment is the wire tag.
fn parse_union(comptime T: type, context: *Context, value: Value) ParseError!T {
    assert(@typeInfo(T).@"union".tag_type != null);
    assert(context.depth <= nesting_max);
    const table = comptime options.resolve(T);
    switch (value) {
        .string => |tag_text| {
            const index = options.find_wire(table, tag_text) orelse
                return unknown_tag(T, context, tag_text);
            inline for (@typeInfo(T).@"union".fields, 0..) |field, field_index| {
                if (index == field_index) {
                    if (field.type != void) {
                        const text = "variant \"{s}\" needs a payload";
                        return context.fail(error.TypeMismatch, text, .{tag_text});
                    }
                    return @unionInit(T, field.name, {});
                }
            }
            unreachable; // proof: `find_wire` returns an index below the field count.
        },
        .map => |map| {
            try enter_container(context);
            if (map.count != 1) {
                const text = "expected a map with one entry, found {d}";
                return context.fail(error.TypeMismatch, text, .{map.count});
            }
            return parse_union_payload(T, table, context, map.items()[0]);
        },
        else => return mismatch(context, "string or map for union " ++ @typeName(T), value),
    }
}

/// The payload of the one entry of a union map, parsed as the variant its key names.
fn parse_union_payload(
    comptime T: type,
    comptime table: options.Table,
    context: *Context,
    entry: core.Map.Entry,
) ParseError!T {
    assert(@typeInfo(T).@"union".tag_type != null);
    assert(context.path.count <= context.depth);
    const index = options.find_wire(table, entry.key) orelse
        return unknown_tag(T, context, entry.key);
    inline for (@typeInfo(T).@"union".fields, table.entries, 0..) |field, wire, field_index| {
        if (index == field_index) {
            if (field.type == void) {
                const text = "variant \"{s}\" takes no payload";
                return context.fail(error.TypeMismatch, text, .{entry.key});
            }
            const segment: context_mod.Segment = .{ .key = wire.wire_name };
            const payload = try context.parse_child(field.type, segment, entry.value);
            return @unionInit(T, field.name, payload);
        }
    }
    unreachable; // proof: `find_wire` returns an index below the field count.
}

fn unknown_tag(comptime T: type, context: *Context, tag_text: []const u8) ParseError {
    assert(context.depth <= nesting_max);
    assert(context.path.count <= context.depth);
    const text = "unknown {s} \"{s}\"";
    return context.fail(error.UnknownEnumValue, text, .{ @typeName(T), tag_text });
}

/// `std.array_hash_map.String(Item)` from a `.map`: one capacity reservation of exactly
/// `map.count` from the tree arena, then insertion in map order. Keys are borrowed from `value`;
/// the tree frees the map, it is never `deinit`ed by the caller.
fn parse_string_map(
    comptime T: type,
    comptime Item: type,
    context: *Context,
    value: Value,
) ParseError!T {
    assert(T == std.array_hash_map.String(Item));
    assert(context.depth <= nesting_max);
    const map = switch (value) {
        .map => |map| map,
        else => return mismatch(context, "map", value),
    };
    try enter_container(context);
    var result: T = .empty;
    try result.ensureTotalCapacity(context.tree.arena.allocator(), map.count);
    for (map.items()) |entry| {
        const item = try context.parse_child(Item, .{ .key = entry.key }, entry.value);
        // `core.Map` keys are unique and the capacity was reserved above.
        result.putAssumeCapacityNoClobber(entry.key, item);
    }
    assert(result.count() == map.count);
    return result;
}

/// `[N]T` from an `.array` of exactly `N` items.
fn parse_array(comptime T: type, context: *Context, value: Value) ParseError!T {
    const info = @typeInfo(T).array;
    assert(context.depth <= nesting_max);
    const items = switch (value) {
        .array => |items| items,
        else => return mismatch(context, "array", value),
    };
    try enter_container(context);
    if (items.len != info.len) {
        const text = "expected array of length {d}, found {d}";
        return context.fail(error.LengthMismatch, text, .{ info.len, items.len });
    }
    var result: T = undefined; // Every element is assigned below, or an error is returned.
    for (&result, items, 0..) |*slot, item, index| {
        slot.* = try context.parse_child(info.child, .{ .index = index }, item);
    }
    return result;
}

/// `[]const Child` or `[]Child` from an `.array`: one allocation of exactly `items.len` from
/// the tree arena, freed with the tree.
fn parse_slice(
    comptime T: type,
    comptime Child: type,
    context: *Context,
    value: Value,
) ParseError!T {
    assert(@typeInfo(T) == .pointer);
    assert(Child != u8);
    const items = switch (value) {
        .array => |items| items,
        else => return mismatch(context, "array", value),
    };
    try enter_container(context);
    const result = try context.tree.arena.allocator().alloc(Child, items.len);
    assert(result.len == items.len);
    for (result, items, 0..) |*slot, item, index| {
        slot.* = try context.parse_child(Child, .{ .index = index }, item);
    }
    return result;
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
    _ = @import("parse_struct_test.zig");
    _ = @import("parse_slice_test.zig");
    _ = @import("parse_model_test.zig");
    _ = @import("parse_union_test.zig");
    _ = @import("parse_map_test.zig");
    _ = @import("parse_hook_test.zig");
}

//! reflect/stringify — `stringify(T, tree, value, diag)` maps the Zig value `value: T` onto a
//! `core.Value` at comptime, the mirror of `reflect/parse` (ADR 0002 sections 1-5): every type
//! `parse` accepts, with the same options table, the same key path in diagnostics and the same
//! container depth bound (the 129th nested container is `TooDeep`). Signed integers become
//! `.int`; unsigned ones `.int` up to `maxInt(i64)` and `.uint` above, the canonical form of
//! `number.parse_integer`; floats `.float`. A `[]const u8` or map key must be valid UTF-8
//! (`InvalidUtf8`, never a silent `.bytes`). Structs emit every field in declaration order; enum
//! tags, struct fields and union tags use their wire names, which are comptime constants.
//! Allocation: every string, array, map and `core.Value` copy of the result is allocated from
//! the tree arena (a hook may allocate there too), so the result never aliases `value` and lives
//! as long as the `ValueTree`; sizes are known before each allocation (`len`, `count`, field
//! count), one allocation per container. Every failure is a typed `StringifyError` and writes the
//! one `Diagnostics` of the call exactly once; success never writes it.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("../core.zig");
const context_mod = @import("context.zig");
const options = @import("options.zig");
const parse_mod = @import("parse.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const Diagnostics = core.Diagnostics;
const Context = context_mod.Context;
const Path = context_mod.Path;
const StringifyError = context_mod.StringifyError;
const nesting_max = core.value.nesting_max;

/// Converts `value` to a `Value` allocated in `tree`; the result lives until `tree.deinit()` and
/// shares no memory with `value`. On error `diag` holds a position-less message naming the key
/// path and the reason.
pub fn stringify(
    comptime T: type,
    tree: *ValueTree,
    value: T,
    diag: *Diagnostics,
) StringifyError!Value {
    var path: Path = undefined;
    path.init();
    var context: Context = undefined;
    context.init(tree, diag, &path);
    assert(context.depth == 0);
    assert(!context.diag_written);
    return stringify_value(T, &context, &value);
}

/// The same conversion under a caller's `Context`: the path and the depth continue where they
/// are. Does not push a path segment of its own; `Context.stringify_child` does.
/// Precondition: `context.path.count <= context.depth <= nesting_max`.
pub fn stringify_value(
    comptime T: type,
    context: *Context,
    value: *const T,
) StringifyError!Value {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    return stringify_kind(T, context, value) catch |err| {
        if (!context.diag_written) write_fallback(T, context, err);
        return err;
    };
}

/// Writes `"{path}: stringify of {T} failed: {errorName}"` for an error that came back without
/// `context.diag_written`, so every error return writes the diagnostics exactly once.
/// Precondition: the diagnostics of `context` are not written yet.
fn write_fallback(comptime T: type, context: *Context, err: StringifyError) void {
    assert(!context.diag_written);
    assert(context.depth <= nesting_max);
    const text = if (comptime parse_mod.has_hook(T))
        "sigilStringify of {s} failed: {s}"
    else
        "stringify of {s} failed: {s}";
    const returned = context.fail_stringify(err, text, .{ @typeName(T), @errorName(err) });
    assert(returned == err);
    assert(context.diag_written);
}

/// Picks the converter of `T`; every unsupported type is a `@compileError` naming it.
fn stringify_kind(comptime T: type, context: *Context, value: *const T) StringifyError!Value {
    assert(context.depth <= nesting_max);
    assert(context.path.count <= context.depth);
    comptime parse_mod.assert_supported(T);
    if (T == Value) return clone_value(context, value.*, context.depth);
    if (T == core.Timestamp) return .{ .timestamp = value.* };
    if (comptime parse_mod.has_hook(T)) return T.sigilStringify(value, context);
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value.* },
        .int => stringify_int(T, value.*),
        .float => .{ .float = value.* },
        .optional => |info| if (value.*) |*payload|
            stringify_value(info.child, context, payload)
        else
            .null,
        .@"enum" => stringify_enum(T, value.*),
        .pointer => |info| if (T == []const u8)
            stringify_string(context, value.*)
        else
            stringify_items(info.child, context, value.*),
        .array => |info| stringify_items(info.child, context, value),
        .@"struct" => if (comptime parse_mod.string_map_value(T)) |Item|
            stringify_string_map(T, Item, context, value)
        else
            stringify_struct(T, context, value),
        .@"union" => stringify_union(T, context, value),
        else => comptime unreachable, // proof: `assert_supported` rejected every other kind.
    };
}

/// Fails with `TooDeep` when a container would be entered past `nesting_max`: 128 nested
/// containers pass, the 129th fails (the boundary of `core.value.eql`).
fn enter_container(context: *Context) StringifyError!void {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    if (context.depth >= nesting_max) {
        const text = "exceeds nesting depth limit {d}";
        return context.fail_stringify(error.TooDeep, text, .{nesting_max});
    }
}

/// `len` as a `u32` count, or `InputTooLarge` naming `what`; core's offsets and counts are `u32`.
fn check_count(context: *Context, len: usize, comptime what: []const u8) StringifyError!u32 {
    assert(what.len > 0);
    assert(context.depth <= nesting_max);
    // proof: not I/O; `check_len` has the single error `InputTooLarge`.
    return core.unicode.check_len(len) catch |err| switch (err) {
        error.InputTooLarge => context.fail_stringify(
            error.InputTooLarge,
            what ++ " is longer than {d}",
            .{std.math.maxInt(u32)},
        ),
    };
}

/// Where `text` stops being valid UTF-8, or null when it is valid. Fails with `InputTooLarge`.
fn first_invalid(context: *Context, text: []const u8) StringifyError!?core.unicode.Invalid {
    _ = try check_count(context, text.len, "string");
    // proof: `check_count` above already rejected a length past maxInt(u32), the only error.
    return core.unicode.find_invalid(text) catch unreachable;
}

/// Unsigned values above `maxInt(i64)` are `.uint`, everything else `.int`.
fn stringify_int(comptime T: type, number: T) Value {
    const info = @typeInfo(T).int;
    assert(info.bits <= 64);
    if (info.signedness == .signed) return .{ .int = number };
    const wide: u64 = number;
    if (wide <= std.math.maxInt(i64)) return .{ .int = @intCast(wide) };
    assert(wide > std.math.maxInt(i64));
    return .{ .uint = wide };
}

/// The wire name of the tag; a comptime constant, so the result aliases nothing of the caller.
fn stringify_enum(comptime T: type, tag: T) Value {
    assert(@typeInfo(T).@"enum".is_exhaustive);
    const table = comptime options.resolve(T);
    inline for (std.enums.values(T), table.entries) |candidate, entry| {
        assert(std.mem.eql(u8, @tagName(candidate), entry.zig_name));
        if (tag == candidate) return .{ .string = entry.wire_name };
    }
    unreachable; // proof: an exhaustive enum value is one of `std.enums.values(T)`.
}

/// A `[]const u8` as a `.string` copied into the tree, after the UTF-8 check.
fn stringify_string(context: *Context, text: []const u8) StringifyError!Value {
    assert(context.path.count <= context.depth);
    assert(context.depth <= nesting_max);
    if (try first_invalid(context, text)) |found| {
        const format = "invalid UTF-8 at byte {d} ({s})";
        const args = .{ found.offset, @tagName(found.reason) };
        return context.fail_stringify(error.InvalidUtf8, format, args);
    }
    return context.tree.dupe_string(text);
}

/// A `[N]T` or slice as an `.array` of exactly its length, one allocation from the tree arena.
fn stringify_items(
    comptime Child: type,
    context: *Context,
    items: []const Child,
) StringifyError!Value {
    assert(items.len == 0 or @intFromPtr(items.ptr) != 0);
    assert(context.depth <= nesting_max);
    try enter_container(context);
    _ = try check_count(context, items.len, "array");
    const result = try context.tree.arena.allocator().alloc(Value, items.len);
    assert(result.len == items.len);
    for (result, items, 0..) |*slot, *item, index| {
        slot.* = try context.stringify_child(Child, .{ .index = index }, item);
    }
    return .{ .array = result };
}

/// A struct as a `.map`: every field, declaration order, under its wire name.
fn stringify_struct(comptime T: type, context: *Context, value: *const T) StringifyError!Value {
    assert(@typeInfo(T) == .@"struct");
    assert(context.depth <= nesting_max);
    try enter_container(context);
    const table = comptime options.resolve(T);
    const fields = @typeInfo(T).@"struct".fields;
    var map = try context.tree.new_map(fields.len);
    inline for (fields, table.entries) |field, entry| {
        const segment: context_mod.Segment = .{ .key = entry.wire_name };
        const item = try context.stringify_child(field.type, segment, &@field(value.*, field.name));
        // proof: capacity is the field count and `options.resolve` made the wire names unique.
        map.put(entry.wire_name, item) catch unreachable;
    }
    assert(map.count == fields.len);
    return .{ .map = map };
}

/// A tagged union, externally tagged: a void variant is its wire tag as a `.string`, any other
/// variant a one-entry `.map` `{tag: payload}` whose payload path segment is the wire tag.
fn stringify_union(comptime T: type, context: *Context, value: *const T) StringifyError!Value {
    const info = @typeInfo(T).@"union";
    assert(info.tag_type != null);
    assert(context.depth <= nesting_max);
    const table = comptime options.resolve(T);
    inline for (info.fields, table.entries) |field, entry| {
        if (std.meta.activeTag(value.*) == @field(info.tag_type.?, field.name)) {
            if (comptime field.type == void) return .{ .string = entry.wire_name };
            try enter_container(context);
            var map = try context.tree.new_map(1);
            const segment: context_mod.Segment = .{ .key = entry.wire_name };
            const payload = &@field(value.*, field.name);
            const item = try context.stringify_child(field.type, segment, payload);
            map.put(entry.wire_name, item) catch unreachable; // proof: one slot, one entry.
            return .{ .map = map };
        }
    }
    unreachable; // proof: the active tag is one of the union's fields.
}

/// `std.array_hash_map.String(Item)` as a `.map` in the map's own order; keys are UTF-8 checked
/// and copied into the tree.
fn stringify_string_map(
    comptime T: type,
    comptime Item: type,
    context: *Context,
    value: *const T,
) StringifyError!Value {
    assert(T == std.array_hash_map.String(Item));
    assert(context.depth <= nesting_max);
    try enter_container(context);
    const count = try check_count(context, value.count(), "map");
    var map = try context.tree.new_map(count);
    for (value.keys(), value.values()) |key, *item| {
        if (try first_invalid(context, key)) |found| {
            const format = "key has invalid UTF-8 at byte {d} ({s})";
            const args = .{ found.offset, @tagName(found.reason) };
            return context.fail_stringify(error.InvalidUtf8, format, args);
        }
        const copy = try context.tree.dupe_key(key);
        const child = try context.stringify_child(Item, .{ .key = copy }, item);
        // proof: hash map keys are unique and the room was reserved.
        map.put(copy, child) catch unreachable;
    }
    assert(map.count == count);
    return .{ .map = map };
}

/// Deep copy of `value` into the tree. `level` is the number of containers above it; recursion
/// is bounded by it: a container at `level >= nesting_max` is `TooDeep`, so at most
/// `nesting_max` frames are live.
fn clone_value(context: *Context, value: Value, level: u32) StringifyError!Value {
    assert(level <= nesting_max);
    assert(level >= context.depth);
    return switch (value) {
        .null, .bool, .int, .uint, .float, .timestamp => value,
        .string => |text| context.tree.dupe_string(text),
        .bytes => |data| context.tree.dupe_bytes(data),
        .array => |items| clone_array(context, items, level),
        .map => |map| clone_map(context, map, level),
    };
}

/// Copies an array of `Value`s one level deeper; `TooDeep` once `level` reaches `nesting_max`.
fn clone_array(context: *Context, items: []const Value, level: u32) StringifyError!Value {
    assert(level <= nesting_max);
    assert(level >= context.depth);
    if (level >= nesting_max) {
        const text = "exceeds nesting depth limit {d}";
        return context.fail_stringify(error.TooDeep, text, .{nesting_max});
    }
    const result = try context.tree.arena.allocator().alloc(Value, items.len);
    assert(result.len == items.len);
    for (result, items) |*slot, item| slot.* = try clone_value(context, item, level + 1);
    return .{ .array = result };
}

/// Copies a `Map` one level deeper. Precondition: `source` keeps the `Map` invariant (unique
/// keys, `count <= entries.len`); `Map.put` and `Map.check_invariants` are the way to uphold it.
fn clone_map(context: *Context, source: core.Map, level: u32) StringifyError!Value {
    assert(level <= nesting_max);
    assert(source.count <= source.entries.len);
    if (level >= nesting_max) {
        const text = "exceeds nesting depth limit {d}";
        return context.fail_stringify(error.TooDeep, text, .{nesting_max});
    }
    var map = try context.tree.new_map(source.count);
    for (source.items()) |entry| {
        const key = try context.tree.dupe_key(entry.key);
        const item = try clone_value(context, entry.value, level + 1);
        map.put(key, item) catch unreachable; // proof: the source keys are unique; room reserved.
    }
    assert(map.count == source.count);
    return .{ .map = map };
}

test {
    _ = @import("stringify_test.zig");
}

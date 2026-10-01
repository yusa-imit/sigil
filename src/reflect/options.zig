//! reflect/options — resolves a type's `sigil_options` declaration (ADR 0002 §6) at comptime
//! into a field table: Zig name, wire name, whether the Zig field has a default, and the
//! struct's `deny_unknown_fields` flag. Parse and stringify read the table; they never read
//! `sigil_options` themselves. Every misuse is a `@compileError` naming the type and the option,
//! never a runtime surprise. Allocation: none (comptime only, plus `find_wire` over a table).

const std = @import("std");
const assert = std.debug.assert;

/// How `rename_all` rewrites a name that `rename` does not mention.
pub const RenameAll = enum {
    snake_case,
    camel_case,
    pascal_case,
    kebab_case,
    screaming_snake_case,
};

/// One field of a struct, or one tag of an enum or tagged union.
pub const Entry = struct {
    /// The name in the Zig declaration.
    zig_name: []const u8,
    /// The name in the document, after `rename` and `rename_all`.
    wire_name: []const u8,
    /// True when the Zig struct field has a default value. Always false for enums and unions.
    has_default: bool,
};

/// The resolved options of one type.
pub const Table = struct {
    /// In declaration order.
    entries: []const Entry,
    /// Structs only: an unknown map key is `UnknownField`. False for enums and unions, where
    /// the option does not apply. Defaults to true for structs, as in `std.json`.
    deny_unknown_fields: bool,
};

/// Resolves `T.sigil_options` (absent means no renames and `deny_unknown_fields = true`).
/// The declaration must be `pub`: Zig cannot see a private one from another file, so a
/// private `sigil_options` is indistinguishable from none and is silently not applied.
/// Precondition: `T` is a struct, an enum or a tagged union. Comptime only.
pub fn resolve(comptime T: type) Table {
    comptime {
        const names = zig_names(T);
        // The pairwise wire-name check dominates: names.len squared string compares.
        @setEvalBranchQuota(10_000 + names.len * names.len * 256);
        const has_options = @hasDecl(T, "sigil_options");
        if (has_options) {
            if (@hasDecl(T, "sigilParse") or @hasDecl(T, "sigilStringify")) {
                @compileError("sigil_options on " ++ @typeName(T) ++ ", which declares " ++
                    "sigilParse/sigilStringify: the options would be dead; remove one");
            }
        }
        const options = if (has_options) T.sigil_options else .{};
        check_option_keys(T, options);
        const style = rename_all_of(T, options);
        check_rename_targets(T, options, names);
        var entries: [names.len]Entry = undefined;
        for (names, 0..) |name, index| {
            entries[index] = .{
                .zig_name = name,
                .wire_name = wire_name_of(T, options, name, style),
                .has_default = has_default(T, index),
            };
        }
        check_unique(T, &entries);
        const final = entries;
        assert(final.len == names.len);
        const deny = deny_unknown_fields_of(T, options);
        if (@typeInfo(T) != .@"struct") assert(!deny);
        return .{ .entries = &final, .deny_unknown_fields = deny };
    }
}

/// Index of the entry whose wire name is `wire_name`, or null. Linear; tables are small.
pub fn find_wire(table: Table, wire_name: []const u8) ?u32 {
    assert(table.entries.len <= std.math.maxInt(u32));
    for (table.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.wire_name, wire_name)) return @intCast(index);
    }
    assert(wire_name.len <= std.math.maxInt(u32));
    return null;
}

/// The Zig field names of a struct, or the tag names of an enum or a tagged union.
fn zig_names(comptime T: type) []const []const u8 {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        .@"enum" => |info| info.fields,
        .@"union" => |info| blk: {
            if (info.tag_type == null) {
                @compileError("reflect: untagged union " ++ @typeName(T) ++ " is unsupported");
            }
            break :blk info.fields;
        },
        else => @compileError("reflect options: " ++ @typeName(T) ++ " is not a struct, " ++
            "enum or tagged union"),
    };
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = field.name;
    const final = names;
    return &final;
}

fn has_default(comptime T: type, comptime index: usize) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields[index].default_value_ptr != null,
        else => false,
    };
}

fn check_option_keys(comptime T: type, comptime options: anytype) void {
    const info = @typeInfo(@TypeOf(options));
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".sigil_options must be an anonymous struct");
    }
    for (info.@"struct".fields) |field| {
        const known = std.mem.eql(u8, field.name, "rename") or
            std.mem.eql(u8, field.name, "rename_all") or
            std.mem.eql(u8, field.name, "deny_unknown_fields");
        if (!known) {
            @compileError(@typeName(T) ++ ".sigil_options: unknown option ." ++ field.name ++
                " (expected rename, rename_all or deny_unknown_fields)");
        }
    }
}

fn rename_all_of(comptime T: type, comptime options: anytype) ?RenameAll {
    if (!@hasField(@TypeOf(options), "rename_all")) return null;
    const value = options.rename_all;
    if (@TypeOf(value) == RenameAll) return value;
    if (@TypeOf(value) == @TypeOf(.enum_literal)) {
        return std.meta.stringToEnum(RenameAll, @tagName(value)) orelse
            @compileError(@typeName(T) ++ ".sigil_options: rename_all ." ++ @tagName(value) ++
                " is not one of snake_case, camel_case, pascal_case, kebab_case, " ++
                "screaming_snake_case");
    }
    @compileError(@typeName(T) ++ ".sigil_options: rename_all must be an enum literal such " ++
        "as .kebab_case");
}

fn deny_unknown_fields_of(comptime T: type, comptime options: anytype) bool {
    const applies = @typeInfo(T) == .@"struct";
    if (!@hasField(@TypeOf(options), "deny_unknown_fields")) return applies;
    if (!applies) {
        @compileError(@typeName(T) ++ ".sigil_options: deny_unknown_fields applies to " ++
            "structs only");
    }
    if (@TypeOf(options.deny_unknown_fields) != bool) {
        @compileError(@typeName(T) ++ ".sigil_options: deny_unknown_fields must be a bool");
    }
    return options.deny_unknown_fields;
}

/// Every key of `.rename` must name a field or tag of `T`, and carry a non-empty string.
fn check_rename_targets(
    comptime T: type,
    comptime options: anytype,
    comptime names: []const []const u8,
) void {
    if (!@hasField(@TypeOf(options), "rename")) return;
    const rename = options.rename;
    const info = @typeInfo(@TypeOf(rename));
    if (info != .@"struct") {
        @compileError(@typeName(T) ++ ".sigil_options: rename must be an anonymous struct");
    }
    for (info.@"struct".fields) |field| {
        const found = for (names) |name| {
            if (std.mem.eql(u8, name, field.name)) break true;
        } else false;
        if (!found) {
            @compileError(@typeName(T) ++ ".sigil_options: rename of ." ++ field.name ++
                ", which is not a field or tag of the type");
        }
        if (rename_string(@field(rename, field.name)).len == 0) {
            @compileError(@typeName(T) ++ ".sigil_options: rename of ." ++ field.name ++
                " is empty");
        }
    }
}

fn rename_string(comptime value: anytype) []const u8 {
    const info = @typeInfo(@TypeOf(value));
    const is_string = info == .pointer and info.pointer.size == .one and
        @typeInfo(info.pointer.child) == .array and
        @typeInfo(info.pointer.child).array.child == u8;
    if (!is_string) @compileError("sigil_options: rename values must be string literals");
    return value;
}

fn wire_name_of(
    comptime T: type,
    comptime options: anytype,
    comptime name: []const u8,
    comptime style: ?RenameAll,
) []const u8 {
    if (@hasField(@TypeOf(options), "rename")) {
        if (@hasField(@TypeOf(options.rename), name)) {
            return rename_string(@field(options.rename, name));
        }
    }
    const chosen = style orelse return name;
    if (!is_snake_name(name)) {
        @compileError(@typeName(T) ++ ": rename_all needs snake_case names, and ." ++ name ++
            " is not one; give it an explicit rename");
    }
    var out: [rename_len(name, chosen)]u8 = undefined;
    rename_into(&out, name, chosen);
    const final = out;
    return &final;
}

fn check_unique(comptime T: type, comptime entries: []const Entry) void {
    for (entries, 0..) |entry, index| {
        for (entries[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.wire_name, other.wire_name)) {
                @compileError(@typeName(T) ++ ": ." ++ entry.zig_name ++ " and ." ++
                    other.zig_name ++ " both land on the wire name \"" ++ entry.wire_name ++
                    "\"");
            }
        }
    }
}

/// True for `[a-z][a-z0-9]*(_[a-z0-9]+)*`, the names `rename_all` can rewrite.
fn is_snake_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    var previous_underscore = false;
    for (name[1..]) |byte| {
        if (byte == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
            continue;
        }
        const lower = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        if (!lower and !digit) return false;
        previous_underscore = false;
    }
    return !previous_underscore;
}

/// Length of `name` after `style`. Precondition: `is_snake_name(name)`.
fn rename_len(name: []const u8, style: RenameAll) u32 {
    assert(is_snake_name(name));
    const underscores: u32 = @intCast(std.mem.count(u8, name, "_"));
    const len: u32 = @intCast(name.len);
    return switch (style) {
        .snake_case, .kebab_case, .screaming_snake_case => len,
        .camel_case, .pascal_case => len - underscores,
    };
}

/// Writes `name` rewritten by `style` into `out`. Preconditions: `is_snake_name(name)` and
/// `out.len == rename_len(name, style)`.
fn rename_into(out: []u8, name: []const u8, style: RenameAll) void {
    assert(is_snake_name(name));
    assert(out.len == rename_len(name, style));
    var capitalize_next = style == .pascal_case;
    var written: usize = 0;
    for (name) |byte| {
        const joiner = byte == '_' and (style == .camel_case or style == .pascal_case);
        if (joiner) {
            capitalize_next = true;
            continue;
        }
        out[written] = switch (style) {
            .snake_case => byte,
            .kebab_case => if (byte == '_') '-' else byte,
            .screaming_snake_case => std.ascii.toUpper(byte),
            .camel_case, .pascal_case => if (capitalize_next) std.ascii.toUpper(byte) else byte,
        };
        capitalize_next = false;
        written += 1;
    }
    assert(written == out.len);
}

const Sample = struct {
    server_name: []const u8,
    port_number: u16 = 80,
    tls: ?bool = null,
};

const Plain = struct {
    alpha: u8,
    beta_gamma: u8 = 1,
};

const Renamed = struct {
    server_name: []const u8,
    port_number: u16 = 80,
    pub const sigil_options = .{
        .rename = .{ .server_name = "host" },
        .rename_all = .kebab_case,
        .deny_unknown_fields = false,
    };
};

const Mode = enum {
    fast_path,
    slow,
    pub const sigil_options = .{ .rename_all = .screaming_snake_case };
};

const Shape = union(enum) {
    unit_circle,
    box_size: u32,
    pub const sigil_options = .{ .rename_all = .pascal_case };
};

test "resolve: no options keeps names, records defaults, denies unknown fields" {
    const table = comptime resolve(Plain);
    try std.testing.expect(table.deny_unknown_fields);
    try std.testing.expectEqual(@as(usize, 2), table.entries.len);
    try std.testing.expectEqualStrings("alpha", table.entries[0].zig_name);
    try std.testing.expectEqualStrings("alpha", table.entries[0].wire_name);
    try std.testing.expect(!table.entries[0].has_default);
    try std.testing.expectEqualStrings("beta_gamma", table.entries[1].wire_name);
    try std.testing.expect(table.entries[1].has_default);
}

test "resolve: optional field without default has no default" {
    const table = comptime resolve(Sample);
    try std.testing.expect(!table.entries[0].has_default);
    try std.testing.expect(table.entries[1].has_default);
    try std.testing.expect(table.entries[2].has_default);
}

test "resolve: rename wins over rename_all, deny_unknown_fields false is honoured" {
    const table = comptime resolve(Renamed);
    try std.testing.expect(!table.deny_unknown_fields);
    try std.testing.expectEqualStrings("server_name", table.entries[0].zig_name);
    try std.testing.expectEqualStrings("host", table.entries[0].wire_name);
    try std.testing.expectEqualStrings("port-number", table.entries[1].wire_name);
}

test "resolve: enum tags follow rename_all and never have defaults" {
    const table = comptime resolve(Mode);
    try std.testing.expectEqualStrings("FAST_PATH", table.entries[0].wire_name);
    try std.testing.expectEqualStrings("SLOW", table.entries[1].wire_name);
    try std.testing.expect(!table.entries[0].has_default);
    try std.testing.expect(!table.deny_unknown_fields);
}

test "resolve: tagged union tags follow rename_all in declaration order" {
    const table = comptime resolve(Shape);
    try std.testing.expectEqual(@as(usize, 2), table.entries.len);
    try std.testing.expectEqualStrings("unit_circle", table.entries[0].zig_name);
    try std.testing.expectEqualStrings("UnitCircle", table.entries[0].wire_name);
    try std.testing.expectEqualStrings("BoxSize", table.entries[1].wire_name);
}

test "resolve: a struct without fields resolves to an empty table" {
    const Empty = struct {};
    const table = comptime resolve(Empty);
    try std.testing.expectEqual(@as(usize, 0), table.entries.len);
    try std.testing.expect(table.deny_unknown_fields);
}

test "find_wire: finds by wire name, not by Zig name" {
    const table = comptime resolve(Renamed);
    try std.testing.expectEqual(@as(?u32, 0), find_wire(table, "host"));
    try std.testing.expectEqual(@as(?u32, 1), find_wire(table, "port-number"));
    try std.testing.expectEqual(@as(?u32, null), find_wire(table, "server_name"));
    try std.testing.expectEqual(@as(?u32, null), find_wire(table, ""));
}

test "is_snake_name: accepts snake names, rejects everything else" {
    const accepted = [_][]const u8{ "a", "ab", "a1", "a_b", "a_1", "port_2_number", "x9" };
    for (accepted) |name| try std.testing.expect(is_snake_name(name));
    const rejected = [_][]const u8{ "", "A", "aB", "_a", "a_", "a__b", "1a", "a-b", "a b", "é" };
    for (rejected) |name| try std.testing.expect(!is_snake_name(name));
}

fn expect_rename(name: []const u8, style: RenameAll, expected: []const u8) !void {
    var out: [64]u8 = undefined;
    const len = rename_len(name, style);
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), len);
    rename_into(out[0..len], name, style);
    try std.testing.expectEqualStrings(expected, out[0..len]);
}

test "rename: every style on a multi-word name" {
    try expect_rename("max_open_files", .snake_case, "max_open_files");
    try expect_rename("max_open_files", .camel_case, "maxOpenFiles");
    try expect_rename("max_open_files", .pascal_case, "MaxOpenFiles");
    try expect_rename("max_open_files", .kebab_case, "max-open-files");
    try expect_rename("max_open_files", .screaming_snake_case, "MAX_OPEN_FILES");
}

test "rename: single-letter words and digits" {
    try expect_rename("a", .camel_case, "a");
    try expect_rename("a", .pascal_case, "A");
    try expect_rename("x_1_y", .camel_case, "x1Y");
    try expect_rename("x_1_y", .pascal_case, "X1Y");
    try expect_rename("v2", .screaming_snake_case, "V2");
}

const Exempt = struct {
    maxSize: u8,
    other_name: u8,
    pub const sigil_options = .{
        .rename = .{ .maxSize = "max_size" },
        .rename_all = RenameAll.kebab_case,
    };
};

const Tagged = union(enum) {
    first_kind: u8,
    second_kind,
    pub const sigil_options = .{ .rename = .{ .second_kind = "two" }, .rename_all = .snake_case };
};

test "resolve: an explicit rename exempts a non-snake name from rename_all" {
    const table = comptime resolve(Exempt);
    try std.testing.expectEqualStrings("max_size", table.entries[0].wire_name);
    try std.testing.expectEqualStrings("other-name", table.entries[1].wire_name);
}

test "resolve: rename applies to union tags, rename_all snake_case is the identity" {
    const table = comptime resolve(Tagged);
    try std.testing.expectEqualStrings("first_kind", table.entries[0].wire_name);
    try std.testing.expectEqualStrings("two", table.entries[1].wire_name);
}

test "resolve: a struct with many fields resolves within its branch quota" {
    const Wide = @Struct(.auto, null, &wide_names, &wide_types, &wide_attrs);
    const table = comptime resolve(Wide);
    try std.testing.expectEqual(@as(usize, wide_names.len), table.entries.len);
    try std.testing.expectEqual(@as(?u32, 63), find_wire(table, "f63"));
}

const wide_names = blk: {
    @setEvalBranchQuota(100_000);
    var names: [64][:0]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = std.fmt.comptimePrint("f{d}", .{index});
    break :blk names;
};
const wide_types = [_]type{u8} ** 64;
const wide_attrs = [_]std.builtin.Type.StructField.Attributes{.{}} ** 64;

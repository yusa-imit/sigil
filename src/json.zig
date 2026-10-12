//! sigil.json — RFC 8259 pull scanner, DOM builder, pretty/minify writer, and the in-memory
//! entry points `parse`/`stringify` (ADR 0003 section 8).
//!
//! Landed: `json/scanner.zig` (pull tokenizer, `locate`, `raw_eql`), `json/dom.zig` (bytes into
//! a `ValueTree`), `json/writer.zig` (minify/pretty). `parse_value`/`write_value` are the
//! Value-level pair; `parse(T)` runs the DOM, then `reflect.parse_traced`, and re-locates a
//! reflect failure in the source: `diag` gets the line:col and snippet of the value the key path
//! names, and keeps reflect's message. `stringify(T)` runs `reflect.stringify`, then the writer.
//!
//! `parseFile`/`stringifyFile` (in `json/file.zig`) carry the file-shaped signature every format
//! module implements identically — see ADR 0001 as amended by ADR 0003 section 9. The parity
//! test in `src/root.zig` holds toml/yaml/msgpack/cbor/proto/csv to this exact shape.
//!
//! Ownership: every function allocates only from the `ValueTree` arena it is given (the writer
//! allocates nothing). `parseFile`/`stringifyFile` allocate only from the caller's `arena` and
//! never free. No allocator and no `Io` is stored; sigil never constructs an `Io`. Every error
//! return writes `diag` exactly once; success never.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const core = @import("core.zig");
const reflect = @import("reflect.zig");

pub const scanner = @import("json/scanner.zig");
pub const dom = @import("json/dom.zig");
pub const writer = @import("json/writer.zig");
const file = @import("json/file.zig");

const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// Module-level error set: everything any function of this module can return.
pub const Error = file.ParseFileError || file.StringifyFileError;

/// What to do when an object repeats a key.
pub const DuplicateKeyPolicy = dom.DuplicateKeyPolicy;

/// Every field is required: no defaults. `deny_unknown_fields` lives on the target type.
pub const ParseOptions = struct {
    /// Containers may nest `depth_max` deep; `1 <= depth_max <= core.value.nesting_max`.
    depth_max: u16,
    /// Input longer than this is `error.InputTooLarge`, before any byte is read.
    bytes_max: u32,
    duplicate_key: DuplicateKeyPolicy,
};

/// Layout, key order, escaping and depth of the output; see `writer.StringifyOptions`.
pub const StringifyOptions = writer.StringifyOptions;

/// Why the text is not a document, or why a `Value` could not be built from it (15 variants).
pub const ParseValueError = dom.ParseValueError;

/// Why a `Value` has no JSON text (5 variants).
pub const WriteValueError = writer.WriteValueError;

/// `parse_value`'s errors plus `reflect.ParseError`; the shared names merge (23 variants).
/// `IntegerOutOfRange` is reflect narrowing into `T`; `IntegerAboveMax` is the DOM past u64.
pub const ParseError = ParseValueError || reflect.ParseError;

/// `reflect.StringifyError` plus `WriteValueError`; the shared names merge (6 variants).
pub const StringifyError = reflect.StringifyError || WriteValueError;

comptime {
    assert(@typeInfo(ParseValueError).error_set.?.len == 15);
    assert(@typeInfo(WriteValueError).error_set.?.len == 5);
    assert(@typeInfo(ParseError).error_set.?.len == 23);
    assert(@typeInfo(StringifyError).error_set.?.len == 6);
}

/// Parses `input`, one JSON document, into `tree` and returns its root, which is not stored in
/// `tree.root`. Strings are copies; the result lives until `tree.deinit()`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= nesting_max`.
pub fn parse_value(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    if (input.len > options.bytes_max) {
        const none = core.diagnostics.position_none;
        diag.* = Diagnostics.init(none, none, "input is larger than bytes_max", null);
        return error.InputTooLarge;
    }
    assert(input.len <= options.bytes_max);
    const dom_options: dom.ParseOptions = .{
        .depth_max = options.depth_max,
        .duplicate_key = options.duplicate_key,
    };
    return dom.parse(tree, input, dom_options, diag);
}

/// Writes `value` to `w` as one JSON document; allocates nothing. See `writer.write`.
/// Preconditions: `1 <= options.depth_max <= nesting_max`; under `.pretty`,
/// `1 <= indent_spaces <= writer.indent_spaces_max`.
pub fn write_value(
    w: *Io.Writer,
    value: Value,
    options: StringifyOptions,
    diag: *Diagnostics,
) WriteValueError!void {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    return writer.write(w, value, options, diag);
}

/// Parses JSON text into `T`: the DOM, then `reflect.parse`. A syntax or number error carries
/// the position the DOM gave. A reflect error is re-located: `diag.line`/`col` and the snippet
/// point at the first byte of the value its key path names (`MissingField` and `UnknownField`
/// at the object's `{`), and the message stays reflect's. Result slices live until
/// `tree.deinit()` and never borrow from `input`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= nesting_max`. A
/// `sigilParse` hook must report failure through `Context.fail` and never write `diag` with a
/// position itself: the position is filled in here from the key path.
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
        relocate(input, options.depth_max, &trace, diag);
        return err;
    };
}

/// Upgrades `diag` from position-less to the source position of the value `trace` names,
/// keeping its message. Precondition: `diag` holds a reflect message at `position_none`.
fn relocate(
    input: []const u8,
    depth_max: u16,
    trace: *const reflect.Path,
    diag: *Diagnostics,
) void {
    assert(diag.line == core.diagnostics.position_none);
    assert(diag.message().len > 0);
    const offset = scanner.locate(input, .{ .depth_max = depth_max }, trace);
    const position = core.diagnostics.position_of(input, offset);
    const snippet = core.diagnostics.snippet_of(input, offset);
    const located = Diagnostics.init(position.line, position.col, diag.message(), snippet);
    assert(located.line >= 1);
    diag.* = located;
}

/// Writes `value` as JSON text: `reflect.stringify` into `tree`, then the writer. Nothing is
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

/// Everything `parseFile` can return: `ParseError` plus file system names (26 variants).
pub const ParseFileError = file.ParseFileError;

/// Everything `stringifyFile` can return: `StringifyError` plus file system names (10 variants).
pub const StringifyFileError = file.StringifyFileError;

pub const parseFile = file.parseFile;
pub const stringifyFile = file.stringifyFile;

test "json: module compiles" {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("json/parse_test.zig");
    _ = @import("json/parse_error_test.zig");
    _ = @import("json/stringify_test.zig");
    _ = file;
}

test "json: error sets have the variant counts of ADR 0003 section 3" {
    const sets = .{
        .{ ParseValueError, 15 },
        .{ WriteValueError, 5 },
        .{ ParseError, 23 },
        .{ StringifyError, 6 },
    };
    inline for (sets) |row| try std.testing.expectEqual(row[1], names_of(row[0]).len);
}

fn names_of(comptime Set: type) []const std.builtin.Type.Error {
    return @typeInfo(Set).error_set.?;
}

fn has_name(comptime Set: type, comptime name: []const u8) bool {
    inline for (comptime names_of(Set)) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "json: ParseError holds every reflect.ParseError name and no stub name" {
    inline for (comptime names_of(reflect.ParseError)) |entry| {
        try std.testing.expect(has_name(ParseError, entry.name));
    }
    inline for (comptime names_of(ParseValueError)) |entry| {
        try std.testing.expect(has_name(ParseError, entry.name));
    }
    const stub_names = [_][]const u8{
        "DepthExceeded", "NumberOutOfRange", "ParseFailed", "UnsupportedType", "NotImplemented",
    };
    inline for (stub_names) |name| {
        try std.testing.expect(!has_name(ParseError, name));
        try std.testing.expect(!has_name(StringifyError, name));
        try std.testing.expect(!has_name(ParseValueError, name));
        try std.testing.expect(!has_name(WriteValueError, name));
    }
}

test "json: StringifyError holds every reflect.StringifyError and WriteValueError name" {
    inline for (comptime names_of(reflect.StringifyError)) |entry| {
        try std.testing.expect(has_name(StringifyError, entry.name));
    }
    inline for (comptime names_of(WriteValueError)) |entry| {
        try std.testing.expect(has_name(StringifyError, entry.name));
    }
}

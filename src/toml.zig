//! sigil.toml — TOML v1.0.0 lexer, parser, writer (order-preserving). toml-test suite.
//!
//! Landed: `toml/lexer.zig`, `toml/scalar.zig` (tokens and scalars), `toml/scratch.zig`,
//! `toml/parser.zig` (keys, tables, arrays, inline tables). `parse_value` is the Value-level
//! entry point; `parse(T)` runs it, then `reflect.parse_traced`, and re-locates a reflect
//! failure in the source: `diag` gets the line:col and snippet of the key (or array element)
//! the key path names, and keeps reflect's message (ADR 0005 sections 6 and 7).
//! `toml/conformance_test.zig` runs the vendored toml-test TOML 1.0.0 corpus (679 cases);
//! `toml/roundtrip_test.zig` holds the round-trip property, corpus mutations and the fuzz entry.
//! `toml/writer.zig` writes a `Value` order-preserving; `write_value` is its entry point and
//! `stringify(T)` runs `reflect.stringify` first. There are no file helpers in v0.5.0
//! (ADR 0005 section 7).
//!
//! Ownership: `gpa` backs the two scratch arrays of one call and is freed before return, so it
//! is never stored; strings, keys and maps go to the `ValueTree` arena. Every error return
//! writes `diag` exactly once; success never.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const core = @import("core.zig");
const reflect = @import("reflect.zig");

pub const lexer = @import("toml/lexer.zig");
pub const scalar = @import("toml/scalar.zig");
pub const parser = @import("toml/parser.zig");
pub const writer = @import("toml/writer.zig");

const Io = std.Io;
const Diagnostics = core.Diagnostics;
const Value = core.Value;
const ValueTree = core.ValueTree;

/// Module-level error set: everything any function of this module can return.
pub const Error = ParseError;

/// Every field is required: no defaults. `deny_unknown_fields` lives on the target type.
pub const ParseOptions = parser.ParseOptions;

/// Why the text is not a TOML document, or why a `Value` could not be built from it.
pub const ParseValueError = parser.ParseValueError;

/// `parse_value`'s errors plus `reflect.ParseError`; the shared names merge.
/// `IntegerOutOfRange` is reflect narrowing into `T`; `IntegerAboveMax` is the TOML i64 limit.
pub const ParseError = ParseValueError || reflect.ParseError;

/// Every field is required: no defaults. See `writer.StringifyOptions`.
pub const StringifyOptions = writer.StringifyOptions;

/// Why a `Value` is not a TOML document (6 variants); `WriteFailed` is the caller's writer.
pub const WriteValueError = writer.WriteValueError;

/// `reflect.StringifyError` plus `WriteValueError`; the shared names merge (7 variants).
pub const StringifyError = reflect.StringifyError || WriteValueError;

comptime {
    assert(@typeInfo(ParseValueError).error_set.?.len == 17);
    assert(@typeInfo(ParseError).error_set.?.len == 25);
    assert(@typeInfo(WriteValueError).error_set.?.len == 6);
    assert(@typeInfo(StringifyError).error_set.?.len == 7);
}

/// Parses `input`, one TOML document, into `tree` and returns its root table, which is not
/// stored in `tree.root`. Strings and keys are copies; the result lives until `tree.deinit()`.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= core.value.nesting_max`.
pub fn parse_value(
    gpa: Allocator,
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    return parser.parse_value(gpa, tree, input, options, diag);
}

/// Parses TOML text into `T`: the document, then `reflect.parse`. A syntax or conflict error
/// carries the position the parser gave. A reflect error is re-located: `diag.line`/`col` and
/// the snippet point at the key of the value its key path names (a table at its header key,
/// an array element at its first byte; `MissingField` and `UnknownField` at the table), and the
/// message stays reflect's. Result slices live until `tree.deinit()` and never borrow from
/// `input`. The re-location parses the text a second time, on the error path only.
/// Preconditions: `tree` was initialized; `1 <= options.depth_max <= nesting_max`. A
/// `sigilParse` hook must report failure through `Context.fail` and never write `diag` with a
/// position itself: the position is filled in here from the key path.
pub fn parse(
    comptime T: type,
    gpa: Allocator,
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseError!T {
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    const root = try parse_value(gpa, tree, input, options, diag);
    var trace: reflect.Path = undefined;
    trace.init();
    return reflect.parse.parse_traced(T, tree, root, diag, &trace) catch |err| {
        relocate(gpa, input, options, &trace, diag);
        return err;
    };
}

/// Writes `value`, which must be a map, to `w` as one TOML document; allocates nothing. Entries
/// keep their order: key/value lines first, then the trailing run of tables and arrays of
/// tables in header form, every other nested map inline. See `writer.write`.
/// Preconditions: `1 <= options.depth_max <= nesting_max`.
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

/// Writes `value` as TOML text: `reflect.stringify` into `tree`, then the writer. Nothing is
/// written to `w` when the conversion fails; the tree holds the converted copy until
/// `tree.deinit()`. `T` must map to a table (a struct or a map), else `RootNotTable`.
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

/// Upgrades `diag` from position-less to the source position of the value `trace` names,
/// keeping its message. Precondition: `diag` holds a reflect message at `position_none`.
fn relocate(
    gpa: Allocator,
    input: []const u8,
    options: ParseOptions,
    trace: *const reflect.Path,
    diag: *Diagnostics,
) void {
    assert(diag.line == core.diagnostics.position_none);
    assert(diag.message().len > 0);
    const offset = parser.locate(gpa, input, options, trace);
    const position = core.diagnostics.position_of(input, offset);
    const snippet = core.diagnostics.snippet_of(input, offset);
    const located = Diagnostics.init(position.line, position.col, diag.message(), snippet);
    assert(located.line >= 1);
    diag.* = located;
}

test {
    _ = @import("toml/lexer_test.zig");
    _ = @import("toml/scalar_test.zig");
    _ = @import("toml/scratch_test.zig");
    _ = @import("toml/parser_test.zig");
    _ = @import("toml/parser_value_test.zig");
    _ = @import("toml/parse_test.zig");
    _ = @import("toml/conformance_test.zig");
    _ = @import("toml/writer.zig");
    _ = @import("toml/stringify_test.zig");
    _ = @import("toml/roundtrip_test.zig");
}

test "toml: module compiles" {
    std.testing.refAllDecls(@This());
}

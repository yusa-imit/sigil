//! sigil.json — RFC 8259 pull scanner, DOM builder, pretty/minify writer, direct-to-struct
//! streaming parse.
//!
//! Planned files (see docs/PRD.md):
//!   - `json/scanner.zig`
//!   - `json/dom.zig`
//!   - `json/writer.zig`
//!   - `json/reflect.zig`
//!
//! Status: stub. `parseFile`/`stringifyFile` carry the file-shaped signature that every format
//! module implements identically — see `docs/adr/0001-io-convention.md`. The parity test in
//! `src/root.zig` holds toml/yaml/msgpack/cbor/proto/csv to this exact shape when they add it.
//!
//! Ownership: `parseFile` allocates only from the caller's `arena` and never frees.
//! `stringifyFile` allocates nothing: it writes through the caller's `scratch`. No allocator and
//! no `Io` is stored; sigil never constructs an `Io`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

/// What to do when an object repeats a key.
pub const DuplicateKeyPolicy = enum { first, last, reject };

/// Every field is required: no defaults.
pub const ParseOptions = struct {
    /// Maximum array/object nesting; hostile input past it returns `error.DepthExceeded`.
    depth_max: u16,
    /// Input size ceiling; a file at or above it returns `error.InputTooLarge`.
    bytes_max: Io.Limit,
    duplicate_key: DuplicateKeyPolicy,
    deny_unknown_fields: bool,
};

/// Every field is required: no defaults.
pub const StringifyOptions = struct {
    pretty: bool,
    indent_spaces: u8,
    depth_max: u16,
    sort_keys: bool,
};

/// `|| Error` is stub scaffolding, deleted when the module lands.
pub const ParseFileError = error{
    OutOfMemory,
    Canceled,
    FileNotFound,
    AccessDenied,
    ReadFailed,
    InputTooLarge,
    /// Malformed JSON; `Diagnostics` carries file:line:col once `core` lands.
    ParseFailed,
    DepthExceeded,
    TypeMismatch,
    MissingField,
    UnknownField,
    NumberOutOfRange,
    InvalidUtf8,
} || Error;

/// `|| Error` is stub scaffolding, deleted when the module lands.
pub const StringifyFileError = error{
    Canceled,
    AccessDenied,
    NoSpaceLeft,
    WriteFailed,
    DepthExceeded,
    /// `value` contains a type JSON cannot represent.
    UnsupportedType,
} || Error;

/// Reads `sub_path` under `dir` and parses it into `T`.
///
/// Parameter order is the kingdom convention (ADR-0001): `comptime T`, `io`, memory, subject,
/// options. `dir` is explicit — sigil never calls `Io.Dir.cwd()` for the caller.
///
/// Preconditions: `sub_path` is non-empty; `options.depth_max > 0`.
/// Ownership: allocations come from `arena` and are never freed by sigil; strings in the result
/// borrow from it, so the result lives exactly as long as the arena.
/// Status: returns `error.NotImplemented` until the module lands.
pub fn parseFile(
    comptime T: type,
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    options: ParseOptions,
) ParseFileError!T {
    assert(sub_path.len > 0);
    assert(options.depth_max > 0);
    _ = io;
    _ = arena;
    _ = dir;
    return error.NotImplemented;
}

/// Serializes `value` into `sub_path` under `dir`, streaming through `scratch`.
///
/// Parameter order is the kingdom convention (ADR-0001): with no comptime type parameter and no
/// receiver, `io` is first; `scratch` is the memory slot; `dir`/`sub_path`/`value` are subject.
///
/// Preconditions: `sub_path` is non-empty; `scratch.len >= scratch_bytes_min`;
/// `options.depth_max > 0`.
/// Ownership: allocates nothing. The file is created or truncated.
/// Status: returns `error.NotImplemented` until the module lands.
pub fn stringifyFile(
    io: Io,
    scratch: []u8,
    dir: Io.Dir,
    sub_path: []const u8,
    value: anytype,
    options: StringifyOptions,
) StringifyFileError!void {
    assert(sub_path.len > 0);
    assert(scratch.len >= scratch_bytes_min);
    assert(options.depth_max > 0);
    _ = io;
    _ = dir;
    _ = value;
    return error.NotImplemented;
}

/// Smallest write buffer `stringifyFile` accepts: one maximal escaped scalar must fit.
pub const scratch_bytes_min: u32 = 64;

test "json: module compiles" {
    std.testing.refAllDecls(@This());
}

test "json: parseFile is driven by std.testing.io and is not implemented yet" {
    const App = struct { port: u16 };
    const result = parseFile(App, std.testing.io, std.testing.allocator, Io.Dir.cwd(), "a.json", .{
        .depth_max = 128,
        .bytes_max = .limited(1 << 20),
        .duplicate_key = .reject,
        .deny_unknown_fields = true,
    });
    try std.testing.expectError(error.NotImplemented, result);
}

test "json: stringifyFile is driven by std.testing.io and is not implemented yet" {
    var scratch: [scratch_bytes_min]u8 = @splat(0);
    const result = stringifyFile(std.testing.io, &scratch, Io.Dir.cwd(), "app.json", .{
        .port = @as(u16, 8080),
    }, .{
        .pretty = true,
        .indent_spaces = 2,
        .depth_max = 128,
        .sort_keys = false,
    });
    try std.testing.expectError(error.NotImplemented, result);
}

//! sigil.config — Layered config: defaults < files < env < args; schema validation; change
//! watching.
//!
//! Planned files (see docs/PRD.md):
//!   - `config/layered.zig`
//!   - `config/env.zig`
//!   - `config/args.zig`
//!   - `config/watch.zig`
//!
//! Status: signature stub. `load` and `Watcher` carry their final public shape — see
//! `docs/adr/0001-io-convention.md` — and return `error.NotImplemented` until plan 002 lands
//! `core/` and `reflect/`.
//!
//! Ownership: `load` allocates only from the caller's `arena` and never frees; the caller drops
//! the whole arena. `Watcher` allocates once in `init` from `gpa`, never grows, and hands the
//! same `gpa` back at `deinit`. This module stores no allocator and no `Io`: `io` is a parameter
//! of every call that touches the filesystem or the clock, and sigil never constructs one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

/// Upper bound on config sources and on watched paths. A caller past this limit is a programmer
/// error, asserted, not an error return.
pub const files_max: u32 = 32;

/// File format of one config source. `auto` picks by filename extension.
pub const Format = enum { json, toml, yaml, auto };

/// One file layer. Later entries in `Options.sources` win over earlier ones.
pub const Source = struct {
    /// Resolved against `Options.dir`.
    path: []const u8,
    format: Format,
    /// When false, a missing file is skipped instead of returning `error.FileNotFound`.
    required: bool,
};

/// Environment layer. sigil never reads the environment itself: a binary passes
/// `init.environ_map` from `std.process.Init` here, exactly as it passes `io`.
pub const Env = struct {
    map: *const std.process.Environ.Map,
    /// `"APP_"` selects `APP_SERVER__PORT`.
    prefix: []const u8,
    /// `"__"` maps `APP_SERVER__PORT` to the field path `server.port`.
    nesting_separator: []const u8,
};

/// Argument layer. The caller owns `argv`; sigil never reads process arguments itself.
pub const Args = struct {
    argv: []const []const u8,
    /// `"--"` selects `--server.port=9090`.
    prefix: []const u8,
    /// `"."` maps `--server.port` to the field path `server.port`.
    nesting_separator: []const u8,
};

/// Every field is required: no defaults, so each call site states each choice.
pub const Options = struct {
    /// Directory that `Source.path` entries are resolved against. Pass `Io.Dir.cwd()`
    /// explicitly; sigil never reaches for the process working directory.
    dir: Io.Dir,
    /// Ascending precedence; `sources.len <= files_max` is a precondition.
    sources: []const Source,
    /// `null` disables the environment layer.
    env: ?Env,
    /// `null` disables the argument layer.
    args: ?Args,
    /// Per-file read limit; a file at or above it returns `error.FileTooBig`.
    file_bytes_max: Io.Limit,
    /// Maximum nesting depth accepted from any layer.
    depth_max: u16,
    deny_unknown_fields: bool,
};

/// Failure vocabulary of `load`. Written by hand rather than composed from std's I/O sets so
/// sigil's public contract does not change shape with std; `error.OutOfMemory` and
/// `error.Canceled` pass through unmapped. `|| Error` is stub scaffolding, deleted by plan 002.
pub const LoadError = error{
    /// Allocation from `arena` failed.
    OutOfMemory,
    /// The caller canceled the operation through `io`; never swallowed.
    Canceled,
    /// A `Source` with `required = true` does not exist.
    FileNotFound,
    /// A config file exists but cannot be opened.
    AccessDenied,
    /// A config file reached `Options.file_bytes_max`.
    FileTooBig,
    /// The file opened but the read failed partway.
    ReadFailed,
    /// A file layer is syntactically malformed.
    ParseFailed,
    /// A layer supplied a value whose type does not match the field of `T`.
    TypeMismatch,
    /// A field of `T` has no default and no layer supplied it.
    MissingField,
    /// `deny_unknown_fields` was set and a layer carried a key absent from `T`.
    UnknownField,
    /// The merged value violates `T`'s declared validation rules.
    SchemaInvalid,
    /// An environment variable under `Env.prefix` could not be interpreted.
    EnvInvalid,
    /// An argument under `Args.prefix` could not be interpreted.
    ArgsInvalid,
} || Error;

/// Loads `T` from defaults < files < env < args and returns it by value.
///
/// Parameter order is the kingdom convention (ADR-0001): the `comptime T` parameter takes the
/// receiver slot, `io` comes immediately after it, then memory, then options.
///
/// Preconditions: `T` is a struct; `options.sources.len <= files_max`; `options.depth_max > 0`.
/// Ownership: every allocation comes from `arena` and is never freed by sigil — the caller drops
/// the arena as a unit. A failed `load` may leave partial allocations in it. Reload by resetting
/// the arena and calling `load` again.
/// Status: returns `error.NotImplemented` until plan 002.
pub fn load(comptime T: type, io: Io, arena: Allocator, options: Options) LoadError!T {
    comptime assert(@typeInfo(T) == .@"struct");
    assert(options.sources.len <= files_max);
    assert(options.depth_max > 0);
    _ = io;
    _ = arena;
    return error.NotImplemented;
}

/// Polling file-change watcher. Not a callback: user code never runs inside an I/O completion
/// (Tiger Style 1.14), the clock is an argument, and work per call is bounded by `paths.len`.
/// Drain it with `while (try watcher.poll(io)) |change| { ... }`.
pub const Watcher = struct {
    /// Paths watched, in the order given to `init`; `Change.path_index` indexes this slice.
    paths: []const []const u8,
    /// Lower bound on the time between stat sweeps; `poll` does no I/O before it elapses.
    sweep_interval_min: Io.Duration,
    /// `Io.Clock.awake` reading at the last sweep.
    swept_at: Io.Timestamp,

    pub const ChangeKind = enum(u8) { created, modified, deleted };

    /// One observed change. Repeated writes between two sweeps coalesce into one `.modified`.
    pub const Change = struct {
        path_index: u32,
        kind: ChangeKind,
    };

    /// Every field is required: no defaults.
    pub const Options = struct {
        /// Directory `paths` are resolved against. Pass `Io.Dir.cwd()` explicitly.
        dir: Io.Dir,
        /// `paths.len <= files_max` is a precondition. A path that does not exist yet is legal:
        /// its appearance is reported as `.created`.
        paths: []const []const u8,
        sweep_interval_min: Io.Duration,
    };

    /// `|| Error` is stub scaffolding, deleted by plan 002.
    pub const InitError = error{
        OutOfMemory,
        Canceled,
        AccessDenied,
        /// A path exists but its metadata could not be read.
        StatFailed,
    } || Error;

    /// `|| Error` is stub scaffolding, deleted by plan 002.
    pub const PollError = error{
        Canceled,
        AccessDenied,
        StatFailed,
    } || Error;

    /// Takes the baseline snapshot so the first `poll` reports only real changes.
    ///
    /// Preconditions: `options.paths.len <= files_max`; `sweep_interval_min` is positive.
    /// Ownership: allocates its fixed arrays from `gpa` here and never grows; `deinit` takes the
    /// same `gpa`. Initializes through `target` in place (Tiger Style 3.4).
    /// Status: returns `error.NotImplemented` until plan 002.
    pub fn init(target: *Watcher, io: Io, gpa: Allocator, options: Watcher.Options) InitError!void {
        assert(options.paths.len <= files_max);
        assert(options.sweep_interval_min.nanoseconds > 0);
        _ = target;
        _ = io;
        _ = gpa;
        return error.NotImplemented;
    }

    /// Releases everything `init` allocated. `gpa` must be the allocator passed to `init`.
    pub fn deinit(watcher: *Watcher, gpa: Allocator) void {
        assert(watcher.paths.len <= files_max);
        _ = gpa;
    }

    /// Returns the next observed change, or `null` when nothing changed or the sweep interval
    /// has not elapsed. At most one stat sweep per `sweep_interval_min`; at most `paths.len`
    /// changes per sweep, so the drain loop is bounded.
    ///
    /// Preconditions: `init` returned successfully.
    /// Status: returns `error.NotImplemented` until plan 002.
    pub fn poll(watcher: *Watcher, io: Io) PollError!?Change {
        assert(watcher.paths.len <= files_max);
        assert(watcher.sweep_interval_min.nanoseconds > 0);
        _ = io;
        return error.NotImplemented;
    }
};

test "config: module compiles" {
    std.testing.refAllDecls(@This());
}

test "config: load is driven by std.testing.io and is not implemented yet" {
    const App = struct { port: u16 };
    const result = load(App, std.testing.io, std.testing.allocator, .{
        .dir = Io.Dir.cwd(),
        .sources = &.{},
        .env = null,
        .args = null,
        .file_bytes_max = .limited(1 << 20),
        .depth_max = 128,
        .deny_unknown_fields = true,
    });
    try std.testing.expectError(error.NotImplemented, result);
}

test "config: watcher is driven by std.testing.io and is not implemented yet" {
    var watcher: Watcher = .{
        .paths = &.{"app.toml"},
        .sweep_interval_min = .fromMilliseconds(500),
        .swept_at = .zero,
    };
    const init_result = watcher.init(std.testing.io, std.testing.allocator, .{
        .dir = Io.Dir.cwd(),
        .paths = &.{"app.toml"},
        .sweep_interval_min = .fromMilliseconds(500),
    });
    try std.testing.expectError(error.NotImplemented, init_result);
    try std.testing.expectError(error.NotImplemented, watcher.poll(std.testing.io));
    watcher.deinit(std.testing.allocator);
}

test "config: io is the parameter after the comptime type on load" {
    const params = @typeInfo(@TypeOf(load)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 4), params.len);
    try std.testing.expectEqual(type, params[0].type.?);
    try std.testing.expectEqual(Io, params[1].type.?);
    try std.testing.expectEqual(Allocator, params[2].type.?);
    try std.testing.expectEqual(Options, params[3].type.?);
}

test "config: io is the parameter after the receiver on every Watcher method" {
    const init_params = @typeInfo(@TypeOf(Watcher.init)).@"fn".params;
    try std.testing.expectEqual(*Watcher, init_params[0].type.?);
    try std.testing.expectEqual(Io, init_params[1].type.?);
    const poll_params = @typeInfo(@TypeOf(Watcher.poll)).@"fn".params;
    try std.testing.expectEqual(*Watcher, poll_params[0].type.?);
    try std.testing.expectEqual(Io, poll_params[1].type.?);
}

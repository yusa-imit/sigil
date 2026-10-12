//! sigil.json file wrappers: `parseFile` and `stringifyFile` (ADR 0003 section 9, which amends
//! ADR 0001), re-exported by `json.zig`.
//!
//! `parseFile` reads the whole file into the caller's `arena` (at most `bytes_max` bytes), then
//! runs `json.parse` over a `ValueTree` backed by that arena. `stringifyFile` converts the value
//! with `reflect.stringify`, then creates or truncates the file and streams the writer's output
//! through a `file_buffer_size` buffer taken from the arena. Neither function frees anything:
//! the caller drops the arena. No allocator and no `Io` is stored; sigil never constructs an `Io`.
//!
//! Failure contract: every error return writes `diag` exactly once and success never does. File
//! system failures carry `position_none` and a message; a malformed file carries its line:col.
//! The `reflect` conversion in `stringifyFile` runs before the file is touched, so a value
//! reflect cannot convert leaves an existing file as it was. Failures of the writer itself
//! (`Unrepresentable`, `TooDeep`, an I/O error) come after the file was created or truncated and
//! leave it partial: the write is not atomic.
//!
//! std's OS error sets are not re-exported. The `map_*` functions collapse them by hand into the
//! few names below; `OutOfMemory` and `Canceled` pass through because their meaning is canonical.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const core = @import("../core.zig");
const reflect = @import("../reflect.zig");
const json = @import("../json.zig");

const Diagnostics = core.Diagnostics;
const ValueTree = core.ValueTree;

/// Size of the write buffer `stringifyFile` takes from the arena.
pub const file_buffer_size: u32 = 4096;

/// What reading a file can add to `json.ParseError` (6 variants, `InputTooLarge` included).
pub const ReadError = error{
    OutOfMemory,
    Canceled,
    FileNotFound,
    AccessDenied,
    ReadFailed,
    InputTooLarge,
};

/// What creating or writing a file can fail with (5 variants).
pub const WriteError = error{
    Canceled,
    FileNotFound,
    AccessDenied,
    NoSpaceLeft,
    WriteFailed,
};

/// Every file system failure `diag` can describe (8 variants).
const IoError = ReadError || WriteError;

/// `json.ParseError` plus the file layer's own names; shared names merge (27 variants).
pub const ParseFileError = json.ParseError || ReadError;

/// `json.StringifyError` plus the file layer's own names; shared names merge (10 variants).
pub const StringifyFileError = json.StringifyError || WriteError;

comptime {
    assert(@typeInfo(ReadError).error_set.?.len == 6);
    assert(@typeInfo(WriteError).error_set.?.len == 5);
    assert(@typeInfo(IoError).error_set.?.len == 8);
    assert(@typeInfo(ParseFileError).error_set.?.len == 27);
    assert(@typeInfo(StringifyFileError).error_set.?.len == 10);
}

/// Reads `sub_path` under `dir` and parses it into `T`.
///
/// Parameter order is the kingdom convention (ADR 0001): `comptime T`, `io`, memory, subject,
/// options, then `diag`. `dir` is explicit: sigil never calls `Io.Dir.cwd()` for the caller.
///
/// Preconditions: `sub_path` is non-empty; `1 <= options.depth_max <= nesting_max`.
/// Ownership: every allocation, the file text included, comes from `arena` and is never freed
/// by sigil; strings in the result live exactly as long as the arena. A file longer than
/// `options.bytes_max` is `InputTooLarge`. On error `diag` is written once.
pub fn parseFile(
    comptime T: type,
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    options: json.ParseOptions,
    diag: *Diagnostics,
) ParseFileError!T {
    assert(sub_path.len > 0);
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    // One byte past `bytes_max`: `readFileAlloc` fails once the size reaches its limit.
    const read_limit: Io.Limit = .limited64(@as(u64, options.bytes_max) + 1);
    const input = dir.readFileAlloc(io, sub_path, arena, read_limit) catch |err| {
        const mapped = map_read_error(err);
        io_failure(diag, mapped);
        return mapped;
    };
    assert(input.len <= options.bytes_max);
    var tree: ValueTree = undefined;
    ValueTree.init(&tree, arena);
    return json.parse(T, &tree, input, options, diag);
}

/// Serializes `value` into `sub_path` under `dir`, creating or truncating the file, and ends it
/// with one `\n`.
///
/// Parameter order is the kingdom convention (ADR 0001): with no comptime type parameter and no
/// receiver, `io` is first, then the memory slot, then subject and options, then `diag`.
///
/// Preconditions: `sub_path` is non-empty; `1 <= options.depth_max <= nesting_max`.
/// Ownership: the converted tree and the write buffer come from `arena` and are never freed by
/// sigil; pass a `FixedBufferAllocator` for a hard bound, and `OutOfMemory` means it was hit.
/// On error `diag` is written once; a write failure leaves a partial file.
pub fn stringifyFile(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    value: anytype,
    options: json.StringifyOptions,
    diag: *Diagnostics,
) StringifyFileError!void {
    assert(sub_path.len > 0);
    assert(options.depth_max >= 1);
    assert(options.depth_max <= core.value.nesting_max);
    var tree: ValueTree = undefined;
    ValueTree.init(&tree, arena);
    const converted = try reflect.stringify.stringify(@TypeOf(value), &tree, value, diag);
    const buffer = arena.alloc(u8, file_buffer_size) catch {
        io_failure(diag, error.OutOfMemory);
        return error.OutOfMemory;
    };
    var handle = dir.createFile(io, sub_path, .{ .truncate = true }) catch |err| {
        const mapped = map_create_error(err);
        io_failure(diag, mapped);
        return mapped;
    };
    defer handle.close(io);

    var file_writer = handle.writer(io, buffer);
    json.write_value(&file_writer.interface, converted, options, diag) catch |err| {
        return write_failure(err, &file_writer);
    };
    try finish(&file_writer, diag);
}

/// Appends the final newline and flushes. Writes `diag` itself because no layer below does.
fn finish(file_writer: *Io.File.Writer, diag: *Diagnostics) WriteError!void {
    file_writer.interface.writeByte('\n') catch {
        const mapped = map_writer_failure(file_writer);
        io_failure(diag, mapped);
        return mapped;
    };
    file_writer.interface.flush() catch {
        const mapped = map_writer_failure(file_writer);
        io_failure(diag, mapped);
        return mapped;
    };
}

/// `write_value` failed; it has already written `diag`. Names the file system cause when the
/// failure was the writer's.
fn write_failure(err: json.WriteValueError, file_writer: *Io.File.Writer) StringifyFileError {
    // proof: only `WriteFailed` is the file's; every other name is the document's and passes.
    switch (err) {
        error.WriteFailed => return map_writer_failure(file_writer),
        else => |document_error| return document_error,
    }
}

/// The std error a failed `Io.File.Writer` recorded, mapped; `WriteFailed` when it recorded none.
fn map_writer_failure(file_writer: *const Io.File.Writer) WriteError {
    const recorded = file_writer.err orelse return error.WriteFailed;
    return map_write_error(recorded);
}

/// Fills `diag` for a file system failure: no source position, a fixed message.
fn io_failure(diag: *Diagnostics, err: IoError) void {
    const none = core.diagnostics.position_none;
    diag.* = Diagnostics.init(none, none, io_message(err), null);
    assert(diag.line == none);
    assert(diag.message().len > 0);
}

fn io_message(err: IoError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.Canceled => "operation canceled",
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.ReadFailed => "file could not be read",
        error.InputTooLarge => "input is larger than bytes_max",
        error.NoSpaceLeft => "no space left on device",
        error.WriteFailed => "file could not be written",
    };
}

/// Collapses std's read errors into `ReadError`; names not listed are `ReadFailed`.
pub fn map_read_error(err: Io.Dir.ReadFileAllocError) ReadError {
    // proof: `else` is the documented catch-all, so a new std name cannot escape the set.
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        error.StreamTooLong, error.FileTooBig => return error.InputTooLarge,
        else => return error.ReadFailed,
    }
}

/// Collapses std's open/create errors into `WriteError`; names not listed are `WriteFailed`.
pub fn map_create_error(err: Io.File.OpenError) WriteError {
    // proof: `else` is the documented catch-all, so a new std name cannot escape the set.
    switch (err) {
        error.Canceled => return error.Canceled,
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        error.ReadOnlyFileSystem => return error.AccessDenied,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        else => return error.WriteFailed,
    }
}

/// Collapses std's write errors into `WriteError`; names not listed are `WriteFailed`.
pub fn map_write_error(err: Io.File.Writer.Error) WriteError {
    // proof: `else` is the documented catch-all, so a new std name cannot escape the set.
    switch (err) {
        error.Canceled => return error.Canceled,
        error.NoSpaceLeft, error.DiskQuota => return error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.WriteFailed,
    }
}

test {
    _ = @import("file_test.zig");
}

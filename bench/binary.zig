//! Binary-format benchmarks for `zig build bench`: msgpack and CBOR decode and encode.
//! The input is the harness's seeded ~1 MiB JSON record document, parsed once into a tree and
//! encoded once per format; decode benchmarks read those bytes, encode benchmarks write the
//! decoded tree back to a discarding sink. Input generation is never timed, and the numbers use
//! the same MB/s and arena-bytes-per-input-byte units as `main.zig` (MB/s counts encoded bytes).
//! Allocation: `gpa` is the caller's; every function frees what it takes.
const std = @import("std");
const sigil = @import("sigil");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// What one benchmark measured: bytes it pushed through the format code across all iterations,
/// the time that took, the arena capacity one iteration needed (0 when it has no arena), and,
/// for the `path` benchmarks, how many nodes they resolved or selected across all iterations
/// (0 for the format benchmarks, which print no ns per match).
pub const Result = struct {
    bytes_total: u64,
    elapsed_ns: u64,
    arena_bytes: u64,
    matches_total: u64 = 0,
};

pub const BenchError = error{ OutOfMemory, BenchFailed };

/// The encoded input is at least this long: the plan asks for a record tree of about 1 MiB and
/// the binary encodings are denser than JSON, so the floor sits below `1 << 20`.
pub const input_bytes_min: u32 = 512 << 10;

/// Every benchmark repeats its measured step this many times.
const iterations: u32 = 16;

const depth_max: u16 = 64;

const bytes_max: u32 = 64 << 20;

/// Encodes the JSON `document` as MessagePack. Same document, same bytes. Caller frees.
pub fn msgpack_input(gpa: Allocator, document: []const u8) BenchError![]u8 {
    return encode_document(sigil.msgpack, gpa, document);
}

/// Encodes the JSON `document` as CBOR (insertion-order keys). Caller frees.
pub fn cbor_input(gpa: Allocator, document: []const u8) BenchError![]u8 {
    return encode_document(sigil.cbor, gpa, document);
}

pub fn msgpack_decode(gpa: Allocator, io: std.Io, input: []const u8) BenchError!Result {
    return bench_decode(sigil.msgpack, gpa, io, input);
}

pub fn msgpack_encode(gpa: Allocator, io: std.Io, input: []const u8) BenchError!Result {
    return bench_encode(sigil.msgpack, gpa, io, input);
}

pub fn cbor_decode(gpa: Allocator, io: std.Io, input: []const u8) BenchError!Result {
    return bench_decode(sigil.cbor, gpa, io, input);
}

pub fn cbor_encode(gpa: Allocator, io: std.Io, input: []const u8) BenchError!Result {
    return bench_encode(sigil.cbor, gpa, io, input);
}

fn bench_decode(
    comptime codec: type,
    gpa: Allocator,
    io: std.Io,
    input: []const u8,
) BenchError!Result {
    const arena_bytes = try decode_once(codec, gpa, input); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try decode_once(codec, gpa, input);
        assert(got == arena_bytes);
    }
    return .{
        .bytes_total = @as(u64, iterations) * input.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = arena_bytes,
    };
}

/// Decodes `input` into a fresh tree and returns the arena capacity it needed.
fn decode_once(comptime codec: type, gpa: Allocator, input: []const u8) BenchError!u64 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    _ = try decode_root(codec, &tree, input);
    return tree.arena.queryCapacity();
}

fn decode_root(
    comptime codec: type,
    tree: *sigil.core.ValueTree,
    input: []const u8,
) BenchError!sigil.core.Value {
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const options: codec.ParseOptions = .{
        .depth_max = depth_max,
        .bytes_max = bytes_max,
        .duplicate_key = .reject,
    };
    return codec.parse_value(tree, input, options, &diag) catch |err| {
        std.log.err("bench: decode failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BenchFailed, // The generated input is valid; any other is a bug.
        };
    };
}

fn bench_encode(
    comptime codec: type,
    gpa: Allocator,
    io: std.Io,
    input: []const u8,
) BenchError!Result {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const root = try decode_root(codec, &tree, input);
    const output_bytes = try encode_once(codec, root); // Warm-up: caches.
    var bytes_total: u64 = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try encode_once(codec, root);
        assert(got == output_bytes);
        bytes_total += got;
    }
    const elapsed_ns = elapsed_ns_since(io, start);
    assert(bytes_total > 0);
    return .{ .bytes_total = bytes_total, .elapsed_ns = elapsed_ns, .arena_bytes = 0 };
}

/// Writes `root` into a discarding sink and returns the output length.
fn encode_once(comptime codec: type, root: sigil.core.Value) BenchError!u64 {
    var buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buffer);
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    write(codec, &sink.writer, root, &diag) catch |err| {
        std.log.err("bench: encode failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
    return sink.fullCount();
}

fn write(
    comptime codec: type,
    w: *std.Io.Writer,
    root: sigil.core.Value,
    diag: *sigil.core.Diagnostics,
) codec.WriteValueError!void {
    const options: codec.StringifyOptions = if (codec == sigil.cbor)
        .{ .depth_max = depth_max, .deterministic = false }
    else
        .{ .depth_max = depth_max };
    return codec.write_value(w, root, options, diag);
}

fn encode_document(comptime codec: type, gpa: Allocator, document: []const u8) BenchError![]u8 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const json_options: sigil.json.ParseOptions = .{
        .depth_max = depth_max,
        .bytes_max = bytes_max,
        .duplicate_key = .reject,
    };
    const root = sigil.json.parse_value(&tree, document, json_options, &diag) catch |err| {
        std.log.err("bench: json parse failed: {s}", .{@errorName(err)});
        return error.BenchFailed;
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    // proof: the only writer that can fail is `out`, whose failure is an allocation failure; the
    // generated tree is valid, so every other error is a bug in the harness.
    write(codec, &out.writer, root, &diag) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => {
            std.log.err("bench: encode failed: {s}: {s}", .{ @errorName(err), diag.message() });
            return error.BenchFailed;
        },
    };
    return out.toOwnedSlice();
}

/// Nanoseconds from `start` to now on the awake clock; the clock never runs backwards.
fn elapsed_ns_since(io: std.Io, start: std.Io.Timestamp) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    assert(elapsed >= 0);
    assert(elapsed <= std.math.maxInt(u64));
    return @intCast(elapsed);
}

const sample_json =
    \\{"id":7,"name":"sigil","score":1.5,"active":true,"none":null,"tags":["a","b"],
    \\ "owner":{"x":-3,"y":18446744073709551615}}
;

test "bench: the inputs are deterministic and decode to the json tree" {
    const gpa = std.testing.allocator;
    const first = try msgpack_input(gpa, sample_json);
    defer gpa.free(first);

    const second = try msgpack_input(gpa, sample_json);
    defer gpa.free(second);

    const cbor_bytes = try cbor_input(gpa, sample_json);
    defer gpa.free(cbor_bytes);

    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(!std.mem.eql(u8, first, cbor_bytes));

    var json_tree: sigil.core.ValueTree = undefined;
    json_tree.init(gpa);
    defer json_tree.deinit();

    var pack_tree: sigil.core.ValueTree = undefined;
    pack_tree.init(gpa);
    defer pack_tree.deinit();

    var cbor_tree: sigil.core.ValueTree = undefined;
    cbor_tree.init(gpa);
    defer cbor_tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const json_options: sigil.json.ParseOptions = .{
        .depth_max = depth_max,
        .bytes_max = bytes_max,
        .duplicate_key = .reject,
    };
    const expected = try sigil.json.parse_value(&json_tree, sample_json, json_options, &diag);
    const from_pack = try decode_root(sigil.msgpack, &pack_tree, first);
    const from_cbor = try decode_root(sigil.cbor, &cbor_tree, cbor_bytes);

    try std.testing.expect(try sigil.core.value.eql(expected, from_pack));
    try std.testing.expect(try sigil.core.value.eql(expected, from_cbor));
}

test "bench: encoding a tree twice gives the same byte count" {
    const gpa = std.testing.allocator;
    const bytes = try cbor_input(gpa, sample_json);
    defer gpa.free(bytes);

    const result = try cbor_encode(gpa, std.testing.io, bytes);

    try std.testing.expectEqual(@as(u64, iterations) * bytes.len, result.bytes_total);
    try std.testing.expectEqual(@as(u64, 0), result.arena_bytes);
}

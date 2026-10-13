//! sigil benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  MB/s  arena bytes per input byte` so the numbers can be pasted
//! into docs/plans/. One seeded JSON document of about 1 MiB is generated once and shared by
//! every benchmark; no corpus is vendored. Timing covers only the measured loop, never the
//! document generation. Allocation: `gpa` is `init.gpa`; every benchmark frees what it takes.
const std = @import("std");
const sigil = @import("sigil");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The generated document is at least this long.
const document_bytes_min: u32 = 1 << 20;

/// Seed of the document generator: the same bytes on every run and every machine.
const document_seed: u64 = 0x51_61_1;

/// Every benchmark repeats its measured step this many times.
const iterations: u32 = 16;

const parse_options: sigil.json.ParseOptions = .{
    .depth_max = 64,
    .bytes_max = 64 << 20,
    .duplicate_key = .reject,
};

const stringify_options: sigil.json.StringifyOptions = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = 64,
};

const Owner = struct { x: i64, y: i64 };

const Record = struct {
    id: i64,
    name: []const u8,
    score: f64,
    active: bool,
    tags: []const []const u8,
    owner: Owner,
};

const Document = struct { records: []const Record };

/// What one benchmark measured: bytes it pushed through the format code across all iterations,
/// the time that took, and the arena capacity one iteration needed (0 when it has no arena).
const Result = struct {
    bytes_total: u64,
    elapsed_ns: u64,
    arena_bytes: u64,
};

const BenchError = error{ OutOfMemory, BenchFailed };

const Bench = struct {
    name: []const u8,
    run: *const fn (Allocator, std.Io, []const u8) BenchError!Result,
};

const benches = [_]Bench{
    .{ .name = "json.dom.parse", .run = bench_dom_parse },
    .{ .name = "json.write.minified", .run = bench_write },
    .{ .name = "json.parse(T)", .run = bench_parse_typed },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1); // argv[0] (the program name) always exists.
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    const document = try generate_document(init.gpa, document_seed);
    defer init.gpa.free(document);

    assert(document.len >= document_bytes_min);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("document: {d} bytes (seed {d}), {d} iterations each\n", .{
        document.len, document_seed, iterations,
    });
    for (benches) |bench| {
        if (filter) |needle| {
            if (std.mem.find(u8, bench.name, needle) == null) continue;
        }
        const result = try bench.run(init.gpa, init.io, document);
        try out.print("{s:<24} {d:>9.1} MB/s {d:>7.2} arena bytes/input byte\n", .{
            bench.name,
            megabytes_per_second(result.bytes_total, result.elapsed_ns),
            arena_ratio(result.arena_bytes, document.len),
        });
    }
    try out.flush();
    assert(out.end == 0); // Postcondition: output is fully drained before returning.
}

fn bench_dom_parse(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try dom_parse_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        assert(try dom_parse_once(gpa, document) == arena_bytes);
    }
    return .{
        .bytes_total = @as(u64, iterations) * document.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = arena_bytes,
    };
}

/// Parses `document` into a fresh tree and returns the arena capacity it needed.
fn dom_parse_once(gpa: Allocator, document: []const u8) BenchError!u64 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    _ = sigil.json.parse_value(&tree, document, parse_options, &diag) catch |err| {
        return fail_parse(err);
    };
    return tree.arena.queryCapacity();
}

fn bench_write(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const root = sigil.json.parse_value(&tree, document, parse_options, &diag) catch |err| {
        return fail_parse(err);
    };
    var bytes_total: u64 = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        var buffer: [4096]u8 = undefined;
        var sink = std.Io.Writer.Discarding.init(&buffer);
        sigil.json.write_value(&sink.writer, root, stringify_options, &diag) catch {
            return error.BenchFailed;
        };
        bytes_total += sink.fullCount();
    }
    const elapsed_ns = elapsed_ns_since(io, start);
    assert(bytes_total > 0);
    return .{ .bytes_total = bytes_total, .elapsed_ns = elapsed_ns, .arena_bytes = 0 };
}

fn bench_parse_typed(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try parse_typed_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        assert(try parse_typed_once(gpa, document) == arena_bytes);
    }
    return .{
        .bytes_total = @as(u64, iterations) * document.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = arena_bytes,
    };
}

/// Parses `document` into `Document` in a fresh tree and returns the arena capacity it needed.
fn parse_typed_once(gpa: Allocator, document: []const u8) BenchError!u64 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const parsed = sigil.json.parse(Document, &tree, document, parse_options, &diag) catch {
        return error.BenchFailed;
    };
    assert(parsed.records.len > 0);
    return tree.arena.queryCapacity();
}

fn fail_parse(err: sigil.json.ParseValueError) BenchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BenchFailed, // The generated document is valid; any other error is a bug.
    };
}

/// Builds the seeded document `{"records":[...]}` in `gpa` memory, at least
/// `document_bytes_min` long. Same seed, same bytes. Caller frees the result.
fn generate_document(gpa: Allocator, seed: u64) Allocator.Error![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const w = &out.writer;
    w.writeAll("{\"records\":[") catch return error.OutOfMemory;
    var index: u32 = 0;
    for (0..record_count_max) |_| {
        if (out.written().len >= document_bytes_min) break;
        if (index > 0) w.writeByte(',') catch return error.OutOfMemory;
        write_record(w, random, index) catch return error.OutOfMemory;
        index += 1;
    }
    w.writeAll("]}") catch return error.OutOfMemory;
    assert(out.written().len >= document_bytes_min);
    return out.toOwnedSlice();
}

/// A record is at least 100 bytes, so 1 MiB needs far fewer than this.
const record_count_max: u32 = 1 << 16;

fn write_record(w: *std.Io.Writer, random: std.Random, index: u32) std.Io.Writer.Error!void {
    const words = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" };
    const name = words[random.uintLessThan(usize, words.len)];
    const score = @as(f64, @floatFromInt(random.uintLessThan(u32, 100_000))) / 100.0;
    try w.print("{{\"id\":{d},\"name\":\"{s}-{d}\",\"score\":{d:.2},\"active\":{s},", .{
        index,
        name,
        random.uintLessThan(u32, 1000),
        score,
        if (random.boolean()) "true" else "false",
    });
    try w.writeAll("\"tags\":[");
    const tag_count = random.uintLessThan(usize, 4);
    for (0..tag_count) |tag_index| {
        if (tag_index > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{words[random.uintLessThan(usize, words.len)]});
    }
    try w.print("],\"owner\":{{\"x\":{d},\"y\":{d}}}}}", .{
        random.intRangeAtMost(i32, -100_000, 100_000),
        random.intRangeAtMost(i32, -100_000, 100_000),
    });
}

/// Nanoseconds from `start` to now on the awake clock; the clock never runs backwards.
fn elapsed_ns_since(io: std.Io, start: std.Io.Timestamp) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    assert(elapsed >= 0);
    assert(elapsed <= std.math.maxInt(u64));
    return @intCast(elapsed);
}

/// Decimal megabytes (10^6 bytes) per second; 0 when no time elapsed.
fn megabytes_per_second(bytes: u64, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    const bytes_per_ns = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed_ns));
    return bytes_per_ns * 1000.0;
}

fn arena_ratio(arena_bytes: u64, input_bytes: usize) f64 {
    assert(input_bytes > 0);
    return @as(f64, @floatFromInt(arena_bytes)) / @as(f64, @floatFromInt(input_bytes));
}

test "bench: megabytes_per_second is zero-safe and exact" {
    try std.testing.expectEqual(@as(f64, 0), megabytes_per_second(5, 0));
    try std.testing.expectEqual(@as(f64, 1000), megabytes_per_second(1, 1));
    try std.testing.expectEqual(@as(f64, 500), megabytes_per_second(1, 2));
    try std.testing.expectEqual(@as(f64, 2), arena_ratio(20, 10));
}

test "bench: the generated document is deterministic, valid, and long enough" {
    const first = try generate_document(std.testing.allocator, document_seed);
    defer std.testing.allocator.free(first);

    const second = try generate_document(std.testing.allocator, document_seed);
    defer std.testing.allocator.free(second);

    try std.testing.expect(first.len >= document_bytes_min);
    try std.testing.expectEqualSlices(u8, first, second);

    const other = try generate_document(std.testing.allocator, document_seed + 1);
    defer std.testing.allocator.free(other);

    try std.testing.expect(!std.mem.eql(u8, first, other));
    try std.testing.expect(std.json.validate(std.testing.allocator, first) catch false);
}

test "bench: each benchmark runs once over the generated document" {
    const document = try generate_document(std.testing.allocator, document_seed);
    defer std.testing.allocator.free(document);

    for (benches) |bench| {
        const result = try bench.run(std.testing.allocator, std.testing.io, document);
        try std.testing.expect(result.bytes_total > 0);
    }
}

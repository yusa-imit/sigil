//! sigil benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  MB/s  arena bytes per input byte` so the numbers can be pasted
//! into docs/plans/. One seeded JSON document of about 1 MiB is generated once and shared by
//! every benchmark; no corpus is vendored. Each benchmark runs one untimed warm-up pass, then
//! the timed loop (parse benchmarks include tree init and teardown); document generation is
//! never timed. Arena bytes are the arena capacity of one iteration, slack included.
//! Allocation: `gpa` is `init.gpa`; every benchmark frees what it takes.
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
/// the time that took, the arena capacity one iteration needed (0 when it has no arena), and,
/// for the `path` benchmarks, how many nodes they resolved or selected across all iterations
/// (0 for the format benchmarks, which print no ns per match).
const Result = struct {
    bytes_total: u64,
    elapsed_ns: u64,
    arena_bytes: u64,
    matches_total: u64 = 0,
};

const BenchError = error{ OutOfMemory, BenchFailed };

/// Pointer lookups per iteration of `path.pointer.resolve`; each parses its own pointer text.
const pointer_lookups: u32 = 1 << 16;

/// Capacity of the `select` output buffer; the generated document has far fewer nodes.
const select_out_max: u32 = 1 << 20;

const query_descendants = "$..*";

const query_filter = "$.records[?@.active == true && @.score >= 50.0].id";

/// Which generated document a benchmark reads: the JSON one or the TOML one.
const Format = enum { json, toml };

/// The TOML document is at least this long (PRD section 5 targets a ~100 KB parse).
const toml_bytes_min: u32 = 100_000;

/// Seed of the TOML document generator.
const toml_seed: u64 = 0x70_31;

const toml_parse_options: sigil.toml.ParseOptions = .{
    .depth_max = 64,
    .bytes_max = 64 << 20,
};

const toml_stringify_options: sigil.toml.StringifyOptions = .{ .depth_max = 64 };

const Bench = struct {
    name: []const u8,
    format: Format,
    run: *const fn (Allocator, std.Io, []const u8) BenchError!Result,
};

const benches = [_]Bench{
    .{ .name = "json.dom.parse", .format = .json, .run = bench_dom_parse },
    .{ .name = "json.write.minified", .format = .json, .run = bench_write },
    .{ .name = "json.parse(T)", .format = .json, .run = bench_parse_typed },
    .{ .name = "path.pointer.resolve", .format = .json, .run = bench_pointer },
    .{ .name = "path.jsonpath $..*", .format = .json, .run = bench_descendants },
    .{ .name = "path.jsonpath filter", .format = .json, .run = bench_filter },
    .{ .name = "toml.parse_value", .format = .toml, .run = bench_toml_parse },
    .{ .name = "toml.parse(T)", .format = .toml, .run = bench_toml_parse_typed },
    .{ .name = "toml.write_value", .format = .toml, .run = bench_toml_write },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1); // argv[0] (the program name) always exists.
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    const document = try generate_document(init.gpa, document_seed);
    defer init.gpa.free(document);

    assert(document.len >= document_bytes_min);

    const toml_document = try generate_toml_document(init.gpa, toml_seed);
    defer init.gpa.free(toml_document);

    assert(toml_document.len >= toml_bytes_min);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("json document: {d} bytes (seed {d}), {d} iterations each\n", .{
        document.len, document_seed, iterations,
    });
    try out.print("toml document: {d} bytes (seed {d})\n", .{ toml_document.len, toml_seed });
    for (benches) |bench| {
        if (filter) |needle| {
            if (std.mem.find(u8, bench.name, needle) == null) continue;
        }
        const input = switch (bench.format) {
            .json => document,
            .toml => toml_document,
        };
        const result = try bench.run(init.gpa, init.io, input);
        try out.print("{s:<24} {d:>9.1} MB/s {d:>7.2} arena bytes/input byte", .{
            bench.name,
            megabytes_per_second(result.bytes_total, result.elapsed_ns),
            arena_ratio(result.arena_bytes, input.len),
        });
        if (bench.format == .toml) {
            try out.print(" {d:>8.3} ms/iter", .{milliseconds_per_iteration(result.elapsed_ns)});
        }
        if (result.matches_total > 0) {
            try out.print(" {d:>9.1} ns/match", .{
                nanoseconds_per_match(result.matches_total, result.elapsed_ns),
            });
        }
        try out.writeByte('\n');
    }
    try out.flush();
    assert(out.end == 0); // Postcondition: output is fully drained before returning.
}

fn bench_dom_parse(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try dom_parse_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try dom_parse_once(gpa, document);
        assert(got == arena_bytes);
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
    const output_bytes = try write_once(root, &diag); // Warm-up: caches.
    var bytes_total: u64 = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try write_once(root, &diag);
        assert(got == output_bytes);
        bytes_total += got;
    }
    const elapsed_ns = elapsed_ns_since(io, start);
    assert(bytes_total > 0);
    return .{ .bytes_total = bytes_total, .elapsed_ns = elapsed_ns, .arena_bytes = 0 };
}

/// Writes `root` minified into a discarding sink and returns the output length.
fn write_once(root: sigil.core.Value, diag: *sigil.core.Diagnostics) BenchError!u64 {
    var buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buffer);
    sigil.json.write_value(&sink.writer, root, stringify_options, diag) catch |err| {
        std.log.err("bench: write failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
    return sink.fullCount();
}

fn bench_parse_typed(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try parse_typed_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try parse_typed_once(gpa, document);
        assert(got == arena_bytes);
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
    const parsed = sigil.json.parse(Document, &tree, document, parse_options, &diag) catch |err| {
        std.log.err("bench: parse(T) failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
    assert(parsed.records.len > 0);
    return tree.arena.queryCapacity();
}

/// Parses `document` into `tree` and returns the root, which borrows from the tree.
fn parse_root(tree: *sigil.core.ValueTree, document: []const u8) BenchError!sigil.core.Value {
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    return sigil.json.parse_value(tree, document, parse_options, &diag) catch |err| {
        return fail_parse(err);
    };
}

fn bench_pointer(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const root = try parse_root(&tree, document);
    const records = sigil.path.pointer.resolve(&root, try pointer_parse("/records")) orelse {
        return error.BenchFailed;
    };
    const record_count: u32 = switch (records.*) {
        .array => |items| @intCast(items.len),
        else => return error.BenchFailed,
    };
    assert(record_count > 0);

    const hits = try pointer_pass(&root, record_count); // Warm-up: caches.
    assert(hits == pointer_lookups); // Every record has `owner.x`.
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try pointer_pass(&root, record_count);
        assert(got == hits);
    }
    return .{
        .bytes_total = 0,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = 0,
        .matches_total = @as(u64, iterations) * hits,
    };
}

/// Parses and resolves `/records/<i>/owner/x` for `pointer_lookups` spread-out indexes and
/// returns how many resolved.
fn pointer_pass(root: *const sigil.core.Value, record_count: u32) BenchError!u32 {
    var hits: u32 = 0;
    var text_buffer: [64]u8 = undefined;
    for (0..pointer_lookups) |lookup| {
        const index: u32 = @intCast((lookup * 7919) % record_count);
        const text = std.fmt.bufPrint(&text_buffer, "/records/{d}/owner/x", .{index}) catch {
            return error.BenchFailed;
        };
        const pointer = try pointer_parse(text);
        if (sigil.path.pointer.resolve(root, pointer) != null) hits += 1;
    }
    return hits;
}

fn pointer_parse(text: []const u8) BenchError!sigil.path.pointer.Pointer {
    const Segment = sigil.path.pointer.Segment;
    // The returned `Pointer` borrows its segments, so the buffer must outlive this call; it is
    // static because the harness is single-threaded and a pointer is used before the next parse.
    const state = struct {
        var buffer: [sigil.path.pointer.segments_max]Segment = undefined;
    };
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    return sigil.path.pointer.parse(text, &state.buffer, &diag) catch |err| {
        std.log.err("bench: pointer failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
}

fn bench_descendants(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    return bench_select(gpa, io, document, query_descendants);
}

fn bench_filter(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    return bench_select(gpa, io, document, query_filter);
}

/// Compiles `query` once, then selects it from the parsed document `iterations` times.
fn bench_select(
    gpa: Allocator,
    io: std.Io,
    document: []const u8,
    query: []const u8,
) BenchError!Result {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const root = try parse_root(&tree, document);

    var program: sigil.path.jsonpath.Program = undefined;
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    sigil.path.jsonpath.compile(&program, query, &diag) catch |err| {
        std.log.err("bench: compile failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };

    const out = try gpa.alloc(*const sigil.core.Value, select_out_max);
    defer gpa.free(out);

    const matches = try select_once(&program, &root, out); // Warm-up: caches.
    assert(matches > 0);
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        const got = try select_once(&program, &root, out);
        assert(got == matches);
    }
    return .{
        .bytes_total = @as(u64, iterations) * document.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = 0,
        .matches_total = @as(u64, iterations) * matches,
    };
}

fn select_once(
    program: *const sigil.path.jsonpath.Program,
    root: *const sigil.core.Value,
    out: []*const sigil.core.Value,
) BenchError!u64 {
    const selected = sigil.path.jsonpath.select(program, root, out) catch |err| {
        std.log.err("bench: select failed: {s}", .{@errorName(err)});
        return error.BenchFailed;
    };
    return selected.len;
}

/// The TOML benchmarks repeat this many times: one pass over ~100 KB takes about a millisecond.
const toml_iterations: u32 = 256;

fn bench_toml_parse(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try toml_parse_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..toml_iterations) |_| {
        const got = try toml_parse_once(gpa, document);
        assert(got == arena_bytes);
    }
    return .{
        .bytes_total = @as(u64, toml_iterations) * document.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = arena_bytes,
    };
}

/// Parses `document` into a fresh tree and returns the arena capacity it needed.
fn toml_parse_once(gpa: Allocator, document: []const u8) BenchError!u64 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    _ = try toml_parse_root(gpa, &tree, document);
    return tree.arena.queryCapacity();
}

/// Parses `document` into `tree` and returns the root table, which borrows from the tree.
fn toml_parse_root(
    gpa: Allocator,
    tree: *sigil.core.ValueTree,
    document: []const u8,
) BenchError!sigil.core.Value {
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    return sigil.toml.parse_value(gpa, tree, document, toml_parse_options, &diag) catch |err| {
        std.log.err("bench: toml parse failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BenchFailed, // The generated document is valid; any other is a bug.
        };
    };
}

fn bench_toml_parse_typed(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    const arena_bytes = try toml_parse_typed_once(gpa, document); // Warm-up: pages and caches.
    const start = std.Io.Clock.awake.now(io);
    for (0..toml_iterations) |_| {
        const got = try toml_parse_typed_once(gpa, document);
        assert(got == arena_bytes);
    }
    return .{
        .bytes_total = @as(u64, toml_iterations) * document.len,
        .elapsed_ns = elapsed_ns_since(io, start),
        .arena_bytes = arena_bytes,
    };
}

/// Parses `document` into `Document` in a fresh tree and returns the arena capacity it needed.
fn toml_parse_typed_once(gpa: Allocator, document: []const u8) BenchError!u64 {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    const parsed = sigil.toml.parse(
        Document,
        gpa,
        &tree,
        document,
        toml_parse_options,
        &diag,
    ) catch |err| {
        std.log.err("bench: toml parse(T) failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
    assert(parsed.records.len > 0);
    return tree.arena.queryCapacity();
}

fn bench_toml_write(gpa: Allocator, io: std.Io, document: []const u8) BenchError!Result {
    var tree: sigil.core.ValueTree = undefined;
    tree.init(gpa);
    defer tree.deinit();

    const root = try toml_parse_root(gpa, &tree, document);
    const output_bytes = try toml_write_once(root); // Warm-up: caches.
    var bytes_total: u64 = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..toml_iterations) |_| {
        const got = try toml_write_once(root);
        assert(got == output_bytes);
        bytes_total += got;
    }
    const elapsed_ns = elapsed_ns_since(io, start);
    assert(bytes_total > 0);
    return .{ .bytes_total = bytes_total, .elapsed_ns = elapsed_ns, .arena_bytes = 0 };
}

/// Writes `root` as TOML into a discarding sink and returns the output length.
fn toml_write_once(root: sigil.core.Value) BenchError!u64 {
    var buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buffer);
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    sigil.toml.write_value(&sink.writer, root, toml_stringify_options, &diag) catch |err| {
        std.log.err("bench: toml write failed: {s}: {s}", .{ @errorName(err), diag.message() });
        return error.BenchFailed;
    };
    return sink.fullCount();
}

fn fail_parse(err: sigil.json.ParseValueError) BenchError {
    std.log.err("bench: parse failed: {s}", .{@errorName(err)});
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
    // Every draw is a named local, in a fixed order, so the byte stream never depends on the
    // evaluation order of call arguments.
    const name = words[random.uintLessThan(usize, words.len)];
    const suffix = random.uintLessThan(u32, 1000);
    const score = @as(f64, @floatFromInt(random.uintLessThan(u32, 100_000))) / 100.0;
    const active = random.boolean();
    try w.print("{{\"id\":{d},\"name\":\"{s}-{d}\",\"score\":{d:.2},\"active\":{s},", .{
        index,
        name,
        suffix,
        score,
        if (active) "true" else "false",
    });
    try w.writeAll("\"tags\":[");
    const tag_count = random.uintLessThan(usize, 4);
    for (0..tag_count) |tag_index| {
        const tag = words[random.uintLessThan(usize, words.len)];
        if (tag_index > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{tag});
    }
    const x = random.intRangeAtMost(i32, -100_000, 100_000);
    const y = random.intRangeAtMost(i32, -100_000, 100_000);
    try w.print("],\"owner\":{{\"x\":{d},\"y\":{d}}}}}", .{ x, y });
}

/// Builds the seeded TOML document, one `[[records]]` table per record, in `gpa` memory, at
/// least `toml_bytes_min` long. Same seed, same bytes. Caller frees the result.
fn generate_toml_document(gpa: Allocator, seed: u64) Allocator.Error![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const w = &out.writer;
    var index: u32 = 0;
    for (0..record_count_max) |_| {
        if (out.written().len >= toml_bytes_min) break;
        write_toml_record(w, random, index) catch return error.OutOfMemory;
        index += 1;
    }
    assert(out.written().len >= toml_bytes_min);
    return out.toOwnedSlice();
}

fn write_toml_record(w: *std.Io.Writer, random: std.Random, index: u32) std.Io.Writer.Error!void {
    const words = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" };
    // Every draw is a named local, in a fixed order, as in `write_record`.
    const name = words[random.uintLessThan(usize, words.len)];
    const suffix = random.uintLessThan(u32, 1000);
    const score = @as(f64, @floatFromInt(random.uintLessThan(u32, 100_000))) / 100.0;
    const active = random.boolean();
    try w.print("[[records]]\nid = {d}\nname = \"{s}-{d}\"\nscore = {d:.2}\nactive = {s}\n", .{
        index,
        name,
        suffix,
        score,
        if (active) "true" else "false",
    });
    try w.writeAll("tags = [");
    const tag_count = random.uintLessThan(usize, 4);
    for (0..tag_count) |tag_index| {
        const tag = words[random.uintLessThan(usize, words.len)];
        if (tag_index > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{tag});
    }
    const x = random.intRangeAtMost(i32, -100_000, 100_000);
    const y = random.intRangeAtMost(i32, -100_000, 100_000);
    try w.print("]\nowner = {{ x = {d}, y = {d} }}\n\n", .{ x, y });
}

/// Milliseconds one iteration of a TOML benchmark took on average.
fn milliseconds_per_iteration(elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(toml_iterations)) / 1e6;
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

/// Nanoseconds per node; `matches` must be positive.
fn nanoseconds_per_match(matches: u64, elapsed_ns: u64) f64 {
    assert(matches > 0);
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(matches));
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
    try std.testing.expectEqual(@as(f64, 4), nanoseconds_per_match(5, 20));
    try std.testing.expectEqual(@as(f64, 0.5), nanoseconds_per_match(2, 1));
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

test "bench: each benchmark measures bytes and time over the generated document" {
    const document = try generate_document(std.testing.allocator, document_seed);
    defer std.testing.allocator.free(document);

    const toml_document = try generate_toml_document(std.testing.allocator, toml_seed);
    defer std.testing.allocator.free(toml_document);

    for (benches) |bench| {
        const input = switch (bench.format) {
            .json => document,
            .toml => toml_document,
        };
        const result = try bench.run(std.testing.allocator, std.testing.io, input);
        const is_path = std.mem.startsWith(u8, bench.name, "path.");
        const is_pointer = std.mem.eql(u8, bench.name, "path.pointer.resolve");
        try std.testing.expectEqual(!is_pointer, result.bytes_total > 0);
        try std.testing.expect(result.elapsed_ns > 0);
        const is_write = std.mem.eql(u8, bench.name, "json.write.minified") or
            std.mem.eql(u8, bench.name, "toml.write_value");
        try std.testing.expectEqual(!is_write and !is_path, result.arena_bytes > 0);
        try std.testing.expectEqual(is_path, result.matches_total > 0);
    }
}

test "bench: the TOML document is deterministic, valid, and long enough" {
    const first = try generate_toml_document(std.testing.allocator, toml_seed);
    defer std.testing.allocator.free(first);

    const second = try generate_toml_document(std.testing.allocator, toml_seed);
    defer std.testing.allocator.free(second);

    try std.testing.expect(first.len >= toml_bytes_min);
    try std.testing.expectEqualSlices(u8, first, second);

    const other = try generate_toml_document(std.testing.allocator, toml_seed + 1);
    defer std.testing.allocator.free(other);

    try std.testing.expect(!std.mem.eql(u8, first, other));

    var tree: sigil.core.ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try toml_parse_root(std.testing.allocator, &tree, first);
    const records = root.map.get("records") orelse return error.TestUnexpectedResult;
    try std.testing.expect(records.array.len > 1);
    try std.testing.expectEqual(
        @as(f64, 0.5),
        milliseconds_per_iteration(@as(u64, toml_iterations) * 500_000),
    );
}

test "bench: the pointer and query benchmarks match what the document holds" {
    const document = try generate_document(std.testing.allocator, document_seed);
    defer std.testing.allocator.free(document);

    var tree: sigil.core.ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try parse_root(&tree, document);
    const out = try std.testing.allocator.alloc(*const sigil.core.Value, select_out_max);
    defer std.testing.allocator.free(out);

    var program: sigil.path.jsonpath.Program = undefined;
    var diag = sigil.core.Diagnostics.init(0, 0, "", null);
    try sigil.path.jsonpath.compile(&program, query_filter, &diag);
    const filtered = try select_once(&program, &root, out);
    try sigil.path.jsonpath.compile(&program, "$.records[*].id", &diag);
    const all = try select_once(&program, &root, out);

    // About a quarter of the records are active with a score of at least 50; none fail to have
    // an `id`, so the filter must select some but not all of them.
    try std.testing.expect(filtered > 0);
    try std.testing.expect(filtered < all);
    try std.testing.expectEqual(
        @as(u64, pointer_lookups),
        try pointer_pass(&root, @intCast(all)),
    );
}

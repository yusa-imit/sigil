//! sigil benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  ops/s  ns/op` so results can be pasted into docs/plans/.
const std = @import("std");
const assert = std.debug.assert;

const Bench = struct {
    name: []const u8,
    run: *const fn (std.mem.Allocator) error{OutOfMemory}!u64,
};

const benches = [_]Bench{
    .{ .name = "noop", .run = noop },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1); // argv[0] (the program name) always exists.
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    for (benches) |bench| {
        if (filter) |needle| {
            if (std.mem.find(u8, bench.name, needle) == null) continue;
        }
        const start = std.Io.Clock.awake.now(init.io);
        const ops = try bench.run(init.gpa);
        const elapsed_ns = elapsed_ns_since(init.io, start);
        try out.print("{s:<32} {d:>12} ops/s {d:>10} ns/op\n", .{
            bench.name,
            ops_per_second(ops, elapsed_ns),
            ns_per_op(ops, elapsed_ns),
        });
    }
    try out.flush();
    assert(out.end == 0); // Postcondition: output is fully drained before returning.
}

fn noop(gpa: std.mem.Allocator) error{OutOfMemory}!u64 {
    _ = gpa; // The placeholder benchmark allocates nothing.
    return 1;
}

/// Nanoseconds from `start` to now on the awake clock; the clock never runs backwards.
fn elapsed_ns_since(io: std.Io, start: std.Io.Timestamp) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    assert(elapsed >= 0);
    assert(elapsed <= std.math.maxInt(u64));
    return @intCast(elapsed);
}

fn ns_per_op(ops: u64, elapsed_ns: u64) u64 {
    assert(elapsed_ns <= std.math.maxInt(u64));
    if (ops == 0) return 0;
    return @divFloor(elapsed_ns, ops);
}

fn ops_per_second(ops: u64, elapsed_ns: u64) u64 {
    if (elapsed_ns == 0) return 0;
    const scaled: u128 = @as(u128, ops) * std.time.ns_per_s;
    const rate = @divFloor(scaled, elapsed_ns);
    return @intCast(@min(rate, std.math.maxInt(u64)));
}

test "bench: rates are zero-safe and floor" {
    try std.testing.expectEqual(@as(u64, 0), ns_per_op(0, 100));
    try std.testing.expectEqual(@as(u64, 3), ns_per_op(3, 10));
    try std.testing.expectEqual(@as(u64, 0), ops_per_second(5, 0));
    try std.testing.expectEqual(@as(u64, 500_000_000), ops_per_second(1, 2));
    const saturated = ops_per_second(std.math.maxInt(u64), 1);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), saturated);
}

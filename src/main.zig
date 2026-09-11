//! sigil CLI — `sigil version` / `sigil --help`. Only real entry point today; every other
//! module is a Phase 1+ stub.
const std = @import("std");
const sigil = @import("sigil");
const assert = std.debug.assert;

const help_text =
    \\sigil — Marks that carry meaning — serialization and configuration formats for Zig
    \\
    \\usage: sigil <command>
    \\  version    print library version
    \\  --help     this text
    \\
;

/// Minimal CLI: `sigil version` / `sigil --help`.
/// Diagnostic subcommands are added as modules land (see docs/PRD.md).
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1); // Positive space: argv[0] (the program name) always exists,
    // an OS/libc guarantee, not user-suppliable data — unlike an upper bound on argv
    // count, which depends entirely on the caller's shell and must never be asserted.

    var stdout_buffer: [512]u8 = undefined;
    // Buffer must fit the longest fixed output; the version line is short and bounded.
    comptime assert(stdout_buffer.len >= help_text.len);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "--help";
    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("sigil {f}\n", .{sigil.version});
    } else {
        try out.print(help_text, .{});
    }
    try out.flush();
    assert(out.end == 0); // Postcondition: output is fully drained before returning.
}

test "cli: version is exposed" {
    try std.testing.expectEqual(@as(u32, 0), sigil.version.major);
}

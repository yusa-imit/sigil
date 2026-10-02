//! Compile-error fixture: an array above `array_bytes_max` would live on the machine stack of
//! every nested frame, so it is not a supported parse target. `build.zig` expects the compiler
//! to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Big = [65537]u8;

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Big, tree, .null, diag) catch {};
}

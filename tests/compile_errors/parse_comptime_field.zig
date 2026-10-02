//! Compile-error fixture: a struct with a `comptime` field (it has no value to fill) is not a
//! supported parse target. `build.zig` expects the compiler to reject this file with the
//! message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Fixed = struct { comptime version: u8 = 1, name: []const u8 };

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Fixed, tree, .null, diag) catch {};
}

//! Compile-error fixture: a single-item pointer is not a supported parse target (only `[]const u8`
//! and, later, `[]const T` slices are). `build.zig` expects the compiler to reject this file with
//! the message listed in `compile_error_cases`.

const sigil = @import("sigil");

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(*const u8, tree, .null, diag) catch {};
}

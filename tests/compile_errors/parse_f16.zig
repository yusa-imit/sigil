//! Compile-error fixture: floats other than `f32` and `f64` are not supported parse targets.
//! `build.zig` expects the compiler to reject this file with the message listed in
//! `compile_error_cases`.

const sigil = @import("sigil");

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(f16, tree, .null, diag) catch {};
}

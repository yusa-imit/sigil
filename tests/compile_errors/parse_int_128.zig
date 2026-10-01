//! Compile-error fixture: integers wider than 64 bits are not a supported parse target (`Value`
//! holds `i64` and `u64`). `build.zig` expects the compiler to reject this file with the message
//! listed in `compile_error_cases`.

const sigil = @import("sigil");

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(i128, tree, .null, diag) catch {};
}

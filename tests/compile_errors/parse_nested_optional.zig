//! Compile-error fixture: `??T` is not a supported parse target (`.null` could mean either
//! level). `build.zig` expects the compiler to reject this file with the message listed in
//! `compile_error_cases`.

const sigil = @import("sigil");

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(??u8, tree, .null, diag) catch {};
}

//! Compile-error fixture: a sentinel-terminated slice (the sentinel cannot borrow from a
//! `Value`) is not a supported parse target. `build.zig` expects the compiler to reject this
//! file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Text = [:0]const u8;

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Text, tree, .null, diag) catch {};
}

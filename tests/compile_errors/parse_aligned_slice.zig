//! Compile-error fixture: an over-aligned slice cannot be served by the tree arena's naturally
//! aligned allocation, so it is not a supported parse target. `build.zig` expects the compiler
//! to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Aligned = []align(16) const u32;

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Aligned, tree, .null, diag) catch {};
}

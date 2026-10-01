//! Compile-error fixture: `[]u8` is not a supported parse target (a mutable byte slice cannot
//! borrow from a `Value`; `[]const u8` is the string type). `build.zig` expects the compiler to
//! reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse([]u8, tree, .null, diag) catch {};
}

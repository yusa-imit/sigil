//! Compile-error fixture: a packed struct (its layout is bits, not fields) is not a supported
//! parse target. `build.zig` expects the compiler to reject this file with the message listed
//! in `compile_error_cases`.

const sigil = @import("sigil");

const Flags = packed struct { a: u4, b: u4 };

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Flags, tree, .null, diag) catch {};
}

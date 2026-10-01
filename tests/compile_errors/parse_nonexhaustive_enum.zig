//! Compile-error fixture: a non-exhaustive enum is not a supported parse target (an unnamed
//! integer value has no wire name). `build.zig` expects the compiler to reject this file with
//! the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Open = enum(u8) { a, b, _ };

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Open, tree, .null, diag) catch {};
}

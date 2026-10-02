//! Compile-error fixture: a tuple (it has no field names to look up) is not a supported parse
//! target. `build.zig` expects the compiler to reject this file with the message listed in
//! `compile_error_cases`.

const sigil = @import("sigil");

const Pair = struct { u8, u8 };

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Pair, tree, .null, diag) catch {};
}

//! Compile-error fixture: an untagged union is not a supported parse target. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = union {
    a: u8,
};

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Bad, tree, .null, diag) catch {};
}

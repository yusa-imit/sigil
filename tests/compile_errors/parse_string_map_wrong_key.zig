//! Compile-error fixture: only `std.array_hash_map.String(V)` is a map parse target; an
//! `Auto` map is not. `build.zig` expects the compiler to reject this file with the message
//! listed in `compile_error_cases`.

const std = @import("std");
const sigil = @import("sigil");

const Bad = std.array_hash_map.Auto(u32, u8);

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Bad, tree, .null, diag) catch {};
}

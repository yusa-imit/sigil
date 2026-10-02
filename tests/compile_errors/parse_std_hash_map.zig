//! Compile-error fixture: a std hash map is a struct of raw pointers, not a data shape; it is
//! not a supported parse target. `build.zig` expects the compiler to reject this file with the
//! message listed in `compile_error_cases`.

const std = @import("std");
const sigil = @import("sigil");

const Map = std.StringHashMapUnmanaged(u32);

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Map, tree, .null, diag) catch {};
}

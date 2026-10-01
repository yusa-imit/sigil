//! Compile-error fixture: a struct is not a parse target until plan 003 item 6 lands. Delete
//! this fixture in that item. `build.zig` expects the compiler to reject this file with the
//! message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Point = struct { x: u8, y: u8 };

export fn probe(tree: *sigil.core.ValueTree, diag: *sigil.core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Point, tree, .null, diag) catch {};
}

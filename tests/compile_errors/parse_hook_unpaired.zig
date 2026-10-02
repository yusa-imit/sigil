//! Compile-error fixture: a type declares `sigilParse` without `sigilStringify`. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");
const core = sigil.core;
const Context = sigil.reflect.Context;

const Bad = struct {
    ms: u64,
    pub fn sigilParse(context: *Context, value: core.Value) sigil.reflect.ParseError!Bad {
        _ = context;
        _ = value;
        return .{ .ms = 0 };
    }
};

export fn probe(tree: *core.ValueTree, diag: *core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Bad, tree, .null, diag) catch {};
}

//! Compile-error fixture: a type declares `sigilStringify` without `sigilParse`. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");
const core = sigil.core;
const Context = sigil.reflect.Context;
const StringifyError = sigil.reflect.StringifyError;

const Bad = struct {
    ms: u64,
    pub fn sigilStringify(self: *const Bad, context: *Context) StringifyError!core.Value {
        _ = self;
        _ = context;
        return .null;
    }
};

export fn probe(tree: *core.ValueTree, diag: *core.Diagnostics) void {
    _ = sigil.reflect.parse.parse(Bad, tree, .null, diag) catch {};
}

//! Compile-error fixture: `sigil_options` on a type that also declares a hook. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .rename_all = .kebab_case };
    pub fn sigilParse() void {}
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

//! Compile-error fixture: `rename_all` over a field name that is not snake_case. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    maxSize: u8,
    pub const sigil_options = .{ .rename_all = .kebab_case };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

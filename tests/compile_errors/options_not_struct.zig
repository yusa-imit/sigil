//! Compile-error fixture: a `sigil_options` that is not an anonymous struct. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = true;
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

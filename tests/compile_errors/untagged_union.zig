//! Compile-error fixture: reflecting an untagged union. `build.zig` expects the compiler to
//! reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = union {
    a: u8,
    b: u16,
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

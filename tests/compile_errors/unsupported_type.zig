//! Compile-error fixture: resolving options for a type that has no fields to rename. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

comptime {
    _ = sigil.reflect.options.resolve(u32);
}

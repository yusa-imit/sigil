//! Compile-error fixture: a `rename` to the empty string. `build.zig` expects the compiler to
//! reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .rename = .{ .name = "" } };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

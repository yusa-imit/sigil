//! Compile-error fixture: a `rename_all` that is a string instead of an enum literal.
//! `build.zig` expects the compiler to reject this file with the message listed in
//! `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .rename_all = "kebab-case" };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

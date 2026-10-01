//! Compile-error fixture: an explicit `rename` that collides with a `rename_all` result.
//! `build.zig` expects the compiler to reject this file with the message listed in
//! `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    max_size: u8,
    other: u8,
    pub const sigil_options = .{
        .rename = .{ .other = "max-size" },
        .rename_all = .kebab_case,
    };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

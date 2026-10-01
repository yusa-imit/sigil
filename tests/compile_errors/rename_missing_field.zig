//! Compile-error fixture: `rename` of a field the type does not have. `build.zig` expects the
//! compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .rename = .{ .nmae = "n" } };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

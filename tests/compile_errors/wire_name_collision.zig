//! Compile-error fixture: two fields landing on one wire name through `rename`. `build.zig`
//! expects the compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    first: u8,
    second: u8,
    pub const sigil_options = .{ .rename = .{ .first = "x", .second = "x" } };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

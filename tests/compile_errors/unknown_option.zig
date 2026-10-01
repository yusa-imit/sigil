//! Compile-error fixture: an unknown `sigil_options` key. `build.zig` expects the compiler to
//! reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .renmae = .{} };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

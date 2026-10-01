//! Compile-error fixture: `deny_unknown_fields` on an enum. `build.zig` expects the compiler to
//! reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = enum {
    one,
    two,
    pub const sigil_options = .{ .deny_unknown_fields = false };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

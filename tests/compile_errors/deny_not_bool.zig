//! Compile-error fixture: `deny_unknown_fields` given a non-bool. `build.zig` expects the
//! compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: u8,
    pub const sigil_options = .{ .deny_unknown_fields = 1 };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

//! Compile-error fixture: `bytes` on an enum. `build.zig` expects the
//! compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = enum {
    first,
    pub const sigil_options = .{ .bytes = .{"first"} };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

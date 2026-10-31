//! Compile-error fixture: `bytes` with a non-string entry. `build.zig` expects the
//! compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    name: []const u8,
    pub const sigil_options = .{ .bytes = .{3} };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

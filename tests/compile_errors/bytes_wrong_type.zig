//! Compile-error fixture: `bytes` lists a field that is not `[]const u8`. `build.zig` expects the
//! compiler to reject this file with the message listed in `compile_error_cases`.

const sigil = @import("sigil");

const Bad = struct {
    count: u32,
    pub const sigil_options = .{ .bytes = .{"count"} };
};

comptime {
    _ = sigil.reflect.options.resolve(Bad);
}

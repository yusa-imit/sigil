//! sigil.core — Value union, arena-owned ValueTree, Number parsing/formatting, Timestamp,
//! Diagnostics (line:col), UTF-8/escape utils.
//!
//! Status: `value`, `tree`, `diagnostics`, `number` (plan 002) and `unicode`, `unicode_escape`
//! (plan 003) have landed; the remaining files are added as PRD phases land (see docs/PRD.md
//! and docs/plans/).

const std = @import("std");
const assert = std.debug.assert;

pub const value = @import("core/value.zig");
pub const Value = value.Value;
pub const Timestamp = value.Timestamp;
pub const Map = value.Map;
pub const tree = @import("core/tree.zig");
pub const ValueTree = tree.ValueTree;
pub const diagnostics = @import("core/diagnostics.zig");
pub const Diagnostics = diagnostics.Diagnostics;
pub const DiagnosticsType = diagnostics.DiagnosticsType;
pub const number = @import("core/number.zig");
pub const unicode = @import("core/unicode.zig");
pub const unicode_escape = @import("core/unicode_escape.zig");

/// Module-level error set: everything the core primitives can return (number conversion,
/// UTF-8 and escape handling, `Value` comparison depth, tree building). Extend as files land;
/// keep names descriptive (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = number.Error || unicode.Error || unicode_escape.EscapeError ||
    error{ TooDeep, OutOfMemory };

test "core: module compiles" {
    std.testing.refAllDecls(@This());
}

/// Whether the error set `E` declares an error called `name`.
fn error_set_has(comptime E: type, comptime name: []const u8) bool {
    const names = @typeInfo(E).error_set.?;
    inline for (names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "core: Error is the union of the module error sets, with no placeholder" {
    comptime assert(!error_set_has(Error, "NotImplemented"));
    comptime assert(error_set_has(Error, "IntegerAboveMax"));
    comptime assert(error_set_has(Error, "FloatOutOfRange"));
    comptime assert(error_set_has(Error, "InputTooLarge"));
    comptime assert(error_set_has(Error, "InvalidHex"));
    comptime assert(error_set_has(Error, "LoneSurrogate"));
    comptime assert(error_set_has(Error, "InvalidCodepoint"));
    comptime assert(error_set_has(Error, "TooDeep"));
    comptime assert(error_set_has(Error, "OutOfMemory"));
}

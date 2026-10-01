//! sigil.reflect — comptime struct ↔ Value mapping: parse(T), stringify(T), field options
//! (rename, defaults, deny_unknown), custom hooks, Schema(T) validation.
//!
//! Files (see docs/PRD.md and docs/adr/0002-reflect-contract.md):
//!   - `reflect/options.zig` — landed: `sigil_options` resolved at comptime into a field table
//!   - `reflect/context.zig` — landed: error sets, key `Path`, `Context` (`fail`, `parse_child`)
//!   - `reflect/parse.zig` — scalars landed; structs, sequences, unions and hooks planned
//!   - `reflect/stringify.zig`, `reflect/schema.zig` — planned
//!
//! Status: partial. Public declarations are added as plan 003 items land.

const std = @import("std");

pub const options = @import("reflect/options.zig");
pub const context = @import("reflect/context.zig");
pub const parse = @import("reflect/parse.zig");

pub const ParseError = context.ParseError;
pub const StringifyError = context.StringifyError;
pub const Context = context.Context;
pub const Path = context.Path;
pub const Segment = context.Segment;

/// Module-level error set: everything `parse` and `stringify` can return.
pub const Error = ParseError || StringifyError;

test "reflect: module compiles" {
    std.testing.refAllDecls(@This());
}

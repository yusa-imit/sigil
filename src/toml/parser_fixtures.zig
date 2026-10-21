//! Shared helpers for the `toml/parser` tests: parse with a tree invariant check, assert an
//! error with its line:col, and read fields of a parsed tree. Only test files import this.

const std = @import("std");
const core = @import("../core.zig");
const parser = @import("parser.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Diagnostics = core.Diagnostics;
const ParseOptions = parser.ParseOptions;
const ParseValueError = parser.ParseValueError;
const Value = core.Value;
const ValueTree = core.ValueTree;

pub const options_default: ParseOptions = .{ .depth_max = 128, .bytes_max = 1 << 20 };

pub fn parse_with(
    tree: *ValueTree,
    input: []const u8,
    options: ParseOptions,
    diag: *Diagnostics,
) ParseValueError!Value {
    const value = try parser.parse_value(std.testing.allocator, tree, input, options, diag);
    check_maps(value);
    return value;
}

/// Parses `input` with the default options; the caller owns `tree`.
pub fn parse_ok(tree: *ValueTree, input: []const u8) !Value {
    var diag = Diagnostics.init(0, 0, "untouched", null);
    const value = try parse_with(tree, input, options_default, &diag);
    try expectEqualStrings("untouched", diag.message());
    return value;
}

pub fn expect_failure_with(
    input: []const u8,
    options: ParseOptions,
    err: ParseValueError,
    line: u32,
    col: u32,
) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();

    var diag = Diagnostics.init(0, 0, "untouched", null);
    try expectError(err, parse_with(&tree, input, options, &diag));
    try expectEqual(line, diag.line);
    try expectEqual(col, diag.col);
    try expect(!std.mem.eql(u8, diag.message(), "untouched"));
}

pub fn expect_failure(input: []const u8, err: ParseValueError, line: u32, col: u32) !void {
    try expect_failure_with(input, options_default, err, line, col);
}

/// `check_invariants` on every map reachable from `root`, iteratively (no recursion).
pub fn check_maps(root: Value) void {
    var stack: [512]Value = undefined;
    var depth: usize = 1;
    stack[0] = root;
    for (0..4096) |_| {
        if (depth == 0) return;
        depth -= 1;
        switch (stack[depth]) {
            .map => |map| {
                map.check_invariants();
                for (map.items()) |entry| {
                    stack[depth] = entry.value;
                    depth += 1;
                }
            },
            .array => |items| {
                for (items) |item| {
                    stack[depth] = item;
                    depth += 1;
                }
            },
            else => {},
        }
    }
    unreachable; // proof: the test documents are far smaller than the step bound.
}

pub fn field(value: Value, name: []const u8) !Value {
    try expect(value == .map);
    const found = value.map.get(name) orelse return error.TestMissingKey;
    return found.*;
}

pub fn expect_keys(value: Value, names: []const []const u8) !void {
    try expect(value == .map);
    try expectEqual(names.len, value.map.count);
    for (names, value.map.items()) |name, entry| try expectEqualStrings(name, entry.key);
}

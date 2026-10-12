//! json/locate — the byte offset of the value a `reflect.Path` names (ADR 0003 section 8).
//!
//! `reflect.parse_traced` leaves the key path of a failure; `locate` walks a `Scanner` along it
//! so the format layer can turn the failure into a source line:col. `.index` counts whole
//! elements, `.none` descends nowhere, `.key` matches the LAST occurrence of the key by decoded
//! bytes (`scanner.raw_eql`), because that is the value a `.last` DOM keeps. A `Scanner` is a
//! plain value, so a copy taken at each match is a snapshot the walk returns to.
//!
//! Total: a segment that finds nothing, has the wrong shape, or meets a scan error ends the walk
//! at the deepest value found, and malformed input yields an offset too. The offset is the first
//! byte of the value, never of its key.
//!
//! Allocation: none. Cost: at most `depth_max` containers deep, one scan per segment of the
//! parent it descends into, so O(depth_max * input) in the worst case, not O(input). A key
//! segment names the last matching source key, so a hook that parses under a synthetic key
//! is located on a source key of the same name if one exists.

const std = @import("std");
const core = @import("../core.zig");
const context = @import("../reflect/context.zig");
const scanner = @import("scanner.zig");
const assert = std.debug.assert;
const Diagnostics = core.Diagnostics;
const Path = context.Path;
const Scanner = scanner.Scanner;
const Segment = context.Segment;
const Token = scanner.Token;

/// A value found inside a container: its first token, and the scanner just after that token.
const Found = struct { scanner: Scanner, token: Token };

/// The offset of the first byte of the value `path` names in `input`, or of the deepest value
/// along it that exists. Returns 0 when not even the root can be read. The result is at most
/// `input.len`, and `path` is not modified.
/// Preconditions: `1 <= options.depth_max <= core.value.nesting_max`;
/// `path.count <= nesting_max`.
pub fn locate(input: []const u8, options: scanner.Options, path: *const Path) u32 {
    assert(options.depth_max >= 1);
    assert(path.count <= core.value.nesting_max);

    var walker: Scanner = undefined;
    // proof: `init` returns only `InputTooLarge`; such an input has no readable value.
    walker.init(input, options) catch return 0;
    var diag = Diagnostics.init(0, 0, "", null);
    // Any scan error means there is no root value to point at.
    var token = walker.next(&diag) catch return 0;
    for (path.segments[0..path.count]) |segment| {
        const found = descend(&walker, token, segment, &diag) orelse break;
        walker = found.scanner;
        token = found.token;
    }
    assert(token.offset <= input.len);
    return token.offset;
}

/// The child of the container opened by `token` that `segment` names, or null.
/// Precondition: `walker` is positioned just after `token`.
fn descend(walker: *Scanner, token: Token, segment: Segment, diag: *Diagnostics) ?Found {
    assert(token.kind != .end);
    assert(token.offset < walker.offset);
    switch (segment) {
        .none => return .{ .scanner = walker.*, .token = token },
        .key => |name| {
            if (token.kind != .object_begin) return null;
            return find_member(walker, name, diag);
        },
        .index => |number| {
            if (token.kind != .array_begin) return null;
            return find_element(walker, number, diag);
        },
    }
}

/// The value of the last member named `name` in the object whose `{` was just read.
fn find_member(walker: *Scanner, name: []const u8, diag: *Diagnostics) ?Found {
    assert(walker.depth >= 1);
    assert(walker.containers.isSet(walker.depth - 1));
    var best: ?Found = null;
    for (0..walker.input.len + 1) |_| {
        const member = walker.next(diag) catch return best;
        if (member.kind == .object_end) return best;
        assert(member.kind == .key);
        const value = walker.next(diag) catch return best;
        const matches = scanner.raw_eql(member.raw, member.has_escapes, name);
        if (matches) best = .{ .scanner = walker.*, .token = value };
        if (!skip_value(walker, value, diag)) return best;
    }
    unreachable; // proof: each member consumes at least its key, so the input runs out first.
}

/// The element `number` of the array whose `[` was just read.
fn find_element(walker: *Scanner, number: u64, diag: *Diagnostics) ?Found {
    assert(walker.depth >= 1);
    assert(!walker.containers.isSet(walker.depth - 1));
    for (0..walker.input.len + 1) |element_index| {
        const element = walker.next(diag) catch return null;
        if (element.kind == .array_end) return null;
        if (element_index == number) return .{ .scanner = walker.*, .token = element };
        if (!skip_value(walker, element, diag)) return null;
    }
    unreachable; // proof: each element consumes at least one byte, so the input runs out first.
}

/// Consumes the rest of the value that starts with `first`; false on a scan error.
/// Precondition: `walker` is positioned just after `first`.
fn skip_value(walker: *Scanner, first: Token, diag: *Diagnostics) bool {
    assert(first.kind != .end);
    assert(first.kind != .key);
    switch (first.kind) {
        .object_begin, .array_begin => {},
        else => return true,
    }
    assert(walker.depth >= 1);
    const target = walker.depth - 1;
    for (0..walker.input.len + 1) |_| {
        if (walker.depth == target) return true;
        _ = walker.next(diag) catch return false;
    }
    unreachable; // proof: each token consumes at least one byte, so the input runs out first.
}

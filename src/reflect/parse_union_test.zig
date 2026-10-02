//! reflect/parse union tests — tagged unions (ADR 0002 sections 2 and 5): a void variant is a
//! `.string` tag, any other variant a single-entry `.map` `{tag: payload}` whose payload path
//! segment is the wire tag. Every shape error, the options table (`rename`, `rename_all`),
//! unions inside structs, optionals and slices, and the container depth boundary.

const std = @import("std");
const core = @import("../core.zig");
const parse_mod = @import("parse.zig");
const rig_mod = @import("parse_rig.zig");

const Value = core.Value;
const ValueTree = core.ValueTree;
const parse = parse_mod.parse;
const testing = std.testing;
const position_none = core.diagnostics.position_none;
const Rig = rig_mod.Rig;
const kv = rig_mod.kv;
const int = rig_mod.int;
const str = rig_mod.str;
const sentinel = rig_mod.sentinel;

const Tcp = struct { host: []const u8, port: u16 };
const Endpoint = union(enum) { tcp: Tcp, unix: []const u8, none };
const Holder = struct { kind: Endpoint };
const Wire = union(enum) {
    unix_socket: []const u8,
    plain_text,
    tcp_port: u16,
    pub const sigil_options = .{ .rename_all = .kebab_case };
};
const Aliased = union(enum) {
    first: u8,
    second,
    pub const sigil_options = .{ .rename = .{ .first = "one" } };
};
const Node = union(enum) { leaf, kids: []const Node };
const Boxed = struct { node: Node };

fn unknown_message(
    comptime T: type,
    comptime prefix: []const u8,
    comptime tag: []const u8,
) []const u8 {
    return std.fmt.comptimePrint("{s}unknown {s} \"{s}\"", .{ prefix, @typeName(T), tag });
}

fn tcp_value(rig: *Rig, host: []const u8, port: Value) !Value {
    return rig.obj(&.{ kv("host", str(host)), kv("port", port) });
}

test "union: a void variant parses from its string tag" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const got = try rig.ok(Endpoint, str("none"));
    try testing.expect(got == .none);
    try testing.expect((try rig.ok(Wire, str("plain-text"))) == .plain_text);
}

test "union: a payload variant parses from a single-entry map" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const tcp_in = try rig.obj(&.{kv("tcp", try tcp_value(&rig, "h", int(80)))});
    const tcp = (try rig.ok(Endpoint, tcp_in)).tcp;
    try testing.expectEqualStrings("h", tcp.host);
    try testing.expectEqual(@as(u16, 80), tcp.port);
    const unix_in = try rig.obj(&.{kv("unix", str("/run/s.sock"))});
    const unix = try rig.ok(Endpoint, unix_in);
    try testing.expectEqualStrings("/run/s.sock", unix.unix);
}

test "union: a bad payload reports the tag as a path segment" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const big = try rig.obj(&.{kv("tcp", try tcp_value(&rig, "h", int(70000)))});
    const range = "tcp.port: 70000 is out of range for u16";
    try rig.fails(Endpoint, big, error.IntegerOutOfRange, range);
    const wrong = try rig.obj(&.{ kv("host", int(1)), kv("port", int(2)) });
    const bad_host = try rig.obj(&.{kv("tcp", wrong)});
    try rig.fails(Endpoint, bad_host, error.TypeMismatch, "tcp.host: expected string, found int");
    const missing = try rig.obj(&.{kv("tcp", try rig.obj(&.{kv("host", str("h"))}))});
    try rig.fails(Endpoint, missing, error.MissingField, "tcp: missing field \"port\"");
    const unix = try rig.obj(&.{kv("unix", int(5))});
    try rig.fails(Endpoint, unix, error.TypeMismatch, "unix: expected string, found int");
}

test "union: an unknown tag is UnknownEnumValue, as a string and as a map key" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const unknown = error.UnknownEnumValue;
    try rig.fails(Endpoint, str("icmp"), unknown, unknown_message(Endpoint, "", "icmp"));
    try rig.fails(Endpoint, str("None"), unknown, unknown_message(Endpoint, "", "None"));
    try rig.fails(Endpoint, str(""), unknown, unknown_message(Endpoint, "", ""));
    const keyed = try rig.obj(&.{kv("icmp", int(1))});
    try rig.fails(Endpoint, keyed, unknown, unknown_message(Endpoint, "", "icmp"));
    const nested = try rig.obj(&.{kv("kind", str("icmp"))});
    const message = unknown_message(Endpoint, "kind: ", "icmp");
    try rig.fails(Holder, nested, unknown, message);
}

test "union: a map with zero or two entries is TypeMismatch" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const empty = try rig.obj(&.{});
    try rig.fails_like(Endpoint, empty, error.TypeMismatch, "");
    const two = try rig.obj(&.{ kv("unix", str("a")), kv("none", str("b")) });
    try rig.fails_like(Endpoint, two, error.TypeMismatch, "");
    const tagged_pair = try rig.obj(&.{ kv("unix", str("a")), kv("tcp", int(1)) });
    const field = try rig.obj(&.{kv("kind", tagged_pair)});
    try rig.fails_like(Holder, field, error.TypeMismatch, "kind: ");
}

test "union: a void tag with a payload and a payload tag without one are TypeMismatch" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const void_with_payload = try rig.obj(&.{kv("none", str("x"))});
    try rig.fails_like(Endpoint, void_with_payload, error.TypeMismatch, "");
    const void_with_null = try rig.obj(&.{kv("none", .null)});
    try rig.fails_like(Endpoint, void_with_null, error.TypeMismatch, "");
    try rig.fails_like(Endpoint, str("tcp"), error.TypeMismatch, "");
    try rig.fails_like(Endpoint, str("unix"), error.TypeMismatch, "");
    const field = try rig.obj(&.{kv("kind", str("tcp"))});
    try rig.fails_like(Holder, field, error.TypeMismatch, "kind: ");
}

test "union: a value that is neither a string nor a map is TypeMismatch" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.fails_like(Endpoint, int(1), error.TypeMismatch, "");
    try rig.fails_like(Endpoint, .null, error.TypeMismatch, "");
    try rig.fails_like(Endpoint, .{ .bool = true }, error.TypeMismatch, "");
    try rig.fails_like(Endpoint, .{ .bytes = "none" }, error.TypeMismatch, "");
    try rig.fails_like(Endpoint, try rig.ints(&.{1}), error.TypeMismatch, "");
    const wrapped = try rig.obj(&.{kv("kind", int(7))});
    try rig.fails_like(Holder, wrapped, error.TypeMismatch, "kind: ");
}

test "union: tag names follow rename_all and rename, the Zig names stop working" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const sock = try rig.ok(Wire, try rig.obj(&.{kv("unix-socket", str("/s"))}));
    try testing.expectEqualStrings("/s", sock.unix_socket);
    const port = try rig.ok(Wire, try rig.obj(&.{kv("tcp-port", int(9))}));
    try testing.expectEqual(@as(u16, 9), port.tcp_port);
    const snake = try rig.obj(&.{kv("unix_socket", str("/s"))});
    const unknown = error.UnknownEnumValue;
    try rig.fails(Wire, snake, unknown, unknown_message(Wire, "", "unix_socket"));
    const plain = unknown_message(Wire, "", "plain_text");
    try rig.fails(Wire, str("plain_text"), unknown, plain);
    const bad = try rig.obj(&.{kv("tcp-port", int(-1))});
    try rig.fails(Wire, bad, error.IntegerOutOfRange, "tcp-port: -1 is out of range for u16");

    const one = try rig.ok(Aliased, try rig.obj(&.{kv("one", int(3))}));
    try testing.expectEqual(@as(u8, 3), one.first);
    try testing.expect((try rig.ok(Aliased, str("second"))) == .second);
    const old = try rig.obj(&.{kv("first", int(3))});
    try rig.fails(Aliased, old, unknown, unknown_message(Aliased, "", "first"));
}

test "union: as a struct field, an optional and a slice element" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const field = try rig.ok(Holder, try rig.obj(&.{kv("kind", str("none"))}));
    try testing.expect(field.kind == .none);
    const maybe_null = try rig.ok(?Endpoint, .null);
    try testing.expect(maybe_null == null);
    const maybe_some = try rig.ok(?Endpoint, try rig.obj(&.{kv("unix", str("u"))}));
    try testing.expectEqualStrings("u", maybe_some.?.unix);
    const list_in = try rig.arr(&.{
        str("none"),
        try rig.obj(&.{kv("unix", str("a"))}),
        try rig.obj(&.{kv("tcp", try tcp_value(&rig, "h", int(1)))}),
    });
    const list = try rig.ok([]const Endpoint, list_in);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expect(list[0] == .none);
    try testing.expectEqualStrings("a", list[1].unix);
    try testing.expectEqual(@as(u16, 1), list[2].tcp.port);
    const bad_tcp = try rig.obj(&.{kv("tcp", try tcp_value(&rig, "h", int(-5)))});
    const bad_in = try rig.arr(&.{ str("none"), bad_tcp });
    const message = "[1].tcp.port: -5 is out of range for u16";
    try rig.fails([]const Endpoint, bad_in, error.IntegerOutOfRange, message);
    const bad_tag = try rig.arr(&.{str("icmp")});
    const unknown = error.UnknownEnumValue;
    const tag_message = unknown_message(Endpoint, "[0]: ", "icmp");
    try rig.fails([]const Endpoint, bad_tag, unknown, tag_message);
}

test "union: an out-of-memory slice of unions names the path and leaks nothing" {
    const input = [_]Value{ str("none"), str("none") };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var tree: ValueTree = undefined;
    tree.init(failing.allocator());
    defer tree.deinit();
    var diag = sentinel();
    const result = parse([]const Endpoint, &tree, .{ .array = &input }, &diag);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expectEqual(position_none, diag.line);
    try testing.expect(std.mem.endsWith(u8, diag.message(), "failed: OutOfMemory"));
}

fn kids_chain(rig: *Rig, levels: u32) !Value {
    std.debug.assert(levels > 0);
    var current = str("leaf");
    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        current = try rig.obj(&.{kv("kids", try rig.arr(&.{current}))});
    }
    return current;
}

fn levels_of(node: Node) u32 {
    var total: u32 = 0;
    var current = node;
    while (current == .kids) : (total += 1) current = current.kids[0];
    return total;
}

test "union depth: a union map is a container, 128 pass and the 129th is TooDeep" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    // A level is the union map plus its array: two containers.
    const sixty_three = try rig.ok(Node, try kids_chain(&rig, 63));
    try testing.expectEqual(@as(u32, 63), levels_of(sixty_three));
    const exact = try rig.ok(Node, try kids_chain(&rig, 64)); // 128 containers
    try testing.expectEqual(@as(u32, 64), levels_of(exact));
    // The struct adds one container: 1 + 63 * 2 = 127 pass, 1 + 64 * 2 = 129 fail.
    const boxed = try rig.ok(Boxed, try rig.obj(&.{kv("node", try kids_chain(&rig, 63))}));
    try testing.expectEqual(@as(u32, 63), levels_of(boxed.node));
    const over = try rig.obj(&.{kv("node", try kids_chain(&rig, 64))});
    try testing.expectError(error.TooDeep, parse(Boxed, &rig.tree, over, &rig.diag));
    const reason = ": exceeds nesting depth limit 128";
    try testing.expect(std.mem.endsWith(u8, rig.diag.message(), reason));
    const marker = core.diagnostics.truncation_marker;
    try testing.expect(std.mem.startsWith(u8, rig.diag.message(), marker));
    try testing.expectEqual(position_none, rig.diag.line);
    const deep = try kids_chain(&rig, 65);
    try testing.expectError(error.TooDeep, parse(Node, &rig.tree, deep, &rig.diag));
    try testing.expect(std.mem.endsWith(u8, rig.diag.message(), reason));
}

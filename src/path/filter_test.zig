//! Tests for JSONPath filters (plan 005 item 7): the RFC 9535 section 2.3.5.3 examples and the
//! section 1.5 bookstore filters with expected results copied from the RFC, the functions
//! `length`/`count`/`value`, `!`/`&&`/`||` and parentheses, absolute queries, nested filters,
//! exact number comparison across `int`/`uint`/`float` (including values an `f64` cast would
//! conflate), every filter `QueryError` variant with its byte column, and the depth and size
//! limits at their boundaries. Documents are parsed by `json.dom` (a test-only import).

const std = @import("std");
const core = @import("../core.zig");
const dom = @import("../json/dom.zig");
const writer = @import("../json/writer.zig");
const filter = @import("filter.zig");
const jsonpath = @import("jsonpath.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Diagnostics = core.Diagnostics;
const Item = filter.Item;
const Program = jsonpath.Program;
const Value = core.Value;
const ValueTree = core.ValueTree;

const nesting_max = core.value.nesting_max;
const parse_options: dom.ParseOptions = .{ .depth_max = nesting_max, .duplicate_key = .reject };
const render_options: writer.StringifyOptions = .{
    .layout = .minified,
    .sort_keys = false,
    .escape = .minimal,
    .depth_max = nesting_max,
};

const rfc_doc =
    \\{"a":[3,5,1,2,4,6,{"b":"j"},{"b":"k"},{"b":{}},{"b":"kilo"}],
    \\"o":{"p":1,"q":2,"r":3,"s":5,"t":{"u":6}},"e":"f"}
;

const bookstore =
    \\{"store":{"book":[
    \\{"category":"reference","author":"Nigel Rees","title":"Sayings of the Century","price":8.95},
    \\{"category":"fiction","author":"Evelyn Waugh","title":"Sword of Honour","price":12.99},
    \\{"category":"fiction","author":"Herman Melville","title":"Moby Dick","isbn":"0-553-21311-3",
    \\"price":8.99},
    \\{"category":"fiction","author":"J. R. R. Tolkien","title":"The Lord of the Rings",
    \\"isbn":"0-395-19395-8","price":22.99}],
    \\"bicycle":{"color":"red","price":399}}}
;

fn compile(query: []const u8) !Program {
    var program: Program = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    jsonpath.compile(&program, query, &diag) catch |err| {
        std.log.err("query '{s}' failed with {s}: {f}", .{ query, @errorName(err), &diag });
        return err;
    };
    program.check_invariants();
    return program;
}

/// Parses `doc`, selects `query`, and compares the JSON rendering of each result in order.
fn expect_select(doc: []const u8, query: []const u8, expected: []const []const u8) !void {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, doc, parse_options, &diag);
    const program = try compile(query);

    var out: [64]*const Value = undefined;
    const nodes = try jsonpath.select(&program, &root, &out);
    try expectEqual(expected.len, nodes.len);
    for (nodes, expected) |node, want| {
        var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer text.deinit();
        try writer.write(&text.writer, node.*, render_options, &diag);
        try expectEqualStrings(want, text.written());
    }
}

fn expect_fails(query: []const u8, expected: jsonpath.QueryError, column: u32) !void {
    var program: Program = undefined;
    var diag = Diagnostics.init(0, 0, "", null);
    const result = jsonpath.compile(&program, query, &diag);
    try std.testing.expectError(expected, result);
    try expectEqual(@as(u32, 1), diag.line);
    try expectEqual(column, diag.col);
}

fn expect_compiles(query: []const u8) !void {
    _ = try compile(query);
}

const b_objects = [_][]const u8{
    "{\"b\":\"j\"}",
    "{\"b\":\"k\"}",
    "{\"b\":{}}",
    "{\"b\":\"kilo\"}",
};
const a_array = "[3,5,1,2,4,6,{\"b\":\"j\"},{\"b\":\"k\"},{\"b\":{}},{\"b\":\"kilo\"}]";

test "filter: RFC 9535 section 2.3.5.3 examples" {
    try expect_select(rfc_doc, "$.a[?@>3.5]", &.{ "5", "4", "6" });
    try expect_select(rfc_doc, "$.a[?@.b]", &b_objects);
    try expect_select(rfc_doc, "$[?@.*]", &.{
        a_array,
        "{\"p\":1,\"q\":2,\"r\":3,\"s\":5,\"t\":{\"u\":6}}",
    });
    try expect_select(rfc_doc, "$[?@[?@.b]]", &.{a_array});
    try expect_select(rfc_doc, "$.o[?@<3, ?@<3]", &.{ "1", "2", "1", "2" });
    try expect_select(rfc_doc, "$.a[?@<2 || @.b == \"k\"]", &.{ "1", "{\"b\":\"k\"}" });
    try expect_select(rfc_doc, "$.o[?@>1 && @<4]", &.{ "2", "3" });
    try expect_select(rfc_doc, "$.o[?@.u || @.x]", &.{"{\"u\":6}"});
    try expect_select(rfc_doc, "$.a[?(@.b == 'kilo')]", &.{"{\"b\":\"kilo\"}"});
    try expect_select(rfc_doc, "$.a[?@ > 3.5 && !(@ > 5)]", &.{ "5", "4" });
    try expect_select(rfc_doc, "$..[?@.b]", &b_objects);
    try expect_select(rfc_doc, "$.o['p', ?@>2]", &.{ "1", "3", "5" });
}

test "filter: bookstore filters from RFC 9535 section 1.5" {
    try expect_select(bookstore, "$..book[?@.isbn].title", &.{
        "\"Moby Dick\"",
        "\"The Lord of the Rings\"",
    });
    try expect_select(bookstore, "$..book[?@.price<10].title", &.{
        "\"Sayings of the Century\"",
        "\"Moby Dick\"",
    });
    try expect_select(bookstore, "$.store[?@.price > 100].color", &.{"\"red\""});
    try expect_select(bookstore, "$..book[?@.price == $.store.bicycle.price]", &.{});
}

test "filter: functions length, count and value" {
    const lengths = "[\"ab\",[1,2],{\"a\":1,\"b\":2},\"x\",5,\"\\u00e9\"]";
    try expect_select(lengths, "$[?length(@)==2]", &.{ "\"ab\"", "[1,2]", "{\"a\":1,\"b\":2}" });
    try expect_select(lengths, "$[?length(@)==1]", &.{ "\"x\"", "\"\u{e9}\"" });
    try expect_select(lengths, "$[?length(@)==0]", &.{});
    const counted = "[{\"a\":1,\"b\":2},{\"a\":1},[1,2],3]";
    try expect_select(counted, "$[?count(@.*)==2]", &.{ "{\"a\":1,\"b\":2}", "[1,2]" });
    try expect_select(counted, "$[?count(@.a)==0]", &.{ "[1,2]", "3" });
    const valued = "[{\"a\":1},{\"a\":{\"a\":1}},{\"a\":2}]";
    try expect_select(valued, "$[?value(@..a)==1]", &.{"{\"a\":1}"});
    try expect_select(valued, "$[?length(value(@.a))==1]", &.{"{\"a\":{\"a\":1}}"});
    try expect_select(valued, "$[?count(@..a) == 2]", &.{"{\"a\":{\"a\":1}}"});
}

test "filter: existence, negation, absolute queries and missing members" {
    try expect_select("[{\"a\":1},{\"b\":1},3]", "$[?!@.a]", &.{ "{\"b\":1}", "3" });
    try expect_select("[{\"a\":1},{\"b\":1},3]", "$[?!(@.a || @.b)]", &.{"3"});
    const target = "{\"target\":2,\"x\":{\"id\":2},\"y\":{\"id\":3}}";
    try expect_select(target, "$[?@.id == $.target]", &.{"{\"id\":2}"});
    try expect_select(target, "$[?$.target == 2 && @.id]", &.{ "{\"id\":2}", "{\"id\":3}" });
    try expect_select("[{\"a\":null},{\"b\":1}]", "$[?@.a == null]", &.{"{\"a\":null}"});
    try expect_select("[{\"a\":null},{\"b\":1}]", "$[?@.a]", &.{"{\"a\":null}"});
    try expect_select("[{\"k\":1},{\"x\":1,\"y\":2}]", "$[?@.x == @.y]", &.{"{\"k\":1}"});
    try expect_select("[{\"x\":1,\"y\":2}]", "$[?@.x != @.y]", &.{"{\"x\":1,\"y\":2}"});
    try expect_select("[true,false,0]", "$[?@ == true]", &.{"true"});
    try expect_select("[true,false,0]", "$[?@ != false]", &.{ "true", "0" });
}

test "filter: arrays and objects compare by value, strings by bytes, types never mix" {
    const doc = "[{\"a\":[1,{\"c\":2}],\"b\":[1,{\"c\":2}]},{\"a\":[1],\"b\":[2]}]";
    try expect_select(doc, "$[?@.a == @.b]", &.{"{\"a\":[1,{\"c\":2}],\"b\":[1,{\"c\":2}]}"});
    try expect_select("[\"a\",\"b\",\"c\",1]", "$[?@ < \"b\"]", &.{"\"a\""});
    try expect_select("[\"a\",\"b\",\"c\",1]", "$[?@ <= \"b\"]", &.{ "\"a\"", "\"b\"" });
    try expect_select("[\"a\",\"b\",\"c\",1]", "$[?@ >= \"b\"]", &.{ "\"b\"", "\"c\"" });
    try expect_select("[\"a\",1,3,null]", "$[?@ < 2]", &.{"1"});
    try expect_select("[\"a\",1,3,null]", "$[?@ <= null]", &.{"null"});
    try expect_select("[\"1\",1]", "$[?@ == 1]", &.{"1"});
}

const keys_equal = "{\"a\":{\"x\":1,\"y\":2},\"b\":{\"y\":2,\"x\":1}}";

test "filter: container equality ignores key order and compares numbers by value" {
    const keys = "[" ++ keys_equal ++ ",{\"a\":{\"x\":1},\"b\":{\"z\":1}}]";
    try expect_select(keys, "$[?@.a == @.b]", &.{keys_equal});
    const numbers = "[{\"a\":[1,[0.0]],\"b\":[1.0,[-0]]},{\"a\":[1],\"b\":[1,2]}]";
    try expect_select(numbers, "$[?@.a == @.b]", &.{"{\"a\":[1,[0.0]],\"b\":[1.0,[0]]}"});
    try expect_select(numbers, "$[?@.a != @.b]", &.{"{\"a\":[1],\"b\":[1,2]}"});
    try expect_select(keys, "$[?@.a <= @.b]", &.{keys_equal});
    try expect_select(keys, "$[?@.a >= @.b]", &.{keys_equal});
    try expect_select("[{\"k\":1}]", "$[?@.x <= @.y]", &.{"{\"k\":1}"});
    try expect_select("[{\"k\":1}]", "$[?@.x >= @.y]", &.{"{\"k\":1}"});
    try expect_select("[{\"x\":1}]", "$[?@.x >= @.y]", &.{});
    try expect_select("[{\"x\":1}]", "$[?@.y <= @.x]", &.{});
    try expect_select("[{\"a\":[1,{\"c\":[]}],\"b\":[1,{\"c\":{}}]}]", "$[?@.a == @.b]", &.{});
}

test "filter: numbers compare by exact value across int, uint and float" {
    const doc = "[9007199254740993,9007199254740992,9007199254740992.0,1.0,1]";
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    var diag = Diagnostics.init(0, 0, "", null);
    const root = try dom.parse(&tree, doc, parse_options, &diag);
    var out: [8]*const Value = undefined;
    const exact = try compile("$[?@ == 9007199254740992]");
    try expectEqual(@as(usize, 2), (try jsonpath.select(&exact, &root, &out)).len);
    const above = try compile("$[?@ > 9007199254740992]");
    try expectEqual(@as(usize, 1), (try jsonpath.select(&above, &root, &out)).len);
    const one = try compile("$[?@ == 1.0]");
    try expectEqual(@as(usize, 2), (try jsonpath.select(&one, &root, &out)).len);

    const wide = "[18446744073709551615,-1,1.8446744073709552e19,9223372036854775807]";
    const wide_root = try dom.parse(&tree, wide, parse_options, &diag);
    const max = try compile("$[?@ == 18446744073709551615]");
    try expectEqual(@as(usize, 1), (try jsonpath.select(&max, &wide_root, &out)).len);
    const over = try compile("$[?@ > 9223372036854775807]");
    try expectEqual(@as(usize, 2), (try jsonpath.select(&over, &wide_root, &out)).len);
    const below = try compile("$[?@ < -0.5]");
    try expectEqual(@as(usize, 1), (try jsonpath.select(&below, &wide_root, &out)).len);
}

test "filter: order_numbers is exact, antisymmetric and false for NaN" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const pool = [_]Item{
        .{ .int = std.math.minInt(i64) },     .{ .int = -1 },
        .{ .int = 0 },                        .{ .int = 9007199254740993 },
        .{ .int = std.math.maxInt(i64) },     .{ .uint = std.math.maxInt(i64) + 1 },
        .{ .uint = std.math.maxInt(u64) },    .{ .float = -inf },
        .{ .float = -0.0 },                   .{ .float = 0.5 },
        .{ .float = 9007199254740992.0 },     .{ .float = 9223372036854775808.0 },
        .{ .float = 18446744073709551616.0 }, .{ .float = inf },
    };
    for (pool) |a| {
        try expectEqual(@as(?std.math.Order, .eq), filter.order_numbers(a, a));
        try expectEqual(@as(?std.math.Order, null), filter.order_numbers(a, .{ .float = nan }));
        try expectEqual(@as(?std.math.Order, null), filter.order_numbers(.{ .float = nan }, a));
        for (pool) |b| {
            const forward = filter.order_numbers(a, b).?;
            try expectEqual(forward.invert(), filter.order_numbers(b, a).?);
        }
    }
    const lt = std.math.Order.lt;
    try expectEqual(@as(?std.math.Order, lt), filter.order_numbers(pool[0], pool[1]));
    try expectEqual(@as(?std.math.Order, lt), filter.order_numbers(pool[4], pool[5]));
    try expectEqual(@as(?std.math.Order, lt), filter.order_numbers(pool[5], pool[6]));
    try expectEqual(@as(?std.math.Order, .gt), filter.order_numbers(pool[3], pool[10]));
    try expectEqual(@as(?std.math.Order, .eq), filter.order_numbers(pool[2], pool[8]));
    try expectEqual(@as(?std.math.Order, .eq), filter.order_numbers(pool[5], pool[11]));
    try expectEqual(@as(?std.math.Order, lt), filter.order_numbers(pool[6], pool[12]));
}

test "filter: NaN never compares equal or ordered" {
    var tree: ValueTree = undefined;
    tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = try tree.dupe_array(&.{ .{ .float = std.math.nan(f64) }, .{ .int = 1 } });
    var out: [4]*const Value = undefined;
    for ([_][]const u8{ "$[?@ == @]", "$[?@ < 2]", "$[?@ >= 0 && @ != 1]" }) |query| {
        const program = try compile(query);
        const found = try jsonpath.select(&program, &root, &out);
        const expected: usize = if (std.mem.eql(u8, query, "$[?@ == @]") or
            std.mem.eql(u8, query, "$[?@ < 2]")) 1 else 0;
        try expectEqual(expected, found.len);
    }
}

test "filter: compile errors name the variant and the byte column" {
    try expect_fails("$[?]", error.InvalidSyntax, 4);
    try expect_fails("$[?@.a ==]", error.InvalidSyntax, 10);
    try expect_fails("$[?@.* == 1]", error.InvalidSyntax, 4);
    try expect_fails("$[?1 == @..*]", error.InvalidSyntax, 9);
    try expect_fails("$[?!@.a == 1]", error.InvalidSyntax, 9);
    try expect_fails("$[?1]", error.InvalidSyntax, 4);
    try expect_fails("$[?length(@.a)]", error.InvalidSyntax, 4);
    try expect_fails("$[?@.a = 1]", error.InvalidSyntax, 8);
    try expect_fails("$[?(@.a]", error.InvalidSyntax, 8);
    try expect_fails("$[?@.a == 01]", error.InvalidSyntax, 11);
    try expect_fails("$[?@.a == tru]", error.InvalidSyntax, 11);
    try expect_fails("$[?match(@.a, 'x')]", error.UnsupportedFunction, 4);
    try expect_fails("$[?search(@.a, 'x')]", error.UnsupportedFunction, 4);
    try expect_fails("$[?foo(@.a)]", error.UnknownFunction, 4);
    try expect_fails("$[?length()]", error.UnknownFunction, 11);
    try expect_fails("$[?count(@.a, @.b) == 1]", error.UnknownFunction, 13);
    try expect_fails("$[?length(@.*) == 1]", error.UnknownFunction, 11);
    try expect_fails("$[?count(1) == 1]", error.UnknownFunction, 10);
    try expect_fails("$[?value(length(@)) == 1]", error.UnknownFunction, 10);
    try expect_fails("$[?@.a == 99999999999999999999]", error.IntegerOutOfRange, 11);
}

test "filter: depth, filter, node and query limits at their boundaries" {
    try expect_compiles("$[?(((((((@.a)))))))]"); // 1 filter + 7 parentheses = 8 levels
    try expect_fails("$[?((((((((@.a))))))))]", error.FilterTooDeep, 11);
    try expect_compiles("$[?@[?@[?@[?@[?@[?@[?@]]]]]]]"); // 7 nested filters + outer = 8
    try expect_compiles("$[?@[?@[?@[?@[?@[?@[?@[?@]]]]]]]]");
    try expect_fails("$[?@[?@[?@[?@[?@[?@[?@[?@[?@]]]]]]]]]", error.FilterTooDeep, 27);
    try expect_compiles("$[?length(value(@.a)) == 1]");

    var query: [1024]u8 = undefined;
    const filters_ok = build_list(&query, "$[", "?@.a", ",", 32, "]");
    try expect_compiles(filters_ok);
    const filters_over = build_list(&query, "$[", "?@.a", ",", 33, "]");
    try expect_fails(filters_over, error.FilterTooLong, 3 + 5 * 32);

    const nodes_ok = build_list(&query, "$[?", "1==1", "||", 32, "]");
    try expect_compiles(nodes_ok);
    const nodes_over = build_list(&query, "$[?", "1==1", "||", 33, "]");
    try expect_fails(nodes_over, error.FilterTooLong, 199);

    const queries_ok = build_list(&query, "$[?", "@.a", "||", 32, "]");
    try expect_compiles(queries_ok);
    const queries_over = build_list(&query, "$[?", "@.a", "||", 33, "]");
    try expect_fails(queries_over, error.FilterTooLong, 4 + 5 * 32);
}

fn put(sink: *std.Io.Writer, text: []const u8) void {
    // proof: every list built here fits the 1024-byte buffer, the longest is 33 x 5 bytes.
    sink.writeAll(text) catch unreachable;
}

test "filter: embedded queries share the segment and selector pools" {
    var query: [1024]u8 = undefined;
    try expect_compiles(build_list(&query, "$[?", "@.a.b", "||", 16, "]"));
    const segments_over = build_list(&query, "$[?", "@.a.b", "||", 17, "]");
    try expect_fails(segments_over, error.TooManySegments, 4 + 7 * 16);
    try expect_compiles(build_list(&query, "$[?", "@[1,2,3,4]", "||", 16, "]"));
    const selectors_over = build_list(&query, "$[?", "@[1,2,3,4]", "||", 17, "]");
    try expect_fails(selectors_over, error.TooManySelectors, 4 + 12 * 16);
}

/// `head`, `count` copies of `item` separated by `separator`, then `tail`, in `buffer`.
fn build_list(
    buffer: []u8,
    head: []const u8,
    item: []const u8,
    separator: []const u8,
    count: u32,
    tail: []const u8,
) []const u8 {
    var writer_state = std.Io.Writer.fixed(buffer);
    put(&writer_state, head);
    for (0..count) |index| {
        if (index > 0) put(&writer_state, separator);
        put(&writer_state, item);
    }
    put(&writer_state, tail);
    return writer_state.buffered();
}

test "filter: a filter on a scalar or an empty container selects nothing" {
    try expect_select("[]", "$[?@]", &.{});
    try expect_select("{}", "$[?@.a]", &.{});
    try expect_select("5", "$[?@]", &.{});
    try expect_select("[[],{}]", "$[?@.*]", &.{});
    try expect_select("[[],{}]", "$[?count(@.*) == 0]", &.{ "[]", "{}" });
}

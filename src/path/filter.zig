//! path/filter — JSONPath filter expressions (RFC 9535 section 2.3.5): the compiled form and its
//! evaluation (ADR 0004 section 6).
//!
//! A filter is a tree of `Expr` nodes in `Program.exprs`, children before parents, so node `i`
//! only refers to nodes below `i`. Every node records the `owner` filter it was parsed for; a
//! nested filter (inside an embedded `@`/`$` query) interleaves its nodes with its parent's, and
//! `owner` keeps the two apart. Evaluation walks the owned nodes of one filter in index order,
//! computing one `Item` per node into a local array, so an expression itself needs no recursion
//! or stack. Both sides of `&&`/`||` are evaluated (the nodes are pure), which keeps the loop flat.
//!
//! The only recursion is an embedded query that contains a filter: evaluating it re-enters
//! `select.walk` one level deeper. The parser rejects more than `filter_depth_max` levels with
//! `FilterTooDeep`, and `select` asserts the level, so the machine stack stays bounded at
//! `filter_depth_max + 1` walks of about 9 KB each (ADR 0004 section 6, amended in plan 005
//! item 7).
//!
//! Comparison follows RFC 9535 section 2.3.5.2.2 with `core.number` exactness: `int`, `uint` and
//! `float` compare by exact value, never through an `f64` cast of an integer; NaN compares false.
//! Allocation: none. Cost: O(nodes x (1 + embedded query work)) per candidate.

const std = @import("std");
const core = @import("../core.zig");
const jsonpath = @import("jsonpath.zig");
const select = @import("select.zig");
const assert = std.debug.assert;
const Order = std.math.Order;
const Program = jsonpath.Program;
const Value = core.Value;

pub const Function = enum { length, count, value };

pub const CompareOp = enum { eq, ne, lt, le, gt, ge };

/// An embedded query: `absolute` starts at the document root (`$`), else at the candidate (`@`).
/// Its segments are `sub_segments[segments_first..][0..segments_count]`; `singular` is true when
/// it can select at most one node (every segment a single name or index, no `..`).
pub const QueryRef = struct {
    absolute: bool,
    singular: bool,
    segments_first: u32,
    segments_count: u32,
};

/// A filter's nodes are `exprs[first..=root]` that it owns; `root` is its logical expression.
pub const Filter = struct { first: u32, root: u32 };

pub const Pair = struct { left: u32, right: u32 };

pub const Node = union(enum) {
    literal_null,
    literal_bool: bool,
    literal_int: i64,
    literal_uint: u64,
    literal_float: f64,
    literal_string: jsonpath.Name,
    /// The node list of embedded query `queries[index]`.
    query: u32,
    /// Existence test: `child` is a `query` node; true when it selects at least one node.
    exists: u32,
    call: struct { function: Function, argument: u32 },
    compare: struct { op: CompareOp, left: u32, right: u32 },
    conjunction: Pair,
    disjunction: Pair,
    negation: u32,
};

pub const Expr = struct { owner: u32, node: Node };

/// The result of one node. `node` is a document node of container type (a scalar document node
/// is converted to its own item); `nodes` is the summary of a query's node list.
pub const Item = union(enum) {
    nothing,
    null,
    boolean: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    /// A container, `bytes` or `timestamp` document node (other scalars become their own item).
    node: *const Value,
    nodes: struct { count: u32, first: ?*const Value },
};

/// Evaluates filter `filter_index` of `program` with `@` = `candidate`, `$` = `root`, at nesting
/// `level` (0 for the main query). `TooDeep` comes from a document deeper than `nesting_max`.
pub fn evaluate(
    program: *const Program,
    root: *const Value,
    level: u32,
    filter_index: u32,
    candidate: *const Value,
) select.SelectError!bool {
    assert(filter_index < program.filters_count);
    assert(level <= jsonpath.filter_depth_max);
    const filter = program.filters[filter_index];
    assert(filter.first <= filter.root);
    assert(filter.root < program.exprs_count);

    var items: [jsonpath.exprs_max]Item = undefined;
    for (filter.first..filter.root + 1) |index| {
        const expr = program.exprs[index];
        if (expr.owner != filter_index) continue;
        items[index] = try evaluate_node(program, root, level, expr.node, candidate, &items);
        assert(expr.owner == filter_index);
    }
    const result = items[filter.root];
    assert(program.exprs[filter.root].owner == filter_index);
    return switch (result) {
        .boolean => |value| value,
        else => unreachable, // proof: the parser makes every filter root a logical node.
    };
}

fn evaluate_node(
    program: *const Program,
    root: *const Value,
    level: u32,
    node: Node,
    candidate: *const Value,
    items: []const Item,
) select.SelectError!Item {
    assert(program.exprs_count <= jsonpath.exprs_max);
    assert(items.len == jsonpath.exprs_max);
    switch (node) {
        .literal_null => return .null,
        .literal_bool => |value| return .{ .boolean = value },
        .literal_int => |value| return .{ .int = value },
        .literal_uint => |value| return .{ .uint = value },
        .literal_float => |value| return .{ .float = value },
        .literal_string => |name| return .{ .string = program.name_text(name) },
        .query => |index| return query_item(program, root, level, index, candidate),
        .exists => |child| return .{ .boolean = items[child].nodes.count > 0 },
        .call => |call| return call_item(call.function, items[call.argument]),
        .compare => |compare| {
            const left = value_of(items[compare.left]);
            const right = value_of(items[compare.right]);
            return .{ .boolean = try compare_items(compare.op, left, right) };
        },
        .conjunction => |pair| {
            return .{ .boolean = items[pair.left].boolean and items[pair.right].boolean };
        },
        .disjunction => |pair| {
            return .{ .boolean = items[pair.left].boolean or items[pair.right].boolean };
        },
        .negation => |child| return .{ .boolean = !items[child].boolean },
    }
}

fn query_item(
    program: *const Program,
    root: *const Value,
    level: u32,
    index: u32,
    candidate: *const Value,
) select.SelectError!Item {
    assert(index < program.queries_count);
    const found = try select.summarize(program, root, level + 1, program.queries[index], candidate);
    return .{ .nodes = .{ .count = found.count, .first = found.first } };
}

fn call_item(function: Function, argument: Item) Item {
    switch (function) {
        .count => {
            assert(argument == .nodes);
            return .{ .int = argument.nodes.count };
        },
        .value => return value_of(argument),
        .length => switch (value_of(argument)) {
            .string => |text| {
                // A parsed tree holds valid UTF-8; a hand-built invalid string has no length.
                const length = std.unicode.utf8CountCodepoints(text) catch return .nothing;
                return .{ .int = @intCast(length) };
            },
            .node => |container| switch (container.*) {
                .array => |items| return .{ .int = @intCast(items.len) },
                .map => |map| return .{ .int = map.count },
                else => return .nothing,
            },
            else => return .nothing,
        },
    }
}

/// The comparable value of an item: a node list of exactly one node is that node, any other
/// node list is `nothing`; a document node becomes the matching scalar item.
fn value_of(item: Item) Item {
    switch (item) {
        .nodes => |found| {
            if (found.count != 1) return .nothing;
            return item_of(found.first.?);
        },
        .node => |container| return item_of(container),
        else => return item,
    }
}

fn item_of(node: *const Value) Item {
    return switch (node.*) {
        .null => .null,
        .bool => |value| .{ .boolean = value },
        .int => |value| .{ .int = value },
        .uint => |value| .{ .uint = value },
        .float => |value| .{ .float = value },
        .string => |text| .{ .string = text },
        else => .{ .node = node },
    };
}

fn compare_items(op: CompareOp, left: Item, right: Item) select.SelectError!bool {
    switch (op) {
        .eq => return equal(left, right),
        .ne => return !(try equal(left, right)),
        .lt => return less(left, right),
        .gt => return less(right, left),
        .le => return less(left, right) or (try equal(left, right)),
        .ge => return less(right, left) or (try equal(left, right)),
    }
}

fn equal(left: Item, right: Item) select.SelectError!bool {
    if (is_number(left) and is_number(right)) return order_numbers(left, right) == Order.eq;
    return switch (left) {
        .nothing => right == .nothing,
        .null => right == .null,
        .boolean => |a| right == .boolean and right.boolean == a,
        .string => |a| right == .string and std.mem.eql(u8, a, right.string),
        .node => |a| right == .node and try deep_equal(a, right.node),
        .int, .uint, .float, .nodes => false,
    };
}

const nesting_max = core.value.nesting_max;

const EqualFrame = struct { a: *const Value, b: *const Value, position: u32 };

const EqualNext = union(enum) {
    done,
    mismatch,
    pair: struct { a: *const Value, b: *const Value },
};

/// RFC 9535 value equality for document nodes: arrays by position, maps by key set (order does
/// not matter), numbers by exact value (`[1]` equals `[1.0]`), NaN never equal. Iterative, one
/// frame per container pair; `TooDeep` past `nesting_max`.
fn deep_equal(a: *const Value, b: *const Value) select.SelectError!bool {
    var frames: [nesting_max]EqualFrame = undefined;
    var depth: u32 = 0;
    switch (compare_pair(a, b)) {
        .unequal => return false,
        .equal => return true,
        .descend => {
            frames[0] = .{ .a = a, .b = b, .position = 0 };
            depth = 1;
        },
    }
    while (depth > 0) {
        assert(depth <= nesting_max);
        const next = next_pair(&frames[depth - 1]);
        switch (next) {
            .done => depth -= 1,
            .mismatch => return false,
            .pair => |pair| switch (compare_pair(pair.a, pair.b)) {
                .unequal => return false,
                .equal => {},
                .descend => {
                    if (depth == nesting_max) return error.TooDeep;
                    frames[depth] = .{ .a = pair.a, .b = pair.b, .position = 0 };
                    depth += 1;
                },
            },
        }
    }
    assert(depth == 0);
    return true;
}

const PairKind = enum { equal, unequal, descend };

/// Decides a pair of nodes without looking at children: containers of equal size descend.
fn compare_pair(a: *const Value, b: *const Value) PairKind {
    switch (a.*) {
        .array => |items| {
            if (b.* != .array or b.array.len != items.len) return .unequal;
            return if (items.len == 0) .equal else .descend;
        },
        .map => |map| {
            if (b.* != .map or b.map.count != map.count) return .unequal;
            return if (map.count == 0) .equal else .descend;
        },
        else => {},
    }
    if (b.* == .array or b.* == .map) return .unequal;
    const left = item_of(a);
    const right = item_of(b);
    if (is_number(left) and is_number(right)) {
        return if (order_numbers(left, right) == Order.eq) .equal else .unequal;
    }
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return .unequal;
    // proof: scalars (bytes and timestamps included) hold no children, so eql cannot be TooDeep.
    const same = core.value.eql(a.*, b.*) catch unreachable;
    return if (same) .equal else .unequal;
}

fn next_pair(frame: *EqualFrame) EqualNext {
    const index = frame.position;
    switch (frame.a.*) {
        .array => |items| {
            if (index == items.len) return .done;
            assert(frame.b.array.len == items.len);
            frame.position += 1;
            return .{ .pair = .{ .a = &items[index], .b = &frame.b.array[index] } };
        },
        .map => |*map| {
            const entries = map.items();
            if (index == entries.len) return .done;
            assert(frame.b.map.count == map.count);
            frame.position += 1;
            const other = &frame.b.map;
            const found = other.get(entries[index].key) orelse return .mismatch;
            return .{ .pair = .{ .a = &entries[index].value, .b = found } };
        },
        else => unreachable, // proof: only container pairs are pushed as frames.
    }
}

fn less(left: Item, right: Item) bool {
    if (is_number(left) and is_number(right)) return order_numbers(left, right) == Order.lt;
    if (left == .string and right == .string) {
        return std.mem.order(u8, left.string, right.string) == Order.lt;
    }
    return false;
}

fn is_number(item: Item) bool {
    return switch (item) {
        .int, .uint, .float => true,
        else => false,
    };
}

/// Exact three-way order of two number items; null when either is NaN.
pub fn order_numbers(left: Item, right: Item) ?Order {
    assert(is_number(left));
    assert(is_number(right));
    switch (left) {
        .int => |a| switch (right) {
            .int => |b| return std.math.order(a, b),
            .uint => |b| return order_int_uint(a, b),
            .float => |b| return invert(order_float_int(b, a)),
            else => unreachable, // proof: asserted a number above.
        },
        .uint => |a| switch (right) {
            .int => |b| return invert(order_int_uint(b, a)),
            .uint => |b| return std.math.order(a, b),
            .float => |b| return invert(order_float_uint(b, a)),
            else => unreachable, // proof: asserted a number above.
        },
        .float => |a| switch (right) {
            .int => |b| return order_float_int(a, b),
            .uint => |b| return order_float_uint(a, b),
            .float => |b| {
                if (std.math.isNan(a) or std.math.isNan(b)) return null;
                return std.math.order(a, b);
            },
            else => unreachable, // proof: asserted a number above.
        },
        else => unreachable, // proof: asserted a number above.
    }
}

fn invert(order: ?Order) ?Order {
    const value = order orelse return null;
    return value.invert();
}

fn order_int_uint(a: i64, b: u64) Order {
    if (a < 0) return .lt;
    return std.math.order(@as(u64, @intCast(a)), b);
}

fn order_float_int(f: f64, i: i64) ?Order {
    if (std.math.isNan(f)) return null;
    if (f >= 9223372036854775808.0) return .gt;
    if (f < -9223372036854775808.0) return .lt;
    const whole = @floor(f);
    const base: i64 = @intFromFloat(whole);
    const order = std.math.order(base, i);
    if (order != Order.eq) return order;
    return if (f > whole) .gt else .eq;
}

fn order_float_uint(f: f64, u: u64) ?Order {
    if (std.math.isNan(f)) return null;
    if (f >= 18446744073709551616.0) return .gt;
    if (f < 0) return .lt;
    const whole = @floor(f);
    const base: u64 = @intFromFloat(whole);
    const order = std.math.order(base, u);
    if (order != Order.eq) return order;
    return if (f > whole) .gt else .eq;
}

test {
    _ = @import("filter_test.zig");
}

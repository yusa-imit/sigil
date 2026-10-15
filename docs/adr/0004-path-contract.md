# ADR-0004 — the path contract: Pointer, Merge Patch, Patch, JSONPath

- Status: accepted
- Date: 2026-10-14
- Plan item: `docs/plans/005-phase-2e-path.md` item 1 (design only)
- Amends: `docs/PRD.md` §4.4; replaces the `path.zig` stub `Error = error{NotImplemented}`
- Extends: ADR-0003 §6 (`Diagnostics` positions), ADR-0002 §3 (shared `TooDeep`/`OutOfMemory`)

## Context

`sigil.path` is the first module that reads and *changes* an existing `core.Value` tree. Four
facts of `core` shape everything below:

- A `Value` is a 32-byte plain union of borrowed slices. `array` is `[]const Value` and a `Map`
  has a capacity fixed at `init` (`OutOfSpace` past it). Nothing mutates in place cheaply, and a
  `Value` alone owns nothing: memory belongs to the `ValueTree` arena, freed once at `deinit`.
- `core.value.nesting_max` (128) is the depth every parser and `eql` honours. A tree deeper than
  that is data `eql` reports as `TooDeep`; `path` must never build one.
- Tiger Style: a limit on everything, no recursion, no storing a `gpa`, no allocation after setup
  for read-only operations.
- This is a one-way door from v0.4.0: zoltraak will `switch` over these error sets.

## Decision

### 1. Layout and names

```
src/path.zig            re-exports pointer, merge, patch, jsonpath; no code
src/path/pointer.zig    RFC 6901
src/path/merge.zig      RFC 7386
src/path/patch.zig      RFC 6902
src/path/jsonpath.zig   RFC 9535 subset: parse + select (may split into jsonpath_*.zig siblings
                        for the 800-line file limit, never into a hierarchy)
```

`path/` may import `core/` and nothing else (REALM.md: format modules are siblings; `path` is the
one module that sits on `core` alone and works on any format's tree). It does not import `json`.

### 2. Results are borrowed views; mutation goes through the tree (a)

Read operations take `root: *const Value` and return `*const Value` pointing *into that tree*.
They live until `ValueTree.deinit`, and stay valid across later `merge`/`patch` calls (§4: no
mutation is in place). Mutating operations take `tree: *ValueTree` and operate on `tree.root`:

```zig
// pointer.zig
pub const segments_max: u32 = core.value.nesting_max;       // 128
pub const Segment = struct { raw: []const u8 };             // sub-slice of the pointer text
pub const Pointer = struct {
    text: []const u8,
    segments: []const Segment,                              // caller buffer, `[0..count]`
};
pub const ParseError = error{ InvalidPointer, TooDeep };
pub fn parse(text: []const u8, buffer: []Segment, diag: *Diagnostics) ParseError!Pointer;
/// Null when the pointer names nothing (absence is a result, not an error).
pub fn resolve(root: *const Value, pointer: Pointer) ?*const Value;
pub fn format(pointer: Pointer, w: *std.Io.Writer) std.Io.Writer.Error!void;
```

- `Segment.raw` keeps `~0`/`~1` undecoded; comparison against a key decodes on the fly, so
  `parse` and `resolve` allocate nothing. `buffer.len >= segments_max` is a precondition;
  a 129th segment is `TooDeep` (same boundary as the parsers).
- `InvalidPointer`: a non-empty text not starting with `/`, `~` not followed by `0` or `1`.
  Array-index grammar (`0` or `[1-9][0-9]*`, `-` end marker) is checked at `resolve`/apply time,
  because a segment is a key or an index depending on the node it meets.
- `resolve` returns null for: missing key, index past the end, `-` (never a node), a segment
  applied to a scalar, a leading-zero or signed or over-`u32` index. Never an error.
- `format` re-escapes (`~` first, then `/`) so `format(parse(t)) == t`.

```zig
// merge.zig
pub const MergeError = error{ TooDeep, OutOfMemory };
pub fn apply(tree: *ValueTree, patch: *const Value) MergeError!void;
```

`apply` merges `patch` (borrowed, any lifetime) into `tree.root` per RFC 7386. The plan said
`apply(tree, target, patch)`; the target is always the root, so it is `tree.root` and the failure
rule of §4 can swap it atomically.

### 3. Patch and Merge Patch operands (b)

```zig
// patch.zig — `ops` is the RFC 6902 document as a Value: an array of operation maps.
pub const PatchError = error{
    InvalidPatch,     // ops not an array of maps; "op"/"path"/"from"/"value" missing or mistyped
    UnknownOp,        // "op" is not add|remove|replace|move|copy|test
    InvalidPointer,   // a "path" or "from" does not parse (as pointer.ParseError.InvalidPointer)
    PathNotFound,     // remove|replace|move|copy|test target, or the parent of an add, is absent
    IndexOutOfRange,  // array index past the end (add: past length; others: past length - 1)
    TestFailed,       // "test" found an unequal value (core.value.eql)
    InvalidMove,      // "from" is a proper prefix of "path" (RFC 6902 §4.4)
    TooDeep, OutOfMemory,
};
pub fn apply(tree: *ValueTree, ops: *const Value, diag: *Diagnostics) PatchError!void;
```

`InvalidPointer` aside, the variants are provoked one-to-one by RFC 6902 appendix A cases. The
`"value"` operand is borrowed from the caller and **deep-copied into the tree** (bounded explicit
stack of `nesting_max` frames, no recursion); strings, bytes and keys are duplicated through
`dupe_string`/`dupe_bytes`/`dupe_key`. After `apply`, nothing the tree holds aliases `ops`.

### 4. Atomicity: path copying, then one root swap (c)

Chosen: **copy the spine, swap the root on success.** Every op builds a new container for each
node on the path from the root to the change (`dupe_array` / `new_map` + entries) and *shares* the
untouched siblings; `tree.root` is assigned once, after the last op succeeded. Rejected:
validate-all-first (duplicates the application logic and still needs the mutation to be correct
for ops that depend on earlier ops, e.g. `add` then `move`), and deep copy (O(document)).

- A failed op, `TestFailed`, `TooDeep` or `OutOfMemory` at any point leaves `tree.root`
  **byte-for-byte unchanged and still valid**. The caller never sees a half-applied patch.
- Garbage stays: abandoned and superseded nodes are not freed until `deinit` (an arena cannot
  free one allocation). Cost per op is O(depth x width of the containers on the path). A
  `k`-op patch on a document with an array of `n` entries therefore allocates up to `k * n *
  32` bytes. This is documented on `apply`; tuning (reuse nodes this apply already owns) is a
  later plan, not a contract change.
- Sharing of untouched siblings is safe because nothing in `path` mutates a node in place.
  `copy` and `move` deep-copy their source into the tree (move = remove, then add of the copy)
  instead of sharing it (amended in plan 005 item 4): a shared subtree would make the tree a
  DAG, every depth check on it a walk of the expanded tree, and `k` doubling `copy`s an
  exponential walk. A deep copy costs memory proportional to what it produces, which the
  allocator already bounds. The tree therefore never holds one subtree twice.
- Array indices: one past the end at any step of a path is `IndexOutOfRange`; `-` (except
  `add`'s final segment) and malformed indices name nothing and are `PathNotFound`. `remove` of
  the document root is `InvalidPatch`; `move` onto its own location is a no-op, into its own
  child `InvalidMove` (amended in plan 005 item 4).
- Depth: an `add`/`replace`/`copy`/merge whose result would be deeper than `nesting_max` is
  `TooDeep`; the invariant "a tree `path` produced has depth <= `nesting_max`" holds.
- `Map` has no delete, so `remove` and merge-`null` build a map without the entry (insertion order
  of the rest kept). `add` of an existing key replaces in place order; of a new key appends.

### 5. One error vocabulary (d)

`TooDeep` and `OutOfMemory` are the same two names as `core.Error`. Every other variant is local
to its operation (sets above plus `QueryError` in §6). No `anyerror`, no `NotImplemented`, no
`Unsupported*` that a later plan will not turn into support: unsupported grammar is a typed
`QueryError` variant so callers can `switch` on it. Diagnostics follow ADR-0003 §6:

- Pointer and JSONPath parse failures: `line = 1`, `col` = 1-based **byte** column in the text,
  snippet = the text around it (`core.diagnostics.snippet_of`), message names the rule.
- Patch: `line = col = position_none`, message `op <index>: <reason>` (0-based op index). The
  tree has no source positions, so a format layer may re-locate it as ADR-0002 §3 describes.
- Diagnostics is written on every `error` return from the above; it is untouched on success.

### 6. JSONPath: subset, limits, result type (e)

```zig
// jsonpath.zig
pub const segments_max: u32 = 32;      // segments in one query
pub const selectors_max: u32 = 64;     // selectors in the whole query, filters included
pub const filter_depth_max: u32 = 8;   // nesting of (...), !, and filters inside filters
pub const query_len_max: u32 = 1024;   // bytes; decoded name strings live in the program
pub const QueryError = error{
    InvalidSyntax, QueryTooLong, TooManySegments, TooManySelectors, FilterTooDeep,
    UnsupportedFunction,   // match|search (I-Regexp): see below
    UnknownFunction,       // anything else, or wrong arity or argument type
    IntegerOutOfRange,     // index/slice/step outside I-JSON +-(2^53 - 1)
};
pub const Program = struct { ... };    // fixed arrays inside; init through an out pointer
pub fn compile(program: *Program, query: []const u8, diag: *Diagnostics) QueryError!void;

pub const SelectError = error{ OutOfSpace, TooDeep };
/// Nodes in document order, duplicates kept (`$[0,0]` yields two). `out.len` is `matches_max`.
pub fn select(program: *const Program, root: *const Value, out: []*const Value)
    SelectError![]*const Value;
```

- **In:** `$`, child (`.name`, `['n']`, `["n"]` with RFC escapes), index (negative counts from the
  end), `*`, slice `start:end:step` (negative step, step `0` selects nothing), descendant `..`
  (before a name, `*`, index or bracket), selector lists `[a, b]`, and filters `?expr`:
  comparison (`== != < <= > >=`), `&&`, `||`, `!`, parentheses, existence test of a relative
  (`@`) or absolute (`$`) query, literals (number, string, `true`, `false`, `null`), and the
  functions `length`, `count`, `value` (they allocate nothing).
- **Out:** `match` and `search` need an I-Regexp matcher. A no-allocation matcher is its own
  design; they compile to `UnsupportedFunction`, which the conformance corpus pins as
  unsupported, never skipped silently. Normalized-path output (RFC 9535 §2.7) is out of scope.
- **Number comparison** follows `core.number`: `int`, `uint`, `float` compare by exact
  mathematical value, never by coercing an integer through `f64`. A float NaN compares false.
  Strings compare by bytes (UTF-8 code point order, which equals byte order).
- **No recursion:** `select` keeps an explicit stack of `(container, next child index)` frames of
  length `nesting_max`; a document deeper than that is `TooDeep` (cannot occur for a tree from
  `json`, but a hand-built `Value` is not trusted). Filters evaluate on a separate bounded stack
  of `filter_depth_max` frames. Cost: O(nodes visited x selectors); `$..*` is O(document).
- `select` writes at most `out.len` nodes; one more is `OutOfSpace` and `out` contents are
  unspecified. An empty result is `out[0..0]`, never an error.
- `Program` borrows nothing from `query` (decoded names are copied inline), so the query text
  may be freed after `compile`. A `Program` is read-only after `compile` and shareable by threads.

### 7. Conformance

Corpus runs (item 8) count `pass`, `fail`, `pinned_unsupported` and assert all three; the
unsupported set is exactly the `match`/`search` tests. RFC 6901 §5, RFC 7386 appendix A and RFC
6902 appendix A are tests with expected values taken from the RFCs, not from our output.

## Consequences

- Read paths are zero-allocation and stable under mutation. Mutation costs arena garbage, bounded
  by `ops x path width`, in exchange for atomicity with no rollback code.
- Untouched siblings are shared between a tree's old and new spine (garbage versions), never
  within the live document. Code that mutates a tree in place (none in sigil) must not assume
  unique ownership of a node it did not allocate itself.
- `Program` is a fixed few-KB struct: callers who need longer queries must wait for a limits type
  parameter, an additive change.
- zoltraak's `JSON.GET` needs `compile` + `select` with a fixed `out` buffer and the typed
  errors above; no allocator.
- Risks accepted: I-Regexp absence (reviewed in a later plan); O(n) array `add`.

# ADR-0005 — the TOML contract: datetimes, build strategy, redefinition, writer

- Status: accepted
- Date: 2026-10-19
- Plan item: `docs/plans/006-phase-3a-toml.md` item 1 (design only)
- Amends: `docs/PRD.md` §4.3 TOML row; replaces the `toml.zig` stub `Error = error{NotImplemented}`
- Extends: ADR-0003 §1-§3 (pull lexer, byte positions, one error vocabulary), ADR-0002 §3

## Context

TOML v1.0.0 differs from JSON in four ways that a format contract must settle before code:

- It has four datetime kinds; `core.Timestamp` (`seconds`, `nanoseconds`, `offset_minutes: ?i16`)
  cannot tell a local date or a local time from a local datetime.
- A table is extended out of order (`[a.b]`, `[c]`, `[a.d]`), but a `core.Map` has a capacity
  fixed at `init` and `Value` is immutable plain data.
- Whether a key or table may be (re)opened depends on *how* it was first made. The invalid half of
  toml-test is mostly this.
- Document order is semantic for sigil (`eql` compares maps in insertion order, REALM round-trip
  rule), but TOML forces scalar keys of a table to precede its `[sub-tables]`.

This is a one-way door from v0.5.0: zr will `switch` over these error sets.

## Decision

### 1. Layout and names

```
src/toml.zig            facade: re-exports, options, parse_value / parse / write_value / stringify
src/toml/lexer.zig      pull lexer over one complete slice (ADR 0003 §1 shape)
src/toml/parser.zig     key/table state machine, values on an explicit stack, scratch -> tree
src/toml/writer.zig     order-preserving writer
src/core/timestamp.zig  civil date <-> days, RFC 3339 / TOML datetime parse and format (shared)
```

`toml/` imports `core/` and `reflect/` only, never `json/` or another format (REALM sibling rule).
`core/timestamp.zig` is in `core` because CBOR tag 0 needs the same text form.

### 2. Datetimes (a): a `kind` tag on `core.Timestamp`

```zig
pub const Timestamp = struct {
    pub const Kind = enum(u8) { instant, local_datetime, local_date, local_time };
    kind: Kind,
    seconds: i64,            // meaning per kind, below
    nanoseconds: u32,        // 0..999_999_999
    offset_minutes: ?i16,    // -1439..1439
};
```

| Kind | TOML | `seconds` | `offset_minutes` |
|---|---|---|---|
| `instant` | `1979-05-27T07:32:00Z`, `...-07:00` | Unix epoch, UTC | the written offset; null only for a source with none (CBOR tag 1) |
| `local_datetime` | `1979-05-27T07:32:00` | the civil fields read as if UTC | null |
| `local_date` | `1979-05-27` | midnight of that date, as if UTC; `nanoseconds` 0 | null |
| `local_time` | `07:32:00.5` | `0..86399` since midnight (date part 1970-01-01) | null |

- Invariants, asserted by `Timestamp.check_invariants` and called by tests: `kind != .instant`
  implies `offset_minutes == null`; `local_date` implies `seconds % 86400 == 0` and
  `nanoseconds == 0`; `local_time` implies `0 <= seconds < 86400`; offsets lie in +-1439.
- `kind` has no default: every construction site names it (Tiger Style §1.15). `reflect` and
  `json.writer` are updated in item 2; `json.writer` still refuses every kind as `Unrepresentable`.
- Why a tag rather than separate `Value` variants: `Value` stays 32 bytes, `reflect` keeps one
  `core.Timestamp` type, and CBOR tag 0/1 maps onto `instant` unchanged.
- Parse accepts `T`, `t` or one space between date and time, and `Z` or `z`. `-00:00` equals
  `+00:00`. Fraction digits beyond 9 are truncated, not rounded (TOML: "truncated").
- A written `:60` second is `InvalidDatetime`: Unix time cannot hold it and no format the kingdom
  speaks keeps it. If toml-test disagrees, item 8 pins that case as unsupported with this reason.
- Calendar rules are real: month 1-12, day by month and leap year (2000 yes, 1900 no), hour 0-23,
  minute 0-59, second 0-59, offset hour 0-23 and minute 0-59, year 0000-9999 (four digits).
- The writer prints the shortest fraction (no trailing zeros, none when 0), `Z` for offset 0 on
  an `instant` with `offset_minutes == 0`, and a null-offset `instant` as `Z` too.

### 3. Build strategy (b): scratch tree, then one exact copy

A counting pass is rejected: to know how many keys `a` ends up with, the pass must run the whole
redefinition state machine (§4), so it would be the parser written twice. Instead:

1. **Scratch build.** `parse_value(gpa, ...)` allocates once, before reading, two arrays from
   `gpa`: `nodes` and `edges`, each bounded by the input (`nodes_max = input.len / 2 + 1`; a node
   needs at least one key byte and one separator byte). A scratch table is a node with a
   first-child / last-child / count linked list, so appending a child is O(1) and needs no
   capacity. Each node carries the §4 state and the byte offset of its definition (for diags).
   Scalars and strings are copied into the *tree* arena as they are lexed (they are final).
2. **Materialize.** One iterative walk (explicit `[nesting_max]Frame` stack) turns each scratch
   table into `tree.new_map(child_count)` of exactly its final size and each array into
   `dupe_array`. Nothing in the tree is ever resized or reallocated; `check_invariants` holds on
   every map.
3. **Free.** The scratch arrays are freed with `gpa` before `parse_value` returns, on success and
   on error (`errdefer`/`defer` pair). Nothing is allocated from `gpa` after step 1, so a
   `FailingAllocator` sweep is exactly two failure points plus the tree arena.

As built (plan 006 items 5 and 6, `toml/scratch.zig`): `nodes_max` is `input.len / 2 + 2 +
depth_max` (every node but the root costs at least two input bytes once its container is
closed, which gives the `+ 2`; a `[` or `{` costs one byte until its closer arrives, and at
most `depth_max` containers are open at once, which gives the last term). The two arrays are
the node array and a hash index over (parent, key), sized to a power of two at least twice
`nodes_max`, so a lookup is O(1) and a table with a million keys is not quadratic. `Map.put`
is not used by `materialize`, since its duplicate scan is linear; the index has already proved
the keys unique. Key bytes borrow the input unless an escape was decoded (then they already live in the tree arena).

The benchmark (item 11) records scratch bytes per input byte beside arena bytes per input byte.
If the `input.len / 2 + 1` bound proves wasteful the bound is tightened by a cheap pre-count of
`=`, `[` and `,` bytes — an optimisation inside item 5, not a contract change.

### 4. Redefinition (c): one state per table

Every scratch table and array has exactly one state; the keys of a TOML document form a tree of
these.

| State | Made by | Later `[header]` final segment | Later dotted key through it | `k = v` for same key |
|---|---|---|---|---|
| `implicit` | an intermediate segment of a header or of `[[ ]]` | becomes `header` (once) | `TableRedefined` | `DuplicateKey` |
| `header` | `[a.b]`, or `[[a]]` element | `TableRedefined` | `TableRedefined` | `DuplicateKey` |
| `dotted` | `a.b = v` makes `a` | `TableRedefined` | allowed, same section only | `DuplicateKey` |
| `inline` | `{ ... }` value, frozen from its `{` | `TableRedefined` | `TableRedefined` | `DuplicateKey` |
| `array_static` | `a = [ ... ]` | `TypeConflict` | `TypeConflict` | `DuplicateKey` |
| `array_tables` | first `[[a]]` | append an element | `TypeConflict` | `DuplicateKey` |

- A header or dotted key *passing through* (not ending on) a table is allowed for `implicit`,
  `header`, `dotted` (the spec's `[fruit.apple.texture]` after `apple.color = ...`) and
  `array_tables` (goes to the last element). It is `TableRedefined` for `inline` and
  `TypeConflict` for `array_static` and for any scalar.
- A header or dotted key *ending on* a table follows the table's row above. `[[a]]` on anything but
  `array_tables` or a missing key is `TypeConflict`.
- Dotted keys may only extend tables made by dotted keys of the *same* section; because a section
  header opens a fresh table that cannot be reopened, this needs no extra bookkeeping. A dotted
  key through a table made by any header, implicit or not, is `TableRedefined`
  (toml-test `append-with-dotted-keys-1/2`).
- Inside `{ }` the same rules apply to the inline table's own subtree, with the inline state
  assigned at the closing brace. Each `[[a]]` element starts as `header`.
- A key assigned twice, or a value assigned where a table/array already sits, is `DuplicateKey`
  (the name `core.Map.put` already uses). Keys compare as bytes after escape decoding, so
  `"a"` and `a` collide.
- The diagnostic position is the first byte of the offending key segment, and the message names
  the segment and the line of the earlier definition.

### 5. Scalars and limits (d, e)

- **Integers are `i64`** (spec). The parser only ever produces `.int`, never `.uint`. Decimal goes
  through `core.number.parse_integer` after `_` is stripped into a bounded buffer; a `.uint` result
  is `IntegerAboveMax`, below `minInt(i64)` is `IntegerBelowMin`. `0x`/`0o`/`0b` are decoded by the
  lexer with its own overflow check (no sign allowed; above `maxInt(i64)` is `IntegerAboveMax`).
  `_` only between digits; a leading zero in decimal is `InvalidNumber`.
- **Floats** go through `core.number.parse_float` (`FloatOutOfRange` past f64). Every NaN
  (`nan`, `+nan`, `-nan`) is stored as the one positive quiet NaN and written as `nan`, so
  parse -> write -> parse is `eql` (bitwise float equality, ADR 0003 §3). `-0.0` is kept.
- **Writer refusals** (`Unrepresentable`): `.null`, `.bytes`. `.uint` above `maxInt(i64)` is also
  `Unrepresentable`; a smaller `.uint` is written as an integer and re-parses as `.int`, so such
  trees are outside the round-trip property (the seeded generator emits `.int` only).
  Non-UTF-8 text is `InvalidUtf8`. A root that is not a map is `RootNotTable`.
- **Depth.** `depth_max` (1..128, default none) counts *containers on the path including the
  root*, so a tree the parser builds always fits `core.value.eql`. Every key segment of a header
  or dotted key, every array, every inline table adds one; `[[a]]` adds two (array and element).
  The boundary is therefore **127 header segments pass, 128 are `TooDeep`**; nested arrays and
  inline tables hit it at the same container count. Plan 006 items 5-6 say 128/129; that counted
  segments without the root, which would build a tree `eql` rejects. The tests use 127/128.
  `TooDeep` points at the segment or bracket that exceeds the limit.
- **Input** longer than `bytes_max` (a `u32`, at most `Lexer.input_len_max` = `maxInt(u32) - 16`,
  headroom for the lexer's `offset + 8` lookahead) is `InputTooLarge` before any
  byte is read. Tokens are bounded by input; the one other limit: a number containing `_` and longer than
  `number_text_max` (512) is `InvalidNumber`, because underscores are stripped into that buffer. Lexer string and number
  scratch is one bounded buffer of `number_text_max` bytes (numbers) and decodes strings straight
  into the tree arena (a decoded string is never longer than its source, ADR 0003 §1).
- **Lines**: LF and CRLF end a line; a bare CR is `UnexpectedToken`. A BOM is `UnexpectedToken`.
  A control character other than tab (and DEL) in a comment or string is `ControlCharacter`.
  `col` is bytes, 1-based (ADR 0003 §2).

### 6. Errors (c, ADR 0003 §3 vocabulary)

`ParseValueError`, 17 variants (a comptime test pins the count and members):

| Variant | Same name in | When |
|---|---|---|
| `InputTooLarge` | `core.unicode.Error` | input > `bytes_max` |
| `UnexpectedEnd` | json | input ends inside a string, array, inline table or after `=` |
| `UnexpectedToken` | json | a byte the grammar forbids: bare CR, BOM, `{ a = 1, }`, newline in `{}`, `a = 1 b = 2` |
| `InvalidNumber` | json | leading zero, `1__0`, `_1`, `0x_1`, `1.`, `.5`, `+0x1` |
| `InvalidDatetime` | — | a datetime shape with a calendar or clock field out of range, or `:60` |
| `InvalidEscape` | json | `\x`, an unknown escape, a short or non-hex `\u`, `\U` above U+10FFFF |
| `LoneSurrogate` | `core.unicode_escape` | `\uD800`..`\uDFFF` |
| `ControlCharacter` | json | see §5 |
| `InvalidUtf8` | core | input is not strict UTF-8 |
| `TooDeep` | `core.value.eql` | §5 |
| `IntegerAboveMax`, `IntegerBelowMin`, `FloatOutOfRange` | `core.number` | §5 |
| `DuplicateKey` | `core.Map.put` | §4 |
| `TableRedefined`, `TypeConflict` | — | §4 |
| `OutOfMemory` | core | scratch or arena allocation failed |

`toml.ParseError = ParseValueError || reflect.ParseError`; reflect errors are re-located to the
value the key path names, as `json.parse` does. The position is the node's definition offset in
the scratch tree: a keyed value or table at its key (a `[header]` table at the last header
segment, a dotted-key table at its first key segment), an array element at its first byte, the
root at 1:1; `MissingField` and `UnknownField` therefore point at the table's key. The
re-location parses the text a second time on the error path only (`parser.locate`), and a failed
second allocation or parse falls back to 1:1. `WriteValueError` is
`core.unicode_escape.WriteError || error{ Unrepresentable, TooDeep, RootNotTable }` (6 variants);
`StringifyError` is `reflect.StringifyError || WriteValueError`. Every parse error writes `diag`
once with a line:col; success never writes it.

### 7. Public surface (f)

```zig
pub const ParseOptions = struct { depth_max: u16, bytes_max: u32 };
pub const StringifyOptions = struct { depth_max: u16 };
pub fn parse_value(gpa: Allocator, tree: *ValueTree, input: []const u8,
    options: ParseOptions, diag: *Diagnostics) ParseValueError!Value;
pub fn parse(comptime T: type, gpa: Allocator, tree: *ValueTree, input: []const u8,
    options: ParseOptions, diag: *Diagnostics) ParseError!T;
pub fn write_value(w: *Io.Writer, value: Value, options: StringifyOptions,
    diag: *Diagnostics) WriteValueError!void;
pub fn stringify(comptime T: type, tree: *ValueTree, w: *Io.Writer, value: T,
    options: StringifyOptions, diag: *Diagnostics) StringifyError!void;
pub const lexer = @import("toml/lexer.zig");
```

It mirrors `json.zig` with one addition: `gpa` leads `parse_value`/`parse` because of the scratch
arrays of §3 (it is used for the call and not stored). `parse_value` returns the root and does not
store it in `tree.root`. The result of `parse(T)` lives until `tree.deinit()`. No file helpers in
v0.5.0 (TOML configs are read by the consumer); `lexer` is public, an event parser is not.
No options default.

### 8. Writer (order-preserving)

`write_value` never reorders. TOML requires every key/value of a table to precede its
`[sub-tables]`, so a map entry may use header form only when **every later entry of the same map is
also a table or a non-empty array of maps**; an earlier map entry that is followed by a scalar is
written inline (`k = { a = 1, b = { c = 2 } }`), as is every map inside an array that is not a
pure array of maps. Re-parsing therefore returns the same key order and parse -> write -> parse
is `eql` for every tree the writer accepts.

- `k = scalar` first; then `[a.b]` headers in depth-first order; `[[a]]` for a non-empty array
  whose elements are all maps and that sits in the trailing table run; otherwise inline arrays.
- Keys are bare when `[A-Za-z0-9_-]+`, else basic-quoted with the escapes of `core.unicode_escape`.
  Strings are basic strings, escaping `"`, `\`, controls and DEL; non-ASCII UTF-8 is written raw.
- Floats always carry `.`, an exponent, or are `inf`, `-inf`, `nan`; integers are decimal.
- No dotted keys are written; there is no pretty-print option and no comments (PRD: none in v1).
- Iteration uses an explicit bounded stack (`depth_max`); the writer allocates nothing.

### 9. The toml-test runner (g)

`src/toml/conformance_test.zig` runs `tests/toml-test/` (pinned release, `SOURCE`, MIT licence
checked at vendoring). Its expectation files are tagged JSON; the runner decodes them with
**`std.json`**, not `sigil.json`, so no file under `src/toml/` imports `json/` even in tests. It
renders each parsed `Value` into the same tagged form (floats and datetimes compared by value:
floats as f64 with NaN equal to NaN, datetimes through `core.timestamp.format`) and compares
structurally. Counts are asserted: valid, invalid, pass, reject, pinned-unsupported (each pin with
a reason string, never a skip), and printed once per run.

## Consequences

- `core.Timestamp` gains a field: a breaking shape change, allowed in a foundation MINOR during
  `0.x`; CHANGELOG "Changed". No consumer pins sigil, so the cost is paid now.
- `parse_value` allocates `O(input)` scratch (`gpa`) in addition to the arena; bounded and freed
  before return. Documents of 100 KB cost a few MB of scratch, measured in item 11.
- Round-trip is exact for trees the writer accepts, at the price of inline tables in documents
  whose key order interleaves scalars and tables.
- 17 + 6 error variants become public; adding one later is a breaking change for exhaustive
  `switch`es.
- Items 2-12 of plan 006 follow this ADR; depth tests are 127/128, not 128/129 (§5).

# ADR-0003 — the JSON contract: scanner, positions, errors, DOM sizing, strictness, writer

- Status: accepted
- Date: 2026-10-08
- Plan item: `docs/plans/004-phase-2abc-json.md` item 1 (design only)
- Amends: ADR-0001 §3 and its json signatures (§9 below); `docs/PRD.md` §4.2, §4.3, §5
- Extends: ADR-0002 §3 (re-location of path-only errors, additive)

## Context

Plan 004 turns bytes into a `core.Value` for the first time. What it pins is copied twice: by
2D (direct-to-struct streaming) and 2E (path), which consume this scanner and DOM, and by TOML
and YAML, which copy the scanner shape, the position rule and the error vocabulary. A
consumer's exhaustive `switch` over a JSON error set is a one-way door from v0.3.0 on.

Forces:
- `core` gives `Value` (32 bytes), `Map.Entry` (48 bytes), a `Map` whose capacity is fixed at
  `init`, `number.parse_decimal` (i64/u64/f64 distinct, `IntegerAboveMax` past u64),
  `unicode.find_invalid` (u32 byte offsets, `InputTooLarge` past `maxInt(u32)`), `parse_hex4`,
  `decode_utf16`, `write_escaped`, and `Diagnostics` with 1-based positions and `position_none`.
- Tiger Style §1.7-1.9: a limit on everything, no recursion, no stored allocator. JSON nests
  and its input is hostile.
- PRD §5 asks for a DOM within 2x the input. A `[0,0,...]` element is 2 input bytes and one
  32-byte `Value`, so no layout over this `Value` meets it. What is left to decide is the
  transient cost of sizing `Map`s and arrays exactly, and an honest bound.
- ADR-0002 §3 promised that the format layer re-locates reflect's path-only errors, but
  `Context` unwinds its `Path` on the way out (`defer leave_child`): nothing survives to locate.
- ADR-0001 pinned `stringifyFile(io, scratch, ...)` as "allocates nothing", yet the pipeline
  runs `reflect.stringify`, which allocates every node in a `ValueTree`. The stub's error sets
  carry `DepthExceeded`, `NumberOutOfRange`, `ParseFailed` and `UnsupportedType`, which disagree
  with core and reflect, and `ParseOptions.deny_unknown_fields`, which ADR-0002 §6 put on the
  type.

## Decision

### 1. Scanner (a): a pull tokenizer over one complete slice, zero allocation

```zig
// src/json/scanner.zig
pub const Options = struct { depth_max: u16 }; // 1 <= depth_max <= nesting_max, asserted.
pub const Kind = enum(u8) {
    object_begin, object_end, array_begin, array_end, key, string, number,
    literal_true, literal_false, literal_null, end,
};
pub const Token = struct {
    kind: Kind,
    has_escapes: bool, // .key/.string only: `raw` holds at least one `\`.
    offset: u32,       // First byte; the opening quote of a .key/.string; input.len for .end.
    raw: []const u8,   // Sub-slice of the input: between the quotes, or the literal text.
};
pub const Scanner = struct {
    input: []const u8,
    offset: u32,
    depth: u16,
    depth_max: u16,
    containers: std.bit_set.IntegerBitSet(core.value.nesting_max), // Bit d: 1 = object.
    expect: Expect, // Private: what the grammar allows next.
    pub const InitError = error{InputTooLarge};
    pub fn init(scanner: *Scanner, input: []const u8, options: Options) InitError!void;
    pub fn next(scanner: *Scanner, diag: *Diagnostics) ScanError!Token;
};
/// Precondition: `raw` is from a .key/.string token and `out.len >= raw.len`.
pub fn decode_string(raw: []const u8, out: []u8) []u8; // Returns `out[0..decoded_len]`.
```

- **Complete slice only.** Every `raw` is a sub-slice of the input: no copy, no allocation.
  Chunked input is a different type later, not a mode of this one.
- **`next` validates everything**: structure, separators, literal spelling, RFC 8259 §6 number
  grammar, and string content (UTF-8 by `find_invalid`, no raw byte below 0x20, escape syntax,
  surrogate pairing by `parse_hex4`/`decode_utf16`). A string token is therefore always
  decodable, and `decode_string` has no error set: an escape never grows (`\uXXXX` is 6 bytes
  for at most 3, a pair 12 for 4), and each decode step is a proof-commented `catch unreachable`.
- **`.number` is grammar-checked, not range-checked.** Range belongs to the consumer: the DOM
  uses `core.number`, 2D reads straight into `u8`.
- **Depth** lives in a 128-bit stack. Opening container number `depth_max + 1` is `TooDeep` at
  its own bracket: 128 nested containers pass, 129 fail, the boundary of `core.value.eql` and
  reflect. `comptime assert(core.value.nesting_max <= std.math.maxInt(u16))`.
- **`.end`** comes exactly once, after the root value and trailing whitespace. Calling `next`
  after `.end` or after an error is a contract violation, asserted.
- **The scanner is a plain value** with no pointer but `input`, so a copy is a snapshot
  (`comptime assert(@sizeOf(Scanner) <= 64)`). §8's locator relies on it.
- `init` returns `InputTooLarge` through `core.unicode.check_len`: a 5 GiB mapping is data, as
  in core. Every error writes `diag` once; success never writes it.

| Kind | `raw` | Where | `next` checks |
|---|---|---|---|
| `object_begin`, `array_begin` | `{`, `[` | value position | depth <= `depth_max`, else `TooDeep` |
| `object_end`, `array_end` | `}`, `]` | after the opener or a member | matches the opener; no trailing comma |
| `key` | between quotes | object start, or after `,` | string rules; `:` must follow |
| `string` | between quotes | value position | UTF-8, no byte < 0x20, escapes `"\/bfnrtu`, pairs |
| `number` | literal text | value position | `-?(0\|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` |
| `literal_true` etc. | `true` `false` `null` | value position | exact spelling |
| `end` | empty | after the root value | only ` \t\n\r` follows |

A number token is the maximal run of `[0-9+\-.eE]`, judged whole: `01`, `+1`, `.5`, `1.`, `1e+`
and `-` are each one `InvalidNumber`, never a valid prefix followed by `TrailingData`.

### 2. Positions (b): `u32` byte offsets, line:col only on failure

- Every offset is `u32`. Input longer than `maxInt(u32)` or `bytes_max` is `InputTooLarge`
  before any byte is read.
- The hot loop tracks no line. On failure, `line = 1 +` the number of `\n` before the offset
  and `col = 1 +` the bytes since the last `\n`: O(offset), paid once.
- **`col` counts bytes**, 1-based. It agrees with `find_invalid` offsets and with the Zig
  compiler's own columns, and it is defined on invalid UTF-8, where a codepoint count is not.
  `\r` alone is not a line break; `\r\n` counts once.
- The offset is the first byte of the offending thing: the token, the byte, the bracket that is
  too deep, the first byte of a bad UTF-8 sequence, the `\` of a bad or unpaired escape, the
  start of an out-of-range number, the quote of a second duplicate key. `UnexpectedEnd` points
  at `input.len`, one past the last byte, so empty input is `1:1`.
- New in core, added by item 2 (TOML and YAML need it, and formats must not import each other):
  `core.diagnostics.Position = struct { line: u32, col: u32 }`,
  `position_of(input: []const u8, offset: u32) Position` (asserts `offset <= input.len`; both
  fields >= 1), and `snippet_of(input, offset) []const u8`: the failing line from
  `max(line start, offset - snippet_len_max / 2)` to the next `\n`, cut by `Diagnostics.init`.

### 3. Errors (c): one vocabulary, names shared with core and reflect

A variant that means what a core or reflect variant means has the same name, and Zig merges
same-named errors under `||`, so `TooDeep` is one error from the scanner to reflect. A core
variant that is a special case of a wider JSON error folds into it (`InvalidHex` becomes
`InvalidEscape`). One that cannot occur after the scanner has validated is absent
(`InvalidCodepoint`).

| Variant | Raised by | Same name in | When |
|---|---|---|---|
| `InputTooLarge` | init, file, writer | `core.unicode.Error` | input > `bytes_max` or `maxInt(u32)`; a string over u32 |
| `UnexpectedEnd` | scanner | — | input ends inside a value, or holds only whitespace |
| `UnexpectedToken` | scanner | — | a byte the grammar forbids here: BOM, comment, `'`, `,]`, misspelt literal |
| `TrailingData` | scanner | — | non-whitespace after the root value |
| `InvalidNumber` | scanner | — | a number run outside the §1 grammar |
| `InvalidEscape` | scanner | (`InvalidHex` folds in) | `\` + a byte outside `"\/bfnrtu`, or a non-hex digit |
| `LoneSurrogate` | scanner | `core.unicode_escape` | `\uD800` unpaired, or a lone low surrogate |
| `ControlCharacter` | scanner | — | a raw byte below 0x20 inside a string |
| `InvalidUtf8` | scanner, writer | core, `reflect.StringifyError` | text is not strict UTF-8 |
| `TooDeep` | scanner, writer | `core.value.eql`, reflect | container number `depth_max + 1` |
| `IntegerAboveMax` | DOM | `core.number` | integer > `maxInt(u64)` |
| `IntegerBelowMin` | DOM | `core.number` | integer < `minInt(i64)` |
| `FloatOutOfRange` | DOM | `core.number`, reflect | a finite literal rounds to infinity (`1e400`) |
| `DuplicateKey` | DOM | `core.Map.put` | a repeated key under `.reject` |
| `OutOfMemory` | DOM, files | everywhere | the tree arena failed |
| `Unrepresentable` | writer | — | `.bytes`, `.timestamp`, NaN, +-inf (§7) |
| `WriteFailed` | writer | `std.Io.Writer.Error` | the writer failed |

```zig
pub const ScanError = error{ UnexpectedEnd, UnexpectedToken, TrailingData, InvalidNumber,
    InvalidEscape, LoneSurrogate, ControlCharacter, InvalidUtf8, TooDeep };          // 9
pub const ParseValueError = ScanError || error{ InputTooLarge, IntegerAboveMax,
    IntegerBelowMin, FloatOutOfRange, DuplicateKey, OutOfMemory };                    // 15
pub const WriteValueError = error{ Unrepresentable, InvalidUtf8, InputTooLarge, TooDeep,
    WriteFailed };                                                                    // 5
pub const ParseError = ParseValueError || reflect.ParseError;                         // 23
pub const StringifyError = reflect.StringifyError || WriteValueError;                 // 6
pub const ParseFileError = ParseError ||
    error{ Canceled, FileNotFound, AccessDenied, ReadFailed };                        // 27
pub const StringifyFileError = StringifyError || error{ Canceled, AccessDenied, NoSpaceLeft };
pub const Error = ParseFileError || StringifyFileError; // Module convention; replaces the stub.
```

- `reflect.ParseError` folds in whole: its `FloatOutOfRange`, `TooDeep` and `OutOfMemory` merge
  with the DOM's, and its other 8 variants are added. A comptime test walks
  `@typeInfo(reflect.ParseError).error_set` and asserts each name is in `ParseError`; another
  asserts `DepthExceeded`, `NumberOutOfRange`, `ParseFailed`, `UnsupportedType` and
  `NotImplemented` are in no json set. The counts above are pinned by a comptime test too; if
  the merge yields a different number, the test and this ADR are corrected together.
- `diag` rule, as reflect's: every error return of every json entry point writes `diag` exactly
  once; success never does. Source errors get 1-based line:col and a snippet; Value errors
  (writer, `reflect.stringify`) get `position_none` and ADR-0002's `"{path}: {reason}"`; I/O
  errors get `position_none` and a reason. The caller prefixes the file name.

### 4. DOM (d): exact sizes from a counting pass, no scratch growth

```zig
// src/json/dom.zig. Copies every string; the result lives until tree.deinit().
pub fn parse(tree: *ValueTree, input: []const u8, options: ParseOptions,
    diag: *Diagnostics) ParseValueError!Value;
```

1. `bound` = the number of `[` and `{` bytes: an upper bound on containers (brackets inside
   strings only over-count). `counts = alloc(u32, bound)` from the tree arena, its newest block.
2. Pass 1: a `Scanner` validates the whole document and writes `counts[ordinal]` = child count,
   in container-begin order, through a fixed `[depth_max]` stack of open ordinals. Every syntax
   error is reported here, before any node exists.
3. `counts` shrinks in place to the real container count (`resize` of the newest allocation).
4. Pass 2: a second `Scanner` over the same bytes cannot fail (proof comment). Each container
   gets one allocation of exactly `counts[ordinal]` `Value`s, or a `tree.new_map` of that
   capacity; children go straight into their final slot under a fixed `[depth_max]` frame
   stack. Numbers go through `core.number.parse_decimal` (the §1 grammar is a subset of
   `is_decimal_literal`, asserted). A string is `alloc(raw.len)`, `decode_string`, then a shrink
   in place.

- No recursion: two fixed stacks of `depth_max` frames. The root is returned, not stored in
  `tree.root`, so one tree can hold several documents (config layers).
- **Memory, exact and testable**: arena bytes <= sum of string and key raw lengths + 32 per
  array element + 48 per object member + 4 per container, plus arena block overhead. The
  transient peak adds 4 per bracket byte, given back in step 3 and reused by step 4. Item 4
  comptime-asserts `@sizeOf(Value) == 32` and `@sizeOf(Map.Entry) == 48`, so the formula cannot
  drift silently. PRD §5's "2x" becomes this formula; item 10 records arena bytes per input
  byte.
- **Strings are copied, never borrowed from `input`**: the result has one lifetime, the tree
  (REALM.md "DOM ownership"). `parseFile` reads the file into the same arena, so it borrows
  through a private flag; that is not public API.
- If 0.16's `ArenaAllocator` cannot shrink its newest allocation in place, item 4 uses the
  exact three-scan fallback (see Alternatives); the public API does not change.

### 5. Strictness (e): RFC 8259 and nothing else

- The root may be any value, scalars included (RFC 8259 §2).
- A UTF-8 BOM is `UnexpectedToken` at 1:1 with a message naming it (§8.1 lets a parser ignore
  it; one grammar is simpler, and a caller strips it on purpose).
- No extensions: comments, trailing commas, `'`, unquoted keys, `NaN`, `Infinity`, hex, `+1`,
  and whitespace other than ` \t\n\r` are each `UnexpectedToken` or `InvalidNumber`. Bytes >=
  0x80 outside a string are `UnexpectedToken`.
- Integers past `maxInt(u64)` are `IntegerAboveMax`, below `minInt(i64)` `IntegerBelowMin`,
  never a float. `-0` is `.int = 0`; `-0.0` is `.float` with its sign bit; `1e-400` underflows
  to `0.0`; `1e400` is `FloatOutOfRange`.
- `\u0000` decodes to a NUL byte; noncharacters pass; a lone surrogate never becomes U+FFFD.

### 6. Duplicate keys and key order (f)

- `DuplicateKeyPolicy = enum { reject, last }`. The stub's `first` is dropped: no consumer
  needs it, and each variant is a permanent API with its own tests.
- `.reject`: `DuplicateKey` at the second key. `.last`: the value of the last occurrence at the
  position of the first, as JavaScript's `JSON.parse`. The slot is overwritten, so the map ends
  with `count < entries.len`, which `Map` allows; the replaced subtree stays in the arena,
  bounded by the input. New in core, added by item 4: `Map.index_of(map, key) ?u32`.
- Detection is a linear `index_of` per member, O(n^2) per object. The plan accepts it for
  configs; the bench records it.
- `sort_keys`: the writer emits members in ascending `std.mem.order(u8, ...)` of the key bytes,
  which on UTF-8 is codepoint order, by selection: each step scans the object for the smallest
  key above the last one written. No allocation, no new limit, O(n^2) compares per object; keys
  are unique by the `Map` invariant, so each step picks exactly one. It is not RFC 8785, which
  sorts UTF-16 units; nobody may treat it as a canonical form.

### 7. Writer (g): allocates nothing, refuses what cannot come back

```zig
// src/json/writer.zig
pub const Layout = union(enum) { minified, pretty: struct { indent_spaces: u8 } };
pub const StringifyOptions = struct {
    layout: Layout,       // pretty: 1 <= indent_spaces <= indent_spaces_max (8), asserted.
    sort_keys: bool,
    escape: core.unicode_escape.EscapePolicy,
    depth_max: u16,       // 1 <= depth_max <= nesting_max, asserted.
};
pub fn write(w: *std.Io.Writer, value: Value, options: StringifyOptions,
    diag: *Diagnostics) WriteValueError!void;
```

- A fixed `[depth_max]` frame stack, no recursion, no allocation; a float is formatted in a
  `float_text_len_max = 32` byte stack buffer.
- **Refused** with `Unrepresentable` and a path diagnostic: `.bytes`, `.timestamp`, NaN, +-inf.
  Each has a JSON spelling (base64, RFC 3339, `null`), but it re-parses as another `Value`, so
  round-trip would break silently. The caller converts on purpose, in a hook.
- Strings and keys go through `write_escaped(w, text, options.escape)`, which also rejects a
  hand-built non-UTF-8 string (`InvalidUtf8`) or one over u32 (`InputTooLarge`).
- `.int` and `.uint` are written in decimal. A `.uint` <= `maxInt(i64)` re-parses as `.int`,
  the canonical form of ADR-0002 §4: round-trip is `eql` for canonical Values only, so the
  property generator emits `.uint` only above `maxInt(i64)`.
- **`.float` always re-parses as `.float` with the same bits**: shortest round-trip digits,
  `{d}` when x == 0 or 1e-6 <= |x| < 1e21, otherwise `{e}`, and `.0` appended when the text has
  neither `.` nor `e`. So `0.1`, `1.0`, `-0.0`, `5e-324`, `1e300`. The switch is required:
  `{d}` of `5e-324` is over 300 bytes. Item 5's golden tests pin the exact 0.16 output.
- `minified` writes no whitespace. `pretty` puts every member and element on its own line,
  indented `indent_spaces` per level, with `"key": value` and `,` at the line end; empty
  containers stay `{}` and `[]`. `write` adds no final newline.
- New in reflect, added by item 5: `reflect.context.write_diagnostic(diag, path: *const Path,
  comptime format, args) void`, the body of `Context.write_message` made public, so writer
  messages follow ADR-0002's path grammar. The writer fills a `Path` from its frames only on
  failure.

### 8. Entry points and re-location (h, in memory)

```zig
// src/json.zig
pub const DuplicateKeyPolicy = enum { reject, last };
pub const ParseOptions = struct {
    depth_max: u16,                    // 1 <= depth_max <= nesting_max, asserted.
    bytes_max: u32,                    // input.len > bytes_max is InputTooLarge.
    duplicate_key: DuplicateKeyPolicy,
};
pub fn parse_value(tree: *ValueTree, input: []const u8, options: ParseOptions,
    diag: *Diagnostics) ParseValueError!Value;
pub fn write_value(w: *Io.Writer, value: Value, options: StringifyOptions,
    diag: *Diagnostics) WriteValueError!void;
/// Result slices live until `tree.deinit()`.
pub fn parse(comptime T: type, tree: *ValueTree, input: []const u8, options: ParseOptions,
    diag: *Diagnostics) ParseError!T;
pub fn stringify(comptime T: type, tree: *ValueTree, w: *Io.Writer, value: T,
    options: StringifyOptions, diag: *Diagnostics) StringifyError!void;
```

- ADR-0001's order holds, and `diag` is always the last parameter, after `options`: it is an
  out-parameter, as in reflect. `deny_unknown_fields` leaves `ParseOptions`; it lives on `T`.
- Re-location, added by item 8. Reflect gains `parse.parse_traced(T, tree, value, diag,
  trace: *Path)` and `Context.trace: ?*Path` (null from `parse`); the first message write
  copies the live path into it. `scanner.locate(input, options, path) u32` walks a `Scanner`
  along it: `.index` counts elements, `.none` descends nowhere, `.key` matches the last
  occurrence by decoded comparison (`scanner.raw_eql(raw, has_escapes, key) bool`, item 8),
  keeping a `Scanner` copy at each match. It stops at the deepest segment it finds, since a
  hook's synthetic segment has no source, so it is total; O(input), at most `depth_max` deep.
  `parse` then overwrites `diag.line`/`col` and the snippet and keeps the message.
  `MissingField` and `UnknownField` land on the object's `{`, because the path names the struct.

### 9. Files, and the amendment to ADR-0001 (h)

```zig
pub fn parseFile(comptime T: type, io: Io, arena: Allocator, dir: Io.Dir,
    sub_path: []const u8, options: ParseOptions, diag: *Diagnostics) ParseFileError!T;
pub fn stringifyFile(io: Io, arena: Allocator, dir: Io.Dir, sub_path: []const u8,
    value: anytype, options: StringifyOptions, diag: *Diagnostics) StringifyFileError!void;
```

- **`diag` joins both, as the seventh and last parameter.** Without it a malformed file fails
  without line:col, against REALM.md "no position-less parse errors"; the stub's own comment
  already promised it.
- **`stringifyFile` takes `arena`, not `scratch: []u8`**; `scratch_bytes_min` is deleted.
  `reflect.stringify` builds a `ValueTree`, so "allocates nothing" was unreachable for any `T`.
  A caller who wants a hard bound passes a `FixedBufferAllocator` as `arena`, and
  `OutOfMemory` then means the bound was hit. The file writer's 4 KiB buffer comes from the
  same arena. `write_value` itself still allocates nothing.
- `parseFile` reads `sub_path` into `arena` (`bytes_max` exceeded is `InputTooLarge`), maps I/O
  errors by hand to the four names (ADR-0001 §4), and parses with a `ValueTree` over `arena`
  that is never deinitialized, as `config.load` does. `stringifyFile` creates or truncates the
  file, writes, appends one `\n`, and flushes; it is not atomic. Item 9 pins the exact 0.16
  `Io.Dir` read/write calls.
- The parity test in `src/root.zig` changes with item 9: 7 parameters, `params[2]` is
  `std.mem.Allocator` in both, the last is `*core.Diagnostics`. `json.Error` loses
  `NotImplemented`. `config.LoadError` (`ParseFailed`, `deny_unknown_fields`) is not amended
  here; Phase 5 aligns it with this vocabulary.

## Consequences

- TOML and YAML copy §1-§3 (slice scanner, `u32` offsets, byte columns, shared names) and use
  core's `position_of`/`snippet_of`; only their token kinds differ.
- A consumer's `switch` over `json.ParseError` is closed at 23 variants. `IntegerOutOfRange`
  (reflect, narrowing into `T`) and `IntegerAboveMax` (DOM, past u64) are close in name and
  different in meaning; the doc comments say which layer raises which.
- The DOM scans its input twice. Syntax errors cost no tree memory and every container is one
  exact allocation; the price is one extra scan. A tuning plan may fuse the passes, but this
  contract does not change.
- DOM memory has a formula instead of a ratio, and PRD §5 says so. Small-number arrays cost
  about 16x their text: that is the price of a 32-byte `Value`, not of the parser.
- Errors in reflect land on the value's first token, not on the exact byte; `UnknownField`
  lands on the object, not on the key. Pointing at the key is an additive refinement.
- `stringifyFile` goes through a tree, so it needs memory proportional to the value. 2D's
  direct writer removes the tree, not the parameter.
- A file write that fails part way leaves a partial file. Atomic replace is a later, additive
  option.
- Plan 004's risks are settled: `TooDeep`, not `DepthExceeded`; floats always carry `.0` or an
  exponent; reflect's frozen `trace` is the additive `Context` change the plan foresaw.

## Alternatives

- **Scratch stack for DOM children** (push, copy out at the container end). One scan, but its
  peak is the widest container and it grows during the parse; in the tree arena the old buffers
  are never freed, and a separate `gpa` breaks ADR-0001's single `arena`.
- **Look-ahead count per container** (copy the scanner, skip to the matching bracket). No
  memory, but O(input x depth): 128x on hostile input.
- **Exact container count by a third scan** instead of the bracket bound. No transient, one
  more scan; the fallback if 0.16's `ArenaAllocator` cannot shrink its newest allocation.
- **Codepoint or UTF-16 columns.** Undefined on invalid UTF-8 and O(line) per report; editors
  convert from the snippet.
- **One `ParseFailed` for all syntax errors** (stub). It hides the cause from a `switch`, and
  plan items 2-3 test each cause separately.
- **Accepting a BOM, comments or trailing commas.** Each is a second grammar to fuzz and
  document; JSONC would be its own module.
- **Large integers as floats.** Silent loss of digits breaks REALM.md "Numeric exactness".
- **A `.first` duplicate policy.** Nobody needs it; `last` matches JS, Go and Python.
- **Sorting keys through an index array.** Needs scratch memory or a key-count limit; the
  selection walk needs neither and is as fast for config-sized objects.
- **Writing `.bytes` as base64.** It re-parses as `.string`; round-trip breaks silently.

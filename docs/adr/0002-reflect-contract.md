# ADR-0002 — the `reflect` contract: hooks, errors, diagnostics, coercion, shapes

- Status: accepted
- Date: 2026-10-01
- Plan item: `docs/plans/003-phase-1cd-unicode-reflect.md` item 3 (design only)
- Amends: `docs/PRD.md` §4.2 (same PR)

## Context

`reflect` maps a Zig type `T` to a `core.Value` and back at comptime. Every format module
(Phase 2-4) and `config.load` (ADR-0001) calls it, and every consumer's config types and
`sigilParse`/`sigilStringify` hooks are written against it. That makes the hook signature,
the error set, the diagnostics shape and the Value shape of each Zig type one-way doors.
Changing any of them later breaks code in other repositories.

Forces:
- `Value` carries no source positions, but REALM.md says "Diagnostics are first-class". The
  merged `Diagnostics` stores a message in a fixed 256-byte buffer and truncates the tail with
  `"..."`.
- REALM.md "Numeric exactness": `.int`/`.uint`/`.float` stay distinct, and nothing converts
  int to float silently. `number.parse_integer` gives `.int` unless the value is above
  `maxInt(i64)`.
- REALM.md "DOM ownership": what reflect returns lives in the `ValueTree`. Tiger Style §1.9
  and §3.8: store no allocator, and name memory by who frees it.
- Reflection recurses at run time over data (`struct { children: []Node }`). Tiger Style
  §1.8 bans recursion. §4.2 accepts it only with an explicit, asserted bound, as in PR #19.
- PRD §4.2 names `std.StringHashMap`. In 0.16 that type stores its allocator and loses
  insertion order, so it breaks TOML/YAML round-trips.

## Decision

### 1. Entry points and hooks: the `*ValueTree` is the only memory, reached through `Context`

```zig
pub const ParseError = error{
    TypeMismatch, IntegerOutOfRange, InexactNumber, FloatOutOfRange, UnknownEnumValue,
    MissingField, UnknownField, LengthMismatch, InvalidValue, TooDeep, OutOfMemory,
};
pub const StringifyError = error{ InvalidUtf8, InputTooLarge, TooDeep, OutOfMemory };
pub const Error = ParseError || StringifyError; // Module convention; replaces the stub.

/// Result slices borrow from `value` or were allocated from `tree`; both die at
/// `tree.deinit()`. Precondition: `value` belongs to `tree` or outlives it.
pub fn parse(comptime T: type, tree: *ValueTree, value: Value, diag: *Diagnostics)
    ParseError!T;
/// Every string, key and container of the result is copied into `tree`.
pub fn stringify(comptime T: type, tree: *ValueTree, value: T, diag: *Diagnostics)
    StringifyError!Value;

pub const Segment = union(enum) { key: []const u8, index: u64, none };
pub const Context = struct {
    tree: *ValueTree,        // Hooks allocate here: `tree.arena.allocator()`.
    diag: *Diagnostics,      // Reflect-owned below this line; hooks read `tree` only.
    path: *Path,             // `[nesting_max]Segment` plus `count: u32`, on parse's stack.
    depth: u32,              // Invariant: path.count <= depth <= nesting_max.
    diag_written: bool,
    pub fn parse_child(context: *Context, comptime U: type, segment: Segment,
        value: Value) ParseError!U;
    pub fn stringify_child(context: *Context, comptime U: type, segment: Segment,
        value: *const U) StringifyError!Value;
    pub fn fail(context: *Context, err: ParseError, comptime format: []const u8,
        args: anytype) ParseError;
};

// Declared on T (struct, enum or union). Checked at comptime by exact type equality.
pub fn sigilParse(context: *reflect.Context, value: Value) reflect.ParseError!T;
pub fn sigilStringify(self: *const T, context: *reflect.Context)
    reflect.StringifyError!Value;
```

- **Why `*ValueTree`, not a bare `allocator`.**
  - A hook's result then has the same one lifetime as everything else reflect returns.
  - A failed parse leaves garbage in the arena, and `deinit` frees it. There is no `errdefer`
    chain per slice.
  - The parameter says who frees (§3.8). An `allocator` parameter invites a `gpa` whose frees
    never happen.
  - Stringify hooks get `new_map`/`dupe_*`, which keep the `Map` invariants.
  - `config.load(T, io, arena, ...)` stays compatible: it backs a `ValueTree` with its `arena`
    and never calls `deinit`.
- **Why a `Context` and not `(tree, value, diag)`.** A hook that parses sub-values through
  the public `parse` would start again at depth 0. A recursive type that passes through a hook
  would then recurse without bound on a hand-built `Value`. `parse_child`/`stringify_child`
  continue the path and the depth. Each call counts as one level even when it does not
  descend, so a hook that re-parses its own value hits `TooDeep`, not a stack overflow. A
  struct can also gain fields later without breaking any hook. Four positional parameters
  cannot.
- **`sigilStringify` returns a `Value`.** Reflect never sees a writer. Formats own bytes, and
  `.int` vs `.uint` vs `.float` survives into every format unchanged.
- **Hook errors.** A hook returns reflect's error set and nothing else. Its specifics go in
  the message, so a consumer's exhaustive `switch` stays closed. A hook fills `diag` in one of
  two ways:
  - Through `context.fail(err, fmt, args)`, which writes `"{path}: {reason}"` and returns
    `err`.
  - Through a failing `parse_child`/`stringify_child`, which has already written `diag`.

  If a hook returns an error while `diag_written` is still false (for example a bare
  `OutOfMemory` from `tree.dupe_string`), reflect writes `"{path}: sigilParse of {T} failed:
  {errorName}"`. Every error return writes `diag` exactly once. Success never writes it.
- **Pairing.** A type declares both hooks or neither, otherwise it is a `@compileError`.
  Round-trip is a REALM.md property, and relaxing this later is additive. A type with hooks
  must not also declare `sigil_options`, because the options would be dead.

### 2. Error variants

Each variant has at least one test that provokes it.

| Variant | Raised when |
|---|---|
| `TypeMismatch` | Value tag not accepted by `T`. This includes `.float` into an int, `.null` into a non-optional, `.bytes` into `[]const u8`, and a union in the wrong shape. |
| `IntegerOutOfRange` | `.int`/`.uint` outside `T`'s range (narrowing, negative into unsigned). |
| `InexactNumber` | `.int`/`.uint` into a float with a magnitude above the exact-integer bound (§4). |
| `FloatOutOfRange` | A finite `.float` whose magnitude rounds to infinity in `f32`. Same meaning as `number.FloatError`. |
| `UnknownEnumValue` | A string names no enum member, or no tag of a tagged union. |
| `MissingField` | A struct field has no default and its wire name is absent. |
| `UnknownField` | A map key matches no field while `deny_unknown_fields` is on. |
| `LengthMismatch` | `.array` length differs from `N` in `[N]T`. |
| `InvalidValue` | A hook rejected the content of a value whose shape is correct (`"5x"` as a duration). Only hooks raise it. |
| `TooDeep` | Entering container number `nesting_max + 1`, or hook child call number `nesting_max + 1`. |
| `OutOfMemory` | The tree arena failed (slices, string maps, stringify copies). |
| `InvalidUtf8` | Stringify: a `[]const u8` or string-map key is not valid UTF-8 (`core.unicode.find_invalid`). It never becomes a silent `.bytes`. |
| `InputTooLarge` | Stringify: a string or map is longer than `maxInt(u32)`, core's offset and count width (`unicode.check_len`). Tested with a slice whose length is never read. |

`Map.put`'s `DuplicateKey`/`OutOfSpace` cannot happen in stringify. Maps are sized exactly,
and keys are unique by the comptime check or by the hash map. These are proof-commented
`catch unreachable`, not variants.

### 3. Diagnostics: path only, upgraded by the format layer

- `line = col = 0` means "no source position; the message carries the key path". This value
  is `core.diagnostics.position_none: u32 = 0`, added in item 5. Format parsers keep
  positions 1-based, so 0 is never ambiguous. `format()` is unchanged and renders
  `0:0: servers[2].host: ...`.
- Message grammar: `"{path}: {reason}"`, or just `"{reason}"` at the root. In the path:
  - The first key is written bare; later keys get a leading `.`; indices are written `[n]`.
  - A key that is empty or not `[A-Za-z0-9_-]+` is written `["k"]`.
  - Inside a quoted key, `"`, `\`, bytes below 0x20 and 0x7f are escaped as `\"`, `\\` and
    `\xNN`.
  - `.none` segments render nothing.

  Examples: `tls.cert`, `servers[2].host`, `labels["a.b"]`. The path prefix is the contract.
  The reason text is not.
- The message never overflows and is never cut silently:
  - The reason is formatted first into a buffer of `reason_len_max = 128` bytes. If it is
    longer, its tail is cut and `truncation_marker` is appended.
  - The path gets the remaining budget, `message_len_max - reason.len - 2` bytes. A longer
    path keeps its tail, the most specific segments, behind a leading `truncation_marker`
    (`...[7].host: expected string, found int`).

  The total stays within `message_len_max`, so `Diagnostics.init` never truncates the
  message again. Reflect takes the default `*Diagnostics` only.
- Phase 2 upgrade: an additive `reflect` entry reports the failing `Path` structurally. The
  format module (`json.parse(T, ...)`) then re-scans its source with its pull scanner, walks to
  that path, and overwrites `line`/`col` with the node's 1-based position. The message keeps
  the path. This costs O(input) on failure only. Phase 2D's direct streaming path fills
  positions natively.

### 4. Numeric coercion

| Into | From `.int`/`.uint` | From `.float` |
|---|---|---|
| `iN`/`uN`, N <= 64 (`usize` included) | `std.math.cast`; a miss is `IntegerOutOfRange`. A non-canonical small `.uint` (CBOR) is accepted. | Never: `TypeMismatch`, even `3.0`. |
| `f64` | Exact iff `\|n\| <= f64_integer_exact_max = 1 << 53`, else `InexactNumber` | as is |
| `f32` | Exact iff `\|n\| <= f32_integer_exact_max = 1 << 24`, else `InexactNumber` | `@floatCast`, nearest-even. Finite to inf is `FloatOutOfRange`; NaN and inf pass through. |

- The integer bound is a range rule, not a representability rule: `2^54` is rejected into
  `f64` although it is representable. A range has no holes, so a config author can predict it.
- A decimal read into `f32` is rounded twice (text to f64 to f32). This is documented, and
  Phase 2D reads f32 directly.
- Stringify: signed types become `.int`. Unsigned values `<= maxInt(i64)` become `.int` and
  larger ones `.uint`, the canonical form of `number.parse_integer`. `f32`/`f64` become
  `.float`, and f32 widening is exact.
- Guarantees: `parse(stringify(x)) == x` for every supported `x`. `stringify(parse(v))` is
  `eql` to `v` when `v` is canonical.

### 5. Shapes

| Zig type | Value | Notes |
|---|---|---|
| `bool` | `.bool` | No `"true"` strings, no 0/1. |
| `[]const u8` | `.string` | Parse borrows from the tree with no copy and no re-validation. Stringify checks UTF-8, then `dupe_string`. |
| `enum` (exhaustive) | `.string` (wire name) | Integers are `TypeMismatch`. Stringify emits the static comptime name. |
| `?T` | `.null` or `T`'s shape | An explicit `.null` gives `null`. A missing field is `MissingField` unless the field has a default (`= null`). Stringify always emits `.null`, so re-parsing a field without a default works. |
| `struct` (auto/extern) | `.map` | Fields are looked up through the options table. With deny on, unknown keys are checked first, in map order, then fields in declaration order: a typo reports `UnknownField` before `MissingField`. Stringify emits every field, in declaration order. |
| `union(enum)` | Void variant: `.string` tag. Otherwise: single-entry `.map` `{tag: payload}` | Externally tagged, and each variant has exactly one shape. A map with count != 1, `{void_tag: x}`, or a bare string naming a payload variant is `TypeMismatch`. The payload path segment is the tag. |
| `[N]T` | `.array`, len N | Otherwise `LengthMismatch`. `[N]u8` is an array of ints. |
| `[]const T`, `[]T` (T != u8) | `.array` | One allocation of exactly `array.len` from the tree arena. |
| `std.array_hash_map.String(V)` | `.map` | `.empty`, then `ensureTotalCapacity(arena, map.count)` once, then `putAssumeCapacityNoClobber` in map order. Keys are borrowed. Read-only; the tree frees it, never `deinit(gpa)`. Stringify copies keys and checks their UTF-8. |
| `core.Timestamp` | `.timestamp` | Special-cased, not reflected as a struct. |
| `core.Value` | as is | Parse borrows. Stringify deep-copies into the tree with the same depth bound, so the one lifetime rule holds. |

- Depth: each container entered and each hook child call adds one level. Entering past
  `core.value.nesting_max` (128) is `TooDeep`, the same boundary as `core.value.eql`: 128
  nested containers pass, 129 fail.
- Recursion is comptime-generic, with the depth argument asserted. The path is an explicit
  `[nesting_max]Segment` stack. Worst-case machine stack is 128 bounded frames.
- Unsupported, each a `@compileError` naming the type:
  - pointers other than the slices above: `*T`, `[*]T`, `[*c]T`, `[]u8`, and sentinel slices
    and arrays;
  - ints wider than 64 bits, floats other than f32/f64, `comptime_int`/`comptime_float`;
  - untagged, packed and extern unions; packed structs; tuples; `comptime` fields;
  - non-exhaustive enums; `??T`;
  - `void` outside union payloads, `type`, `noreturn`, `anyopaque`, opaques, fns, error sets
    and error unions, `@Vector`;
  - `std.StringHashMap` and `array_hash_map.Auto`/`Custom`.
- A hook is the escape hatch for anything unsupported.

### 6. `sigil_options` (input to `reflect/options.zig`)

```zig
pub const sigil_options = .{
    .rename = .{ .name = "server_name" },   // Zig field or tag -> wire name.
    .rename_all = .kebab_case,              // Applies to names not in .rename.
    .deny_unknown_fields = false,           // Structs only; absent means true.
};
```

- `rename`: an anonymous struct of comptime strings keyed by existing field or tag names.
- `rename_all`: one of `.snake_case` (identity, validates), `.camel_case`, `.pascal_case`,
  `.kebab_case`, `.screaming_snake_case`. It needs every name it touches to match
  `[a-z][a-z0-9]*(_[a-z0-9]+)*`; any other name needs an explicit `rename`.
- `deny_unknown_fields: bool` defaults to `true`, as in `std.json`. A mistyped config key
  fails loudly, and leniency is written out at the type.
- Defaults come only from Zig field default values. No option key supplies them.
- Scope: `rename` and `rename_all` apply to structs, enums and tagged unions.
  `deny_unknown_fields` applies to structs only.
- Each of the following is a `@compileError`:
  - an unknown key;
  - a key whose value has the wrong type;
  - `rename` of a missing name;
  - two names landing on one wire name;
  - `deny_unknown_fields` on an enum or union;
  - options on a type that also declares hooks.

## Consequences

- Hooks, error sets, the diagnostic grammar and every shape above are fixed before any reflect
  code lands. Items 4-8 implement against this file, and PRD §4.2 now matches it.
- A consumer's `switch` over `ParseError` is closed at 11 variants. A hook cannot widen it,
  and domain detail lives in the message.
- Reflect-level errors carry a path, not a position, until Phase 2 re-locates them. A
  `0:0:` prefix in a message means reflect produced it directly.
- Stringify copies strings, so a stringified `Value` never aliases the caller's `T`. The cost
  is one `memcpy` per string on a path that Phase 2D bypasses for speed.
- TOML has no null. Fields that may be null in TOML documents should declare `= null`,
  because the Phase 3 writer drops `.null` entries.
- `deny_unknown_fields` defaults on, so an older binary rejects a newer config that has extra
  keys until the type opts out. This is intended.
- std containers other than `array_hash_map.String` are not recognised. For example,
  `std.ArrayList` would reflect field-wise, which is wrong. Use `[]T`. The options tests cover
  this.
- Plan 003 item 8's sketched signature gains `diag`, and core gains `position_none` and a
  `ValueTree.clone_value` helper (for `Value` fields).

## Alternatives

- **Hooks as `(tree: *ValueTree, value, diag)` / `(self, tree)`.** Fewer names. Rejected:
  - depth restarts inside hooks, so recursive types through hooks are unbounded;
  - the path is lost across a hook;
  - adding a parameter later breaks every hook in every consumer.
- **Hooks taking an `allocator`.** Hides who frees, and ties a result to a second lifetime.
- **One error set for both directions.** Stringify callers would switch over six impossible
  variants.
- **Internally tagged unions (`{"type": "tcp", ...}`).** Works only for struct payloads, and
  reserves a key that fields can collide with. Adjacently tagged (`{tag, value}`) is noisier
  in TOML. Rejected in favour of the externally tagged form.
- **`{"auto": null}` for void variants.** TOML cannot express it.
- **Int to float whenever representable.** The accepted set has holes above 2^53, and nothing
  predicts it from the text.
- **Float to int when integral (`3.0` into `u8`).** It hides the type of a config value and
  breaks `.int`/`.float` distinctness.
- **Absent `?T` meaning null.** It is an implicit default. `= null` is the one way to say it.
- **Truncating the path's tail with plain `Diagnostics.init`.** It would drop the reason,
  which is the most useful part.
- **`std.StringHashMap` (PRD).** It stores its allocator (§1.9) and has no order, so
  round-trip breaks.

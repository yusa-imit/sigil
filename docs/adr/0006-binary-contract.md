# ADR-0006 — the binary-format contract: MessagePack and CBOR over `core.Value`

- Status: accepted
- Date: 2026-10-30
- Plan item: `docs/plans/007-binary-formats.md` item 1 (design only)
- Amends: `docs/PRD.md` §4.3 MessagePack and CBOR rows; replaces the `msgpack.zig` and `cbor.zig`
  stub `Error = error{NotImplemented}`; `reflect` gains `sigil_options.bytes` (§9)
- Extends: ADR-0003 §1-§4 (pull reader, positions, error vocabulary, exact sizing), ADR-0005 §2
  (`Timestamp.Kind`), ADR-0002 §6 (`sigil_options`)

## Context

MessagePack and CBOR are closed binary grammars with official vectors. They raise the same four
questions the text formats did, and both are one-way doors from v0.6.0 (synod will `switch` over
these error sets and hash the encoder's bytes):

- Their maps may have any item as a key; `core.Map` keys are strings.
- Their integers carry a width and a signedness that `Value` collapses into `int` and `uint`.
- Both carry a lengths-first header: a declared count is attacker-controlled and says nothing
  about how many bytes follow (`0xdd ffffffff` is a 4-billion-element array in 5 bytes).
- Both have an extension mechanism (msgpack ext, CBOR tags) and a time type that must meet
  `core.Timestamp`.

CBOR adds indefinite lengths (no count in the header) and a deterministic encoding (RFC 8949
§4.2.1) that the kingdom wants as an option.

Forces: `Value` is 32 bytes, `Map.Entry` 48 (ADR-0003 §4); tidy bans `usize` in format dirs, so
offsets are `u32`; Tiger Style §1.7-§1.9 (limits, no recursion, no allocation after setup);
REALM "DOM ownership" (one lifetime, the tree) and "numeric exactness".

## Decision

### 1. Layout and names

```
src/msgpack.zig          facade: options, parse_value / parse / write_value / stringify
src/msgpack/decoder.zig  Reader (pull, zero-copy tokens) and the tree build
src/msgpack/encoder.zig  writer
src/cbor.zig             facade, same shape
src/cbor/decoder.zig     Reader, counting pass, tree build, tags
src/cbor/encoder.zig     writer, preferred and deterministic forms
```

`msgpack/` and `cbor/` import `core/` and `reflect/` only, never `json/` or each other (REALM
sibling rule). Test-only runners are in §10. `DuplicateKeyPolicy` moves to `core.value`
(`core.DuplicateKeyPolicy`, `enum { reject, last }`, semantics of ADR-0003 §6) and `json.zig`
re-exports it under the same name, so no consumer sees a change.

### 2. The `Value` mapping (a)

| Wire item | `Value` | Notes |
|---|---|---|
| msgpack nil / CBOR null (`0xf6`) | `null` | |
| false / true | `bool` | |
| non-negative integer | `int` up to `maxInt(i64)`, else `uint` | any width: the head width is not kept |
| negative integer | `int` | CBOR `-1 - n` below `minInt(i64)` is `IntegerBelowMin` |
| msgpack float 32/64, CBOR f16/f32/f64 | `float` | widening is exact; NaN keeps its bits |
| msgpack str, CBOR text | `string` | strict UTF-8 (`core.unicode.find_invalid`) or `InvalidUtf8` |
| msgpack bin, CBOR byte string | `bytes` | |
| array / map | `array` / `map` | map keys: §3 |
| msgpack ext -1, CBOR tags 0, 1 | `timestamp`, kind `instant` | §4 |
| CBOR tags 2, 3 | `int` or `uint` | §4 |
| other ext / tags / simple values | typed error | §4 |

- **The one normalization.** `uint` is produced only above `maxInt(i64)`. The decoder never
  returns `.uint` for a value an `i64` holds, so a tree with `.uint = 5` encodes to the byte `05`
  and decodes to `.int = 5`. The round-trip law is therefore exact: for every tree in which
  `.uint` is above `maxInt(i64)` (the *normal form*), `decode(encode(v))` is `eql` to `v`, and
  `encode(decode(b))` is byte-identical to `encode(v)`. The seeded property (plan item 9)
  generates normal-form trees, and a separate test pins `.uint = 5` -> `.int = 5`.
- Width is not kept (`0xcc 05` decodes as `.int = 5`); a decoder never rejects a non-shortest
  integer or float, including in CBOR (the deterministic rule is for the encoder, §7).
- NaN: the decoder keeps the payload bits it reads (f16 and f32 widen with the payload shifted
  left); the encoder writes the one quiet NaN (§6), so `eql` (bitwise float equality, ADR-0003
  §3) holds for trees the encoder wrote and read back.
- CBOR `undefined` (`0xf7`) and every other simple value is `UnsupportedSimple` (§4).

### 3. Map keys and duplicates (b)

- A key must decode to `string` (msgpack str, CBOR text, definite or indefinite). Any other
  item in key position is `NonStringKey` at the key's initial byte. CBOR keys that are tagged
  text are `NonStringKey` too. No stringification of integer keys: it would make two keys collide
  silently.
- Duplicates follow `core.DuplicateKeyPolicy`: `.reject` is `DuplicateKey` at the second key's
  initial byte; `.last` overwrites the slot of the first occurrence, so the map ends with
  `count < entries.len` (allowed by `Map`). Detection is `Map.index_of`, linear per member,
  O(n^2) per map, as ADR-0003 §6 accepted for JSON; the benchmark records it.
- Key order is wire order. Every tree the decoder builds satisfies `Map.check_invariants`.

### 4. Extensions, tags and time (c)

**MessagePack ext.** Type -1 is the timestamp; every other ext type is `UnsupportedExt` at its
head. Lengths and forms (big-endian):

| Form | Data | Value |
|---|---|---|
| ext 4 (`d6 ff`) | u32 seconds | `instant`, nanoseconds 0 |
| ext 8 (`d7 ff`) | u64 = nanoseconds (30 bits) << 34 \| seconds (34 bits) | nanoseconds > 999,999,999 is `InvalidTimestamp` |
| ext 12 (`c7 0c ff`) | u32 nanoseconds, i64 seconds | same range check |

Any other length with type -1 is `InvalidTimestamp`. `offset_minutes` is null: the wire holds
an instant, not a zone.

**CBOR tags.** Tags 0-3 only; any other tag is `UnsupportedTag` at the tag's head (the tagged
content is not decoded).

- Tag 0: content must be a text string, parsed by `core.timestamp.parse`; the result must be
  kind `instant` (a local kind, a bad calendar field or content of another major type is
  `InvalidTimestamp`). The written offset is kept.
- Tag 1: content an integer (any `i64`; a `uint` above `maxInt(i64)` is `InvalidTimestamp`) or a
  float. A float must be finite and within `i64`; `seconds = floor(f)`, `nanoseconds` = the
  fraction times 1e9 rounded half to even, with a carry into `seconds` when it rounds to 1e9.
  The result is `instant` with `offset_minutes` null.
- Tag 2 (unsigned bignum) and 3 (negative bignum): content a byte string; leading zero bytes
  are skipped; more than 8 significant bytes is `IntegerAboveMax` (tag 2) or `IntegerBelowMin`
  (tag 3); otherwise `n` is the big-endian value, tag 2 yields `n` and tag 3 yields `-1 - n`,
  through the §2 rule (`int` when an `i64` holds it, `uint` only above). A tag 3 value below
  `minInt(i64)` is `IntegerBelowMin`. So 2^64-1 is accepted and 2^64 refused, and -2^64 refused.
- Tag content of the wrong major type is `InvalidTimestamp` for tags 0 and 1 and `InvalidTag`
  for tags 2 and 3. Tags may nest (`c2 c2 41 01` is `InvalidTag`); each is a level (§5).

**Simple values.** `false`, `true`, `null` map as in §2. `undefined` and every other simple
value (0-19, 32-255) are `UnsupportedSimple`; two-byte simple values below 32 (`f8 00`..`f8 1f`)
are `NotWellFormed` (RFC 8949 §3.3).

### 5. Limits and the bomb rule (e)

- **Depth.** `depth_max` is 1..`core.value.nesting_max` (128) and counts *levels including the
  root*: every array, map and tag adds one. A tag around a scalar is a level, so a root tagged
  scalar needs `depth_max >= 2`. 128 levels pass, 129 are `TooDeep`, pointing at the head that
  opens level 129. Both readers keep a fixed `[nesting_max]Frame` stack; no recursion.
- **Input.** `bytes_max` is a `u32` and at most `input_len_max = maxInt(u32) - 1`, so
  `col = offset + 1` cannot overflow; longer input is `InputTooLarge` before any byte is read.
- **Declared sizes are checked against the bytes left before anything is allocated or
  counted.** In `u64` arithmetic, with `remaining = input.len - (offset after the head)`:
  a string, byte string, bin or ext of declared length `len` needs `len <= remaining`; an array of
  `n` elements needs `n <= remaining` (one byte per element at least); a map of `n` entries
  needs `2 * n <= remaining`. Failure is `UnexpectedEnd` at the item's initial byte. A 64-bit CBOR
  length that does not fit `u32` fails this check by construction, so no length is narrowed
  unchecked. Consequence: arena bytes for a definite container are at most 32 per input byte
  for arrays and 24 per input byte for maps, never a function of a declared number alone, and
  the fuzz entry (plan item 9) asserts arena bytes are linear in input bytes.
- **Trailing bytes.** The decoders read exactly one item; bytes after it are `TrailingBytes`
  at the first extra byte. (A stream of items is a caller loop over slices.)

### 6. Encoder policy (d)

Fixed policies, no options (an option would be a permanent API with its own tests).

- **Integers: the shortest head.** msgpack: positive fixint, uint 8/16/32/64; negative fixint,
  int 8/16/32/64; a non-negative `int` uses the unsigned forms. CBOR: major 0 or 1, the
  shortest of the inline value and 1/2/4/8 extra bytes. `.uint` is written unsigned.
- **Floats: the shortest width that keeps the value exactly.** msgpack: float 32 (`ca`) when
  `@as(f64, @as(f32, x)) == x` bitwise, else float 64 (`cb`); CBOR: f16, f32 or f64 by the same
  test (preferred serialization, RFC 8949 §4.1), `inf` and `-inf` as f16, `-0.0` kept (sign bit),
  subnormals only when exactly representable. **NaN** of any payload or sign is written as the
  one quiet positive NaN: msgpack `ca 7fc00000`, CBOR `f9 7e00`.
- **Strings** are written as str / text after `core.unicode.find_invalid` (`InvalidUtf8` on
  failure, `w` untouched for that item); `.bytes` as bin / byte string. msgpack uses the
  shortest str form (fixstr, str 8/16/32) and bin 8/16/32; CBOR the shortest definite head.
- **Containers** use the shortest array / map head. CBOR never writes an indefinite length.
- **Timestamps.**
  - msgpack: only `instant` with `offset_minutes == null`. Seconds in `0..2^32-1` and
    nanoseconds 0 use ext 4; seconds in `0..2^34-1` use ext 8; everything else ext 12.
    A non-null offset cannot come back, so it is `Unrepresentable` (the caller normalizes to
    UTC, which is their decision, not the library's); likewise every local kind.
  - CBOR: `instant` with a non-null offset is tag 0 with `core.timestamp.format` text. A null
    offset with nanoseconds 0 is tag 1 with the integer. A null offset with nanoseconds != 0
    is tag 1 with an f64 *only if decoding that float returns the same seconds and nanoseconds*
    (§4), else `Unrepresentable`; around 2^31 seconds an f64 keeps roughly 200 ns, so this holds
    only for coarse fractions. Local kinds are `Unrepresentable`.
- **Other refusals** (`Unrepresentable`): a string, byte string, array or map whose length
  exceeds `maxInt(u32)` in msgpack (CBOR carries 64-bit lengths and has no such limit). Every
  `.null`, `.bool`, `.int`, `.uint`, `.float`, `.string`, `.bytes` within those limits is
  representable. More levels than `depth_max` is `TooDeep`.

### 7. CBOR deterministic encoding (g)

`StringifyOptions.deterministic: bool` (no default). Preferred serialization and definite lengths
are always on (§6), so the flag changes exactly one thing: **map keys are written sorted by the
bytewise lexicographic order of their encoded form** (RFC 8949 §4.2.1). Every key is a text
string, whose encoded form is its head followed by its bytes; heads grow with length, so the
order is *shorter key first, equal lengths by `std.mem.order(u8, ...)`*. Sorting is by repeated
selection, as ADR-0003 §6 does for `sort_keys`: each step scans the map for the smallest key
above the last one written, no allocation, O(n^2) compares per map, unique keys by the `Map`
invariant. Two insertion orders of one map therefore give identical bytes, and the bytes of a
deterministic encode are a wire surface from v0.6.0: a change to them is a breaking change
(`citadel/protocol/VERSIONING.md`), recorded in the realm memory `architecture.md` Formats.
msgpack has no deterministic option in v0.6.0 (its spec defines none); `msgpack` maps are written
in insertion order.

### 8. Errors (ADR-0003 §3 vocabulary)

`msgpack.ParseValueError`, 11 variants (a comptime test pins count and members): `InputTooLarge`,
`UnexpectedEnd`, `ReservedByte` (only `0xc1`), `InvalidUtf8`, `TooDeep`, `NonStringKey`,
`DuplicateKey`, `UnsupportedExt`, `InvalidTimestamp`, `TrailingBytes`, `OutOfMemory`.

`cbor.ParseValueError`, 17 variants: `InputTooLarge`, `UnexpectedEnd`, `NotWellFormed` (additional
info 28-30, simple `f8` below 32), `UnexpectedBreak` (a `break` outside an indefinite item, or
where a definite container is still counting), `InvalidIndefinite` (an indefinite string chunk of
another major type or itself indefinite, or a `break` after a map key), `InvalidUtf8`, `TooDeep`,
`NonStringKey`, `DuplicateKey`, `UnsupportedTag`, `UnsupportedSimple`, `InvalidTimestamp`,
`InvalidTag` (tag 2 or 3 over a non-byte-string), `IntegerAboveMax`, `IntegerBelowMin`,
`TrailingBytes`, `OutOfMemory`.

`ParseError = ParseValueError || reflect.ParseError`. `WriteValueError =
core.unicode_escape.WriteError || error{ Unrepresentable, TooDeep }` for both formats (5
variants, as `json.writer`); `StringifyError = reflect.StringifyError || WriteValueError`.

**Positions (h).** The unit is the byte offset, shown through the existing `Diagnostics`
shape without change: `line = 1`, `col = offset + 1`, where `offset` is the initial byte of the
offending item (the head byte, or the tag's head for tag errors; a bomb failure names the
container's head; `TrailingBytes` the first extra byte; `UnexpectedEnd` the head of the item that
could not be completed). The message names the byte offset in decimal and the reason, so a
reader sees `byte 17` where JSON sees `2:4`. Reflect failures (`TypeMismatch`, `MissingField`)
are re-located the way `json.parse` does it (ADR-0003 §8): `reader.locate(input, options, path)`
walks the item starting offsets along the path and, on a miss, falls back to 1:1.

### 9. CBOR indefinite lengths and the build (f)

Indefinite lengths are supported by a counting pass, not refused (RFC 8949 Appendix A carries
them). `cbor.parse_value` is two scans of the same bytes, as ADR-0003 §4:

1. `bound` = the number of bytes in `5f 7f 9f bf` (a cheap scan; those bytes inside a payload
   only over-count). `counts = alloc(u32, bound)` from the tree arena, its newest block.
2. **Pass 1** runs the full reader and writes `counts[ordinal]` for each indefinite item in
   open order: the child count (map: pair count) for an array or map, the total payload byte
   length for a string. Every grammar, UTF-8, tag, bomb-rule and depth error is reported here,
   before any node exists. `counts` shrinks in place to the number actually used.
3. **Pass 2** cannot fail except `OutOfMemory` and the key/time conversion errors (those too
   are decided in pass 1; pass 2 asserts). Each container is one allocation of its final size
   (definite: the header count, checked in pass 1; indefinite: `counts`); every key and string
   is copied once. A document with no indefinite item has `bound = 0` and pays no allocation
   for pass 1, only the second scan; the benchmark (plan item 10) reports the doubled decode work.
4. msgpack needs neither: every count is in the header, the §5 check precedes each allocation,
   and the build is one pass over an explicit `[nesting_max]Frame` stack.

If 0.16's `ArenaAllocator` cannot shrink its newest allocation in place, the three-scan fallback
of ADR-0003 §4 applies; the public API does not change.

### 10. Public surface, ownership, reflect and runners (i, j)

```zig
// src/msgpack.zig; src/cbor.zig is identical except StringifyOptions.
pub const ParseOptions = struct {
    depth_max: u16,                  // 1 <= depth_max <= nesting_max, asserted.
    bytes_max: u32,                  // input.len > bytes_max is InputTooLarge.
    duplicate_key: core.DuplicateKeyPolicy,
};
pub const StringifyOptions = struct { depth_max: u16 };         // msgpack
pub const StringifyOptions = struct { depth_max: u16, deterministic: bool };   // cbor
pub fn parse_value(tree: *ValueTree, input: []const u8, options: ParseOptions,
    diag: *Diagnostics) ParseValueError!Value;
pub fn write_value(w: *Io.Writer, value: Value, options: StringifyOptions,
    diag: *Diagnostics) WriteValueError!void;
/// Result slices live until `tree.deinit()`.
pub fn parse(comptime T: type, tree: *ValueTree, input: []const u8, options: ParseOptions,
    diag: *Diagnostics) ParseError!T;
pub fn stringify(comptime T: type, tree: *ValueTree, w: *Io.Writer, value: T,
    options: StringifyOptions, diag: *Diagnostics) StringifyError!void;
pub const decoder = @import("msgpack/decoder.zig");   // the pull Reader
```

It mirrors `json.zig`; there is no `gpa` parameter (nothing is allocated outside the tree) and
no file helpers in v0.6.0. `parse_value` returns the root and does not store it in `tree.root`.
No option has a default.

- **Copy vs borrow.** The tree copies every string, byte string and key into its arena, so a
  result has one lifetime (REALM "DOM ownership"). PRD's "zero-copy bin/str" is honored by the
  public `decoder.Reader`, whose tokens borrow `input` (as the JSON scanner's `Token.raw` does)
  and are valid while `input` is. Result slices from `parse(T)` are documented as tree-owned.
- **Reflect and `[]const u8`.** `reflect` maps a `[]const u8` to `.string` (ADR-0002 §4) and
  `.bytes` into it is `TypeMismatch`. Binary data is opted into per field: `sigil_options`
  gains `.bytes = .{ "payload", "digest" }`, a tuple of field names of the struct. A listed
  field must be `[]const u8` or `?[]const u8` (a comptime error otherwise, like `rename` of a
  missing name); `reflect.parse` then accepts `.bytes` only (a `.string` is `TypeMismatch`), and
  `reflect.stringify` emits `.bytes`. No other type maps to `.bytes`: `[N]u8` stays an array of
  `int`. `json` and `toml` change nothing: their writers refuse `.bytes` as `Unrepresentable`
  and their parsers never produce it, which plan item 4 tests per format.
- **Runners (j).** `src/cbor/vectors_test.zig` runs the RFC 8949 Appendix A vectors
  (`appendix_a.json` of the CBOR working group's `test-vectors`, with `hex`, `decoded`,
  `roundtrip`); it decodes the JSON with **`std.json`**, not `sigil.json`. `src/msgpack/
  vectors_test.zig` runs a subset of `msgpack-test-suite`, whose files are YAML: since
  `sigil.yaml` does not exist, the runner reads the `msgpack:` hex lines and the one typed
  expected line of each file with a line reader local to the test. Item 8 checks the licences
  and the file shapes at vendoring; if the upstream shape is too irregular for a line reader,
  the fallback is a hand-derived `tests/msgpack/vectors.json` whose `SOURCE` file maps each case
  to its upstream file. Either way the suite asserts counts (cases, pass, reject,
  pinned-unsupported with a reason string each, never a skip) and prints them once per run.

## Consequences

- `core.value` gains `DuplicateKeyPolicy` (additive; `json` re-exports it). `reflect` gains
  `sigil_options.bytes` (additive). No existing signature changes.
- 11 + 17 parse and 5 + 5 write variants become public; adding one later breaks exhaustive
  `switch`es, so they were chosen to cover every vector class in §4 and §8 once.
- The deterministic CBOR bytes and the shortest-head policy of §6 are a wire surface at v0.6.0.
- Round-trip is exact in normal form (§2); a small `.uint` reads back as `.int`. Offsets are
  never silently dropped: msgpack refuses them, CBOR keeps them through tag 0.
- A CBOR decode of a document without indefinite items costs two scans (the benchmark records
  it); msgpack costs one.
- A reader of a diagnostic sees `byte 17`, not `2:4`. That is the honest unit for binary input
  and keeps `Diagnostics` unchanged.
- Plan 007 items 2-11 follow this ADR.

## Alternatives

- **Refuse indefinite lengths.** Rejected: Appendix A carries them and pinning their vectors
  as unsupported hides a gap; the cost is a second scan that definite-only documents already
  pay for validation.
- **Add `Value` variants for ext and tags.** Rejected: `Value` is 32 bytes and every format
  would carry the variant; unsupported items are a typed error until a consumer needs one.
- **Stringify non-string keys** (`1` -> `"1"`). Rejected: silent collisions (`1` and `"1"`).
- **Silently drop a timestamp offset in msgpack.** Rejected: breaks the "refuse what cannot come
  back" rule of ADR-0003 §7; the caller owns the normalization.
- **Float-width and sort options.** Rejected: one policy each (§6) keeps encoder bytes
  predictable; the deterministic flag is the only switch because RFC 8949 defines it.

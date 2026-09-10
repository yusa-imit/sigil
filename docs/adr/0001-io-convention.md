# ADR-0001 — `io: Io` on sigil's public API

- Status: accepted
- Date: 2026-09-10
- Plan item: `docs/plans/001-zig-0.16-and-tiger-baseline.md` item 7 (kingdom spike)
- Kingdom rule recorded in: `citadel/core/rules/zig-0.16.md`, "THE KINGDOM CONVENTION for `io: Io`"

## Context

Zig 0.16 deletes `std.fs`, `std.net`, `std.time`'s clocks and every `std.Thread` sync primitive
from their old namespaces and reissues them through one runtime vtable value, `std.Io`. Anything
that can block, race, or be canceled now takes an `io: Io` argument. `main` receives one
(`std.process.Init.io`); tests receive one (`std.testing.io`); a library never makes one.

sigil is the kingdom's spike for that convention: it is 285 lines of stubs with one error on 0.16,
so the shape decided here is copied by eight other realms, where getting it wrong is expensive.
sigil's io-touching public surface is small and fixed by `docs/PRD.md`:

- `config.load` — read N config files, overlay environment and CLI arguments, produce a typed `T`.
- `config.watch` — notice that a config file changed (PRD §4.5, phase 5C: polling based).
- `<format>.parseFile` / `<format>.stringifyFile` — the file-shaped convenience wrappers that all
  seven format modules (json, toml, yaml, msgpack, cbor, proto, csv) will eventually implement
  identically over their in-memory `parse`/`stringify`.

Two of these are generic free functions with a `comptime T: type` parameter and no receiver, which
is precisely the case the kingdom rule's "first parameter after the receiver" phrasing does not
resolve on its own. That ambiguity is what this ADR removes.

Three further forces apply. Tiger Style §1.9 forbids storing an allocator for later growth and
§3.8 requires the allocator parameter's *name* to state who frees. Tiger Style §1.14 forbids
invoking user callbacks from inside an I/O completion and asks for `tick()`/`poll()` instead.
Tiger Style §3.5 ranks call-site dimensionality `void > bool > u64 > ?u64 > !u64`. And `std.Io` in
0.16 offers no file-watch primitive at all — `Io.Dir.statFile` is the only portable mechanism.

## Decision

### 1. Parameter order (the rule sigil pins for the kingdom)

**`comptime T` → `io` → memory → subject → `options`.**

1. A `comptime T: type` parameter occupies the receiver slot: it comes first, and `io` comes
   immediately after it. A method's receiver (`self`, or an out pointer `target: *T`) occupies the
   same slot with the same consequence.
2. `io: Io` is next. It is never stashed in a struct to save a parameter; it is passed per call.
   The one sanctioned exception in the kingdom rule (a long-lived owning service object caching an
   `io` field) does not apply to any type sigil defines, including `Watcher`.
3. Memory comes next, named by discipline — `arena`, `gpa`, or `scratch: []u8`, never `allocator`.
4. Then the subject the call acts on, general to specific: `dir: Io.Dir`, then `sub_path`, then
   `value`.
5. `options: Options` is last, and carries no defaults, so every call site spells out every choice.

Worked example, the exact case the rule was ambiguous about:

```zig
pub fn load(comptime T: type, io: Io, arena: Allocator, options: Options) LoadError!T
//          \___ receiver slot _/  \_ io _/  \_ memory _/  \_ subject lives in options _/
```

`Io.Dir` is always an explicit parameter or option field; sigil never calls `Io.Dir.cwd()` itself.
The process's working directory is ambient global state of exactly the kind `io` injection exists
to abolish, and passing `.cwd()` at the call site is what makes `tmpDir`-based tests possible.

The same reasoning applies to the environment: `config.load` does not read the environment. The
caller passes `init.environ_map` in `Options.env`, or `null` to disable that layer. Argument
vectors are passed the same way.

### 2. `config.watch` becomes a poll-based `Watcher`, not a callback

The plan item sketched `config.watch(io: Io, path: []const u8, cb: ...)`. sigil ships no `cb`.
`config.Watcher` is initialized once and drained by the caller:

```zig
var watcher: config.Watcher = undefined;
try watcher.init(io, gpa, .{
    .dir = .cwd(),
    .paths = paths,
    .sweep_interval_min = .fromMilliseconds(500),
});
defer watcher.deinit(gpa);

while (try watcher.poll(io)) |change| { ... }   // Drains at most `paths.len` changes.
```

Reasons, in order of weight: a callback would run user code from inside an I/O completion, which
Tiger Style §1.14 bans outright and which costs the library its control flow, its bounded work per
interval, and its ability to be canceled; a callback forces the library to invent a policy for the
user's errors and for the lifetime of anything the callback captures; `poll` makes the clock an
argument, so a seeded test can drive a whole change history deterministically with
`std.testing.io`; and there is no event-driven mechanism to hide behind anyway, since 0.16's
`std.Io` vtable has no watch operation, so the honest implementation is a rate-limited
`Io.Dir.statFile` sweep, which is a poll by construction. When sirocco grows a native watch slot,
it changes what `poll` does internally, not what callers wrote.

`poll` returns `PollError!?Change`: `null` means "nothing changed, or the sweep interval has not
elapsed" — the common case, and not an error. The `?` buys the `while (try ...) |change|` drain
loop; a `.none` variant of `Change.kind` would force every caller to switch over a payload-less
case instead.

### 3. Memory: `load` takes a caller-owned `arena` and returns `T` by value

`load` allocates only from `arena` and never frees; the caller drops the whole arena. Consequences:
sigil stores no allocator anywhere (Tiger Style §1.9 holds literally, not by exemption), the return
type is `!T` rather than `!Parsed(T)` with a `deinit` a caller can forget, and hot reload is
`_ = arena.reset(.retain_capacity)` followed by another `load`. The parameter is named `arena`
because that name is the ownership contract (§3.8). At a binary's `main` this costs nothing:
`std.process.Init` already hands over both `io` and `arena`.

```zig
const cfg = try sigil.config.load(AppConfig, init.io, init.arena.allocator(), .{ ... });
```

`Watcher` is the one long-lived object; it takes `gpa` at `init`, allocates its fixed arrays there
(bounded by `files_max`), never grows, and takes the same `gpa` back at `deinit`.
`stringifyFile` allocates nothing at all: it writes through the caller's `scratch: []u8`.

### 4. Error sets: real names now, `error.NotImplemented` unioned in as scaffolding

Each function declares its final, hand-written error set today, unioned with the module's existing
stub set:

```zig
pub const LoadError = error{ OutOfMemory, Canceled, FileNotFound, ... } || Error;
```

The sets are written out by hand rather than composed from `Io.Dir.ReadFileAllocError` and friends.
A foundation library pinned by tag must not re-export std's 30-variant OS error sets as its own
public contract: that makes every consumer's exhaustive `switch` hostage to std's churn, and it
buries sigil's own failure vocabulary. `error.OutOfMemory` and `error.Canceled` are the two
exceptions and pass through unmapped, because their meaning is canonical and swallowing
`error.Canceled` leaks resources.

`|| Error` (`error{NotImplemented}`, already present in every sigil module) is the only stub
artifact. It is deleted, function by function, as plan 002 implements each one — a narrowing of a
public error set, done while sigil has no tag and no consumer, and loud at every call site if one
ever appears.

### 5. Libraries never construct an `Io`

No `Io.Threaded`, no `Io.Evented`, no `Io.Threaded.global_single_threaded` anywhere under `src/`,
now or later. `tools/tidy.zig` gains ban rules for those spellings so the property is machine
checked rather than remembered.

### Final signatures

```zig
// src/config.zig
pub const files_max: u32 = 32;

pub const Format = enum { json, toml, yaml, auto };
pub const Source = struct { path: []const u8, format: Format, required: bool };
pub const Env = struct {
    map: *const std.process.Environ.Map,
    prefix: []const u8,
    nesting_separator: []const u8,
};
pub const Args = struct {
    argv: []const []const u8,
    prefix: []const u8,
    nesting_separator: []const u8,
};
pub const Options = struct {
    dir: Io.Dir,
    sources: []const Source,        // Ascending precedence; `sources.len <= files_max`.
    env: ?Env,                      // null disables the environment layer.
    args: ?Args,                    // null disables the argument layer.
    file_bytes_max: Io.Limit,
    depth_max: u16,
    deny_unknown_fields: bool,
};

pub const LoadError = error{
    OutOfMemory, Canceled, FileNotFound, AccessDenied, FileTooBig, ReadFailed,
    ParseFailed, TypeMismatch, MissingField, UnknownField, SchemaInvalid,
    EnvInvalid, ArgsInvalid,
} || Error;

pub fn load(comptime T: type, io: Io, arena: Allocator, options: Options) LoadError!T;

pub const Watcher = struct {
    pub const ChangeKind = enum(u8) { created, modified, deleted };
    pub const Change = struct { path_index: u32, kind: ChangeKind };
    pub const Options = struct {
        dir: Io.Dir,
        paths: []const []const u8,      // `paths.len <= files_max`.
        sweep_interval_min: Io.Duration,
    };
    pub const InitError = error{ OutOfMemory, Canceled, AccessDenied, StatFailed } || Error;
    pub const PollError = error{ Canceled, AccessDenied, StatFailed } || Error;

    pub fn init(target: *Watcher, io: Io, gpa: Allocator, options: Watcher.Options) InitError!void;
    pub fn deinit(watcher: *Watcher, gpa: Allocator) void;
    pub fn poll(watcher: *Watcher, io: Io) PollError!?Change;
};

// src/json.zig — the shape every format module implements identically.
pub fn parseFile(
    comptime T: type,
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    options: ParseOptions,
) ParseFileError!T;

pub fn stringifyFile(
    io: Io,
    scratch: []u8,
    dir: Io.Dir,
    sub_path: []const u8,
    value: anytype,
    options: StringifyOptions,
) StringifyFileError!void;
```

## Consequences

- The ambiguity in the kingdom rule is resolved for every realm: a `comptime T: type` parameter is
  the receiver slot, so `io` is the second parameter of a generic free function and the first of a
  monomorphic one. `citadel/core/rules/zig-0.16.md` already states everything else this spike
  settled and needs no edit beyond, optionally, this one clarifying clause.
- The shape is machine checked, not merely documented: a comptime parity test in `src/root.zig`
  walks all seven format modules and fails the build if any module that declares `parseFile` or
  `stringifyFile` puts `io` anywhere else.
- Only `src/json.zig` carries the format-side stub. Six identical unimplemented copies would be
  six places to drift; the parity test binds any module that adds one later.
- Passing `Io.Dir` and the environment map explicitly makes every io-touching entry point testable
  against `std.testing.io` and a `tmpDir`, with no process-global state — but it makes call sites
  wordier than `std.fs.cwd()`-flavoured APIs, which is the intended trade.
- `load` returning `T` from a caller-owned arena means sigil cannot free a partial result on
  failure; a failed `load` leaves garbage in the caller's arena. This is stated in the `///`
  contract, and it is why the parameter is named `arena` and not `gpa`.
- `Watcher` cannot report a change that happened and reverted between two sweeps, and coalesces
  repeated writes into one `.modified`. That is inherent to polling and is documented; an
  edge-accurate watcher waits for sirocco.
- The error sets are hand-written, so a new std error variant surfaces as a compile error inside
  sigil's mapping code rather than silently widening sigil's public contract. The cost is a
  mapping `switch` per I/O call, written when each function is implemented.
- `error.NotImplemented` must disappear from every one of these sets before sigil's first tag;
  until then no consumer can be told these functions work.

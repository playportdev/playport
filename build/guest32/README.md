# Software-separated Win32 memory experiment

This is a **host-tested memory, PE32 mapping, import-binding and mapped-dependency resolution prototype**, not a shipped
runtime, complete Windows loader, WoW64 bridge or emulator. The dev app can
exercise the memory contract from Settings; no game uses it. It cannot run
Portal 2.
It establishes the first memory contract from
[the Portal 2 investigation](../../docs/evidence/2026-10-01-portal2-32-bit.md).
The app remains x86-64-only; no runtime decision or pin is changed.

## Contract

Each `g32_space` reserves a separate, non-executable 4 GiB backing window above
4 GiB. Guest addresses remain `uint32_t`; host addresses are `uintptr_t` or
pointers. Translation adds the backing base **after** checking the complete
access and every page's permissions. Reverse translation checks ownership and
permissions before producing a guest pointer. Guest arithmetic wraps to 32 bits
before translation, but an access straddling the end of the window faults.

Reservations begin at 64 KiB boundaries; guest pages are 4 KiB. The low 64 KiB
is inaccessible. Commit zeroes only new pages; recommit preserves data. Decommit
and release zero discarded guest pages and leave committed neighbors intact.
An unused whole host page becomes `PROT_NONE` and is advised for reclamation.
`g32_reserve_any` adds deterministic first-fit reservation within a caller's
half-open guest-address interval, whose exclusive upper bound may be 2^32.
It rounds bases up to 64 KiB, requires a nonzero 4 KiB-aligned size, skips all
occupied pages (including decommitted reservations), and never commits backing.
Selection and reservation occur in one externally serialized call. Invalid
input and exhaustion are distinct; failures leave output and memory metadata
unchanged. This supplies bounded allocation groundwork for future dependencies,
heaps and stacks, not Windows VirtualAlloc. The PE mapper can now use it for
bounded automatic image placement (below); no game runtime behavior changes.

Release accepts only an allocation's original base. A VM operation cannot span
two reservations; an ordinary memory access can when both permit it.

`g32_query` snapshots guest metadata without reading backing or granting access.
It accepts any byte address and returns the rounded-down 4 KiB page plus the
**forward** run of matching state, permissions and allocation ownership. It
never searches backward or merges adjacent reservations. Region size is 64-bit
so the exclusive end can be 2^32. The low 64 KiB reports `BLOCKED`, not reusable
`FREE`; reservations report their original allocation base. `COMMITTED` with
zero access is distinct from `RESERVED`, even though both reject translation.
Host `mprotect` state is deliberately ignored. Invalid calls preserve output;
query results expire at the next VM change and require external serialization.
This is not Windows `MEMORY_BASIC_INFORMATION`: allocation protection, image vs
private classification, guard/write-copy and a Wine syscall adapter are absent.
A worst-case query scans all guest pages; it is not a JIT access fast path.

Query tests cover byte/page rounding, forward-only runs, every permission
combination, allocation boundaries, release/decommit/protect/recommit, separate
spaces, intact live bytes, nearly-4-GiB metadata-only runs and the last byte of
the address space. At each host granule, an independent 256-page oracle checks
every page after 1024 deterministic mixed VM operations, including failed
protection changes. [Query evidence](../../docs/evidence/2026-10-01-guest32-memory-query.md).

A 16 KiB host page can contain four guest pages with different permissions.
**Native `mprotect` cannot enforce their permissions independently.** Committed
backing is RW, never executable; `G32_EXEC` permits instruction-byte fetch only.
Every fetch, load, store, string operation and atomic must use equivalent
software checks, including full access width. A raw unchecked `base + address`
in a JIT or syscall bridge is wrong, even if another guest page makes that host
page readable. Pointer loans require external serialization and expire at a VM
change. This prototype has no concurrent-access/lifetime protocol. Failed native
protection operations poison the space; only destruction is safe afterward.

## Checks

`./pp test --quick` includes `guest32_test.c`. The same cases run with actual host
pages and simulated 16 KiB and 64 KiB host granules. They cover the installed
launcher's preferred address (`0x400000`) and image extent (`0x5c000`), **not its
PE contents or execution**; ownership, native/guest pointer conversion,
null/uncommitted/protected pages, access across pages and reservations, upper
address overflow, all-or-nothing permission validation, recommit and zeroing.

Automatic reservation tests additionally compare 2048 deterministic mixed
allocation/release attempts against an independent brute-force page oracle at
each host granule. They cover partial granules, tight byte bounds, decommitted
ownership, occupied later pages, intact neighboring data, exhaustion, rollback,
release/reuse, the upper address boundary and the launcher's preferred-base
collision. No guest image or instruction executes in these allocation tests.
[Allocation evidence](../../docs/evidence/2026-10-01-guest32-bounded-allocation.md).

For sanitizers:

```sh
mkdir -p .work/guest32
clang -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  build/guest32/guest32.c build/guest32/guest32_test.c \
  -o .work/guest32/test-sanitized
.work/guest32/test-sanitized
```

## PE32 image materialization

`pe32.{h,c}` maps i386 PE32 file buffers into guest reservations, copies headers
and sections, zeroes BSS, applies HIGHLOW/ABSOLUTE relocations and sets per-guest-
page permissions. All guest addresses, including the returned entry point and
IAT slots, remain 32-bit values. It never executes backing natively. Relocation
records are snapshotted before applying fixups, so a fixup cannot mutate a later
record while it is being parsed. Mapping failures leave output unchanged and
release only the reservation obtained by that call, never a conflicting one.

Import inspection reads bounded descriptors, lookup tables, IAT slots, DLL and
symbol names through checked guest reads, including ordinal imports and the
FirstThunk fallback. `g32_pe_bind_imports` snapshots those names and guest IAT
addresses, then uses a caller-supplied resolver to stage guest target addresses.
It validates every target and writable IAT slot before writing any slot. Targets
may be readable data or fetchable code in the same space; wide resolver output
rejects native pointers rather than truncating them. Duplicate/byte-overlapping
IAT slots are rejected, and binding failures preserve guest bytes/protections.
Resolver-side effects cannot be rolled back: callbacks must not modify guest
memory, change mappings or reenter the API. Only serialized use is supported.

Binding an existing image requires already-writable IAT pages and does not
broaden permissions. `g32_pe_map_bound` instead maps/relocates a **new** image,
then binds before applying final PE permissions. The installed launcher and
engine have read-only IAT pages; this path leaves them read-only after binding.
Dependencies must already be mapped, and a resolver is required. The unpublished
image is initially guest RW/non-executable; resolver callbacks must not access
it or retain loans into it. Targets are rechecked after final protections so
self-targets cannot retain access granted only during image construction.
Any failure (even after IAT writes) discards only the new image, leaves output
unchanged and preserves dependencies. This still does not implement game APIs.
The FirstThunk fallback is snapshotted before writes but cannot be rebound after
its lookup data is overwritten. Import inspection/binding does **not** load or
resolve dependencies itself, initialise TLS, construct Windows process state,
call DllMain or execute an entry point. Image metadata is native ownership state,
not a guest ABI structure; it expires when its reservation is released.

`g32_pe_map_auto` and `g32_pe_map_bound_auto` place images within a supplied
half-open `[lower, upper)` window (upper may be 2^32). They prefer the file's
ImageBase if valid, wholly in bounds and unoccupied, otherwise choose the first
free 64 KiB-aligned base. Fallback requires non-stripped relocation records;
malformed fixups fail without retrying later bases. Reservation happens exactly
once before the existing materialization/binding/finalization transaction.
Invalid bounds return `ADDRESS`, exhausted relocatable windows `NO_SPACE`, and
fixed-base fallback `RELOCATION`. Failure preserves output and other allocations.
This is not dependency discovery/loading or Windows ASLR policy; callbacks and
image lifetimes retain the same restrictions as the explicit-base APIs.

Automatic-placement tests cover preferred-base priority, collisions (including
later pages and decommitted reservations), relocated fixups, nonrelocatable
images, tight bounds, alignment, exact top-of-space fits, exhaustion and rollback
after malformed fixups, finalization or unresolved imports. The private files
also undergo automatic collision placement and a whole-image comparison with
explicit same-base mapping in a separate space. Auto map-and-bind retains the
read-only IAT and inert-placeholder limitations of the explicit tests above.
[Automatic-placement evidence](../../docs/evidence/2026-10-01-guest32-auto-mapping.md).

The parser deliberately supports page-aligned sections (alignment at least
4 KiB), at most 96 sections, 16 data directories and a 512 MiB image. Import
inspection has a total one-million-thunk budget; binding stages at most 65536
imports. Bound-address/delay imports are not supported. Export forwarders can
be followed only through an explicitly supplied set of already-mapped modules.
These are experimental
resource/format limits, not a statement of full Windows loader compatibility.
Guard pages, shared/write-copy mappings and discardable sections are not yet
implemented. Headers retain the file's original preferred ImageBase; relocated
guest addresses are returned separately in `g32_pe_image`.

`pp test --quick` also runs `pe32_test.c`: synthetic images at native, 16 KiB and
64 KiB host granules, every truncated input length, malformed headers/sections,
relocations, imports, reservation conflicts, rollback and 4096 deterministic
file mutations. Binding checks exercise synthetic function/data imports, ordinal
and FirstThunk lookup, rebind with a separate lookup table, high native-pointer
rejection, wrong-space/unmapped/inaccessible targets, read-only and cross-page
IAT refusal, malformed later imports before resolver callbacks, overlapping
slots, resource limits and no-import images. Real game files are private and
are **not** CI fixtures. Their binding test deliberately rejects an unresolved
import and verifies the entire mapped image is unchanged; no Windows API is
implemented. [Binding evidence](../../docs/evidence/2026-10-02-guest32-import-binding.md).
Map-and-bind tests additionally cover read-only/unaligned cross-page IAT slots,
FirstThunk snapshots, self-targets under final permissions, failed finalization,
reservation rollback, dependency preservation and export-resolver integration.
The optional private-file test also rejects unresolved map-and-bind, then patches
all IAT slots to **inert readable test data**, comparing every image byte against
an IAT-only overlay and checking that every slot remains read-only. This is a
layout/permission experiment, not real game dependency resolution or execution.
[Map-and-bind evidence](../../docs/evidence/2026-10-02-guest32-map-bound.md).
The local host inspection can run through the same test executable:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror \
  build/guest32/guest32.c build/guest32/pe32.c build/guest32/pe32_test.c \
  -o .work/guest32/pe32-test
.work/guest32/pe32-test .work/portal2-files/portal2.exe .work/portal2-files/engine.dll
```

This is a host test, not another entry point into app functionality. The
[real-file evidence](../../docs/evidence/2026-10-02-guest32-pe32.md) includes an
independent full-image comparison at both preferred and relocated addresses.

## PE32 export lookup

`g32_pe_find_export` supplies the counterpart to external import binding. It
looks up exact case-sensitive names or full export ordinals in a mapped image,
returning a **guest** function/data address or a copied forwarder string. Export
ordinals are not EAT indices; zero entries are holes (`G32_PE_NOT_FOUND`), never
pointers to the image base. Unsorted names and aliases work. Table spans and
all name/ordinal pairs are checked before returning, including later malformed
names after a match; unselected EAT targets are not validated. Selected direct
targets must remain readable or fetchable inside the owning image/space.
Failure leaves output and guest memory/protections unchanged.

Forwarder RVAs are recognized inside the export-directory range. Their nonempty
NUL-terminated strings must fit both that range and 260 bytes. They return no
address: dependency loading remains absent; the separate mapped-dependency
resolver below handles forwarder parsing/following and cycle detection.
Functions and names each have a
65536-entry budget; names have a 260-byte bound including NUL. These are prototype
limits, not complete Windows compatibility. All calls still require external
serialization and live image metadata.

Synthetic tests bind imports using real lookups in a synthetic dependency's
export table, covering functions, data, ordinals, aliases, holes, forwarders,
execute-only targets, malformed tables/strings, cross-guest-page accesses,
wrong-space rejection, full-width ordinals and output preservation. The optional
private-file test independently converts raw-file RVAs and checks **every** real
named export and EAT entry at both preferred and relocated addresses, without
calling or binding any game export. It also verifies the whole mapped image
remains unchanged. The same test/sanitizer commands above exercise these checks.
[Export evidence](../../docs/evidence/2026-10-02-guest32-export-lookup.md) records
both engine exports and an independent `llvm-readobj` comparison.

## Mapped-dependency resolution

`g32_pe_modules_create` snapshots caller-supplied ASCII module basenames and
image metadata into an immutable **native** table. All images must already be
mapped in one guest space. Names compare case-insensitively, and names without
any dot gain `.dll`; paths and ambiguous duplicate canonical names are rejected.
Image aliases are permitted. Creation leaves output unchanged on failure;
destroying a table frees only its metadata, never the guest images. Images must
remain live throughout use: this is not reference counting or an unload protocol.

`g32_pe_resolve_export` returns only a checked guest address. It follows named
and strict decimal `#ordinal` forwarders, splitting at the last dot to allow an
explicit module extension. Symbols remain case-sensitive. Cycle identity is the
image base and selected export ordinal, not the spelling of a module/symbol:
module and export aliases cannot disguise a repeated export. Missing modules or
exports return `NOT_FOUND`, malformed input `FORMAT`, cycles `CYCLE` and a depth
limit `UNSUPPORTED`. Failures preserve output and guest bytes/permissions.
The limits are 256 modules, 32 selected exports per lookup and 259-byte names.
Forwarded ordinals span `uint32_t`, including zero; ordinary import ordinals
still have the PE32 thunk's 16-bit limit.

`g32_pe_resolve_import` adapts this table to `g32_pe_bind_imports` or
`g32_pe_map_bound`, treating every failed resolution as unresolved. It does not
load files, manufacture placeholder targets, resolve API sets/search paths,
attach DLLs or call game code. Tests cover multi-hop named/ordinal function/data
resolution, module/name aliases, cycles, strict syntax, resource boundaries,
metadata snapshots, inaccessible targets and transactional binding/rollback.
The private-file tests also resolve every direct engine export at preferred and
relocated addresses against independent raw-file tables, and reject real import
binding with missing dependencies without changing any image byte.

[Resolution evidence](../../docs/evidence/2026-10-02-guest32-forwarder-resolution.md)
records checks and limits. The existing test and sanitizer commands include all
these cases; this code is still not linked into the app or checked on the phone.

## Decoder fetch boundary (host audit only)

`fetch_audit.py` extracts two unmodified methods from a repository-local FEX
source tree (`CheckRangeExecutable`, `PeekByte`) and compiles them against a
synthetic `g32_query` adapter and separated backing:

```sh
python3 build/guest32/fetch_audit.py .work/run/fex
python3 build/guest32/fetch_audit.py .work/run/fex --sanitize
```

This optional experiment needs a prepared source tree, not a FEX build. It
checks execute-only bytes, cross-page denial, native-accessible non-executable
neighbors, decommit/null and the end of 32-bit space at all three host granules.
It reproduces cached execute permission after revocation and verifies a reset
restores rejection. Integration must join FEX's code-invalidation protocol;
`g32_query` cannot reset decoder caches by itself. The runner prints source and
method hashes; generated files stay in `.work/guest32/fetch-audit/`.

**No full instruction decode or execution occurs.** The experiment does not
port immediate reads, IR, JIT or Wine. Generic IR memory operations also serve
native CPU-state storage, so blindly translating every `LoadMem`/`StoreMem`
would be wrong. Separate stack, pair, vector, string, atomic and code-reader
paths require explicit coverage. [Fetch-boundary evidence and source
inventory](../../docs/evidence/2026-10-01-guest32-fetch-boundary.md) define the
next gate: a series-applied isolated full 32-bit decoder test, before execution.

## Full 32-bit decoder gate (host audit only)

After the native link prerequisite below, run:

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --sanitize
```

This links the real context and complete frontend/opcode tables. Patch
`fex/0015` provides a test-only byte-source seam: only the frontend enables
`FEX_TEST_DECODER_BYTE_SOURCE`, without enabling FEX_IOS_HOST or changing native
layouts. No shipped target enables the seam. Guest PCs stay low while a serialized
`g32_translate` callback supplies high contiguous backing; real PeekByte/ReadData
retain full-width execute checks. This is not a concurrent VM port.

All three host granules pass immediate operands, a cross-page MOV with an
execute-only neighbor, native-readable/no-execute rejection, multi-block guest
PCs, explicit cache reset after VM changes and end-of-32-bit-space rejection.
ASan/UBSan cover frontend, adapter and g32, not the other FEX archives. Outputs
and hashes stay in `.work/guest32/separated-decoder/`. This optional experiment
requires a prepared native FEX build and is not part of CI.

**No guest execution, IR/JIT, Wine bridge or game launch occurs.** Disk cache,
SMC and auxiliary code readers are outside this gate. The register-only
pre-optimization decode-to-IR gate below now passes; guest/native memory
provenance and runtime blockers remain.
[Full decoder evidence](../../docs/evidence/2026-10-02-fex-separated-decoder.md).

## Register-only decode-to-IR gate (host audit only)

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir --sanitize
```

`native_ir_test.cpp` uses the same serialized byte-source adapter as the decoder
and calls real opcode-table handlers, OpDispatchBuilder and IRValidation. It
stops **before optimization/register allocation**, not through the complete
ContextImpl::GenerateIR pipeline. No FEX method is replaced, and no new upstream
patch, runtime switch or app entry point is introduced.

Two MOV/MOVZX sequences cover all eight 32-bit GPRs, register copies, AX/AL/AH
partial writes and high-byte zero extension. Execute-only instructions cross a
guest page boundary at three guest PCs, including `0xffff0ffe`, at each host
granule. An independent register oracle compares every instruction boundary for
128 input states per graph. A strict SSA whitelist rejects memory/flag/helper
operations and checks guest-valued metadata/exit PCs and i32 fixed-register
loads/stores; i64 constants/bit inserts are pure values, not native addresses.
This is bounded offline graph analysis, **not guest execution or an interpreter
backend**. Guest instruction bytes remain unchanged and unreadable as data.

Optimized and ASan/UBSan builds pass; archives containing the opcode handlers
and validation pass are uninstrumented. The existing decoder regressions also
pass after sharing `native_audit_adapter.h`. Outputs and hashes stay in
`.work/guest32/separated-ir/`. This optional test needs the prepared native build
above and is not a CI gate. [IR evidence](../../docs/evidence/2026-10-02-fex-register-ir.md).

The optional `--allocate` audit now checks every nonempty sequence prefix
through the real default optimizer/RA pipeline against the same register
oracle. [Allocated IR evidence](../../docs/evidence/2026-10-02-fex-allocated-register-ir.md).
Scalar/stack/vector/string/atomic memory checks, concurrent invalidation,
auxiliary code readers and Wine marshalling remain untouched. No phone run or
game launch occurred; Portal 2 remains unplayable.

## Register-only ARM emission gate (host audit only)

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit --sanitize
```

`--emit` implies `--allocate` and retains its independent pre/post-RA checks.
The real native Arm64JITCore configures RA, emits all 144 prefix blocks and
copies them into its real shared code buffer. Real Dispatcher and LookupCache
objects are constructed, but **no emitted instruction is executed**. This
checks the native non-EC backend, not the shipped ARM64EC calling convention.

`native_code_oracle.h` independently analyzes a strict register-only AArch64
machine-word subset: MOVN/Z/K, MOV register/bitmask aliases, BFI and UBFX.
Unknown instructions, uninitialized temporaries and non-budget register
accesses fail. All 18432 low-32-bit register outcomes match the x86 oracle.
The entry prologue, branch/thunk layout, exit guest-RIP literal, real linker
address, tail and packed RIP metadata are checked separately. No guest-memory
operation or dispatcher/linker execution is covered. Six private post-emission
negative controls are rejected.

Optimized and ASan/UBSan runs pass, including ownership/leak checks; backend
archives remain uninstrumented. All earlier decoder/IR/RA modes pass in both
builds. Outputs stay in `.work/guest32/separated-emission/`; the prepared native
build is required and this is not a CI gate or an app entry point.
[Emission evidence](../../docs/evidence/2026-10-02-fex-register-arm-emission.md).
The next bounded gate is real execution of these register-only blocks on an
ARM target or simulator, with explicit static-register input and exit capture.
An eventual phone experiment must enter through the developer UI. **No phone
validation occurred; Portal 2 remains unplayable.**

## Native FEX link prerequisite (host audit only)

After configuring a series-applied native FEX build with the disabled allocator,
run `python3 build/guest32/native_link_audit.py .work/guest32/decode-audit/native`.
It constructs and destroys a real ContextImpl, exercises libc allocator hooks
and verifies full predictor clearing and reset census. It links real FEXCore,
FEXCore_Base, JemallocDummy, cephes and softfloat with fmt and xxhash, using the
real compilation database, not synthetic replacement implementations.
[Configuration](../../docs/evidence/2026-10-01-fex-native-allocator.md) and
[real-context link evidence](../../docs/evidence/2026-10-01-fex-native-context.md).
This is an optional prerequisite test, **not full decoding or guest execution**;
section garbage collection limits the link check to reachable native code,
now including ContextImpl's virtual methods such as CompileBlock.

## Still needed before a title launch

- Windows memory-query structures/classification and allocation
  rounding/guard/write-copy semantics, concurrent VM changes and safe
  translated-code invalidation. The guest metadata query above is not an ABI bridge.
- FEX instruction decode/fetch, every memory emitter and atomic/string path
  translated and checked; exceptions reported with guest addresses; tests of
  real x86 instructions, not just this C API.
- Wine i386 images and a WoW64 CPU bridge with explicit nested-pointer and
  callback marshalling, guest PEB/TEB/stack and syscall arguments. High-address
  native Wine objects cannot simply be truncated into 32-bit fields.
- An i386 D3D9/Vulkan bridge into the native graphics stack, plus audio/input.
- Integration only via patch series and the product UI. First a Portal 2 menu,
  then gameplay, save/reload and Hollow Knight regression plays on the phone.

## Phone-side memory gate

Dev Settings › Developer › Probes has **Win32 memory experiment**, also driven
with `pp ui --action probe:guest32-memory --shot-each-action`. The button runs
36 checks on a worker, frees both 4 GiB windows and reports its result in the
row and host log. It uses the very same C sources as the host tests, through
repo-relative source/header symlinks in `app/Sources/Guest32Experiment/`.
No Wine session, JIT acquisition, title/file modification or guest execution
is performed. The probe and a title launch refuse to run concurrently, and a
spent runtime must restart first: these windows can temporarily occupy the
bands Wine will later reserve. The target is not declared or linked in release.

[Device evidence](../../docs/evidence/2026-10-02-guest32-device-memory.md) shows
36/36 checks twice in one iOS process with real 16 KiB host pages. Software
backing is therefore possible in this app on the phone as well as the host.
This does not prove a checked FEX/Wine bridge is complete or fast enough for
gameplay.

# Software-separated Win32 memory experiment

**Superseded in direction** by [the Portal 2 plan](../../docs/PORTAL2-PLAN.md):
milestone 0 there removes most of this directory. Do not extend it further.

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
The optional simulator execution gate below now passes. Native hardware,
ARM64EC ABI and real dispatcher/linker execution remain untested. An eventual
phone experiment must enter through the developer UI. **No phone validation
occurred; Portal 2 remains unplayable.**

## Register-only ARM simulator execution gate (host audit only)

Install the optional hash-locked Linux x86-64 simulator wheel inside `.work`:

```sh
mkdir -p .work/guest32/arm-simulator/tmp
TMPDIR="$PWD/.work/guest32/arm-simulator/tmp" python3 -m pip install \
  --target .work/guest32/arm-simulator/deps --no-cache-dir --require-hashes \
  --only-binary=:all: --no-deps -r build/guest32/arm_simulator_requirements.txt
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
# Repeat with --simulate --sanitize for the instrumented host audit.
```

`--simulate` implies `--emit` and retains every independent IR/machine check.
The C++ audit exports the unmodified blocks, native register map and independent
x86 register outcomes. `arm_simulator_audit.py` executes the entry prologue,
register body and initial unlinked thunk using Unicorn 2.1.4. It replaces only
the native linker-address literal in a private copy with a high simulator exit
capture address; **the real linker/dispatcher do not execute**. All 144 blocks
and 18432 inputs pass, with poisoned temporary/upper registers, exact bounded
instruction paths, unchanged SP/NZCV, CPU-state canaries, checked header writes,
exit LR and guest-PC records. No guest memory is mapped into the simulator;
unexpected data accesses fail. Eight post-export corruption controls fail as
expected. Saved exports can be rerun using `arm_simulator_audit.py FILE`.

Logs/exports stay in `.work/guest32/separated-execution/`. This optional test
requires the prepared native build; neither simulator nor exported code is
bundled into the app or added to CI. ASan/UBSan cover the host audit/frontend/g32,
not FEX archives or the simulator. This is simulated instruction execution,
**not native ARM/iOS execution**, ABI validation, cache publication, concurrent
invalidation or a Win32 memory bridge. The next memory gate must distinguish
native CPU-state pointers from guest effective addresses before exercising
checked scalar loads/stores. [Simulator evidence and remaining boundaries](../../docs/evidence/2026-10-02-fex-register-arm-simulation.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Scalar guest-address IR gate (host audit only)

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir --sanitize
```

This separate **pre-optimization/RA** gate decodes and dispatches 17 real scalar
load/store forms at three guest PCs and three backing granules. A strict SSA
inspector compares addresses, access widths/directions, store values and
synthetic load-result register writes with independent x86 formulas for 19584
inputs. It covers base/displacement, scaled SIB, 16-bit address truncation,
absolute addresses, FS segment wrapping, byte/word/dword MOV and FNSTCW.
Unknown IR fails; loaded data is a sentinel, not an interpreted game load.

Native CPU-state storage remains above 4 GiB and is accessed only by validated
`LoadContext` offsets. Its FS base/control word are guest **values**, not native
pointers. Only the independently verified guest effective address goes to the
candidate checked scalar helper below, **outside FEX**. That adapter tests successful
reads/writes, cross-page read-only rejection, uncommitted/execute-only pages,
low-address blocking, end-of-space overflow and unchanged bytes/output on
failure. It is NOT evidence of a checked FEX emitter: no JIT block executes.
225 private post-generation IR corruptions are rejected for their intended
reasons (register source, scale, access width, native-context offset).

Optimized host builds and ASan/UBSan pass; FEX archives are uninstrumented.
Logs stay in `.work/guest32/separated-memory-ir/` (capture runner stdout there
when reproducing). This optional audit requires the prepared native build and
is not shipped or part of CI. The optional post-RA gate below now distinguishes
native addresses introduced by x87 stack lowering from these guest scalars.
[Scalar IR evidence](../../docs/evidence/2026-10-02-fex-scalar-memory-ir.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Allocated scalar-memory / native-provenance gate (host audit only)

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate --sanitize
```

`--memory-allocate` implies `--memory-ir`, retaining all existing pre-RA checks.
The real default optimizer/RA pipeline and IRValidation run with native ARM
register budgets. A strict physical-register inspector verifies the same 19584
scalar inputs after optimization, including addresses, widths, values, partial
register writes, exits and the candidate checked scalar helper. No JIT is created.

Nine real FXCH ST(1) graphs provide a native-memory counterexample: x87 lowering
introduces two FormContextAddress pointers and generic i128 FPR loads/stores
that were absent before optimization. The oracle checks all eight TOP values
and 256 tag patterns using native pointers above 4 GiB and vector slot-identity
tokens. Pointer/data tags follow physical-register writes, including reuse;
native addresses never reach g32 or an unchecked native dereference. This is
bounded lowering/provenance verification, **not floating-point computation or
x87 stack-fault correctness**. FEX itself gains no new provenance metadata.

All 585 private pre/post-RA corruption controls fail for their intended reasons;
post-RA fields are mutated alignment-safely and rechecked after restoration.
Optimized, ASan/UBSan, pre-RA and ARM-simulator regressions pass. Outputs stay in
`.work/guest32/separated-memory-ra/`; source/archive hashes are printed. This
optional gate requires the prepared native build, not CI or the app.
A candidate C scalar helper ABI is tested below, but checked FEX call emission
is still absent, as are other guest-memory families, Wine bridges and real
ARM64EC/iOS execution.
[Allocated-memory evidence](../../docs/evidence/2026-10-02-fex-allocated-memory-ir.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Raw scalar ARM emission gate (host simulator only)

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-simulate
# Add --sanitize for the host exporter/frontend/g32, not archives/simulator.
```

Use the optional hash-pinned simulator installation documented above.
`--memory-simulate` implies `--memory-allocate` and retains its scalar and FXCH
IR controls. The real native ARM backend emits the 153 scalar blocks; FXCH
remains an **IR-only** counterexample. The separate simulator validates 19584
inputs against independent x86 address/value/partial-register formulas,
including wrapping SIB/FS and address-size-16 arithmetic. Native FS/FCW loads,
header publication and linker reads stay in disjoint high mappings. Exact
access sequences, widths, values, complete byte canaries, SP/NZCV and unlinked
exit capture are checked. Only the native linker literal is adapted.

**Raw emission is not checked access.** Disposable mappings at each guest
number let the unmodified loads/stores run even at null, inaccessible pages or
across 4 GiB. The decoder's backing is separated, but simulated data is
identity-addressed: there is no g32 translation inside emitted code. Base-only
memory operands also rely on zero-extended static guest GPRs, unlike computed
addresses whose W-register arithmetic clears upper bits. Three deliberately
poisoned-upper-bit trials establish this precondition; 38 post-export corruption
controls validate the other observations. None establishes runtime fault
handling or preservation on rejected accesses.

Optimized, ASan/UBSan, scalar IR/RA and register simulator regressions pass.
Exports stay in `.work/guest32/separated-memory-emission/` and can be rerun with
`arm_memory_simulator_audit.py FILE`. This optional audit changes no shipped
emitter, patch/pin, app entry point or ABI. The candidate C helper below now
validates full widths and transactional rejection outside FEX; a checked
lowering must still call it correctly from emitted code, preserve native/live
state and handle fault returns before continuing.
[Raw-emission evidence](../../docs/evidence/2026-10-02-fex-scalar-arm-emission.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Candidate checked scalar helper ABI (host only)

`scalar_access.{h,c}` supplies an ordinary native C ABI for future bounded
scalar lowering, not a FEX preserve-all convention. Its only pointer argument
is the native `g32_space`; other inputs are a **64-bit** effective address, a
byte/word/dword width with optional store bit, and a 32-bit old destination or
store value. High address bits are rejected, not truncated; guest arithmetic
must wrap before calling. Complete widths/permissions are validated by g32
before reading/writing little-endian bytes. No native CPU-state/buffer pointer
or translated-pointer loan crosses the operand/result boundary.

The packed 64-bit return contains `g32_result` in the upper half and a 32-bit
value in the lower half. Successful loads replace only the low width bytes;
stores and all rejected calls retain the input value. Rejection changes no
guest bytes or VM metadata. The pre/post-RA audits above now exercise this
helper **from the host inspector**, not an emitted FEX call. Native FXCH pointers
continue to bypass it. The helper is not linked into the app or FEX.

`./pp test --quick` includes 7203 helper calls across native/16 KiB/64 KiB host
granules, every guest permission pair, page/top-of-space boundaries, uncommitted
and execute-only memory, malformed operations, wide/native addresses, native
state canaries and isolated spaces. The optional standalone audit repeats with
ASan/UBSan and rejects six private helper mutations:

```sh
python3 build/guest32/scalar_access_audit.py
```

Outputs stay in `.work/guest32/scalar-helper/`. This audit needs only Clang,
not FEX or the simulator. An iOS ARM64 object compiles; the separate simulated
ARM64 helper gate below now executes the compiled C access path. A future
FEX lowering must preserve all live caller-clobbered
registers/flags, branch on status before publishing a destination/continuing,
and deliver the guest-PC fault. Other instructions, atomics, concurrent VM
changes and ARM64EC interop are outside this contract.
[Helper evidence](../../docs/evidence/2026-10-02-guest32-scalar-helper.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Compiled scalar ARM64 helper gate (host simulator only)

With the optional hash-locked simulator above, Clang, LLD and llvm-nm:

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_arm_audit.py
```

This compiles the **unchanged** helper and g32 implementation as freestanding
AArch64 ELF, then executes their actual machine instructions. No simulator hook
implements an access check, produces a return value or rescues a bad address.
`scalar_arm_fixture.c` initializes private metadata in C and supplies a native
byte-copy routine. Declaration-only OS headers and section garbage collection
exclude allocation/protection/syscalls: this is not testing g32_create or a
native VM. Sparse simulator backing is above 4 GiB, RW even on guest-denied
pages; no low guest-number mapping exists. Artifacts stay in
`.work/guest32/scalar-arm/`; this optional test is not a CI/app dependency.

All 6327 calls pass across three granule values, every committed permission
pair, decommitted neighbors, unaligned/page/top-of-space boundaries, malformed
operations, poisoned/null spaces and actual native code/state/stack addresses.
An independent byte/status oracle, backing access census, metadata-write guard,
complete backing canaries, SP and AAPCS64 callee-saved GPR/SIMD checks accompany
seven compiled corruption controls. Both successful and rejected calls really
clobber volatile registers and NZCV: FEX must save live values **before** entry.

This is ordinary non-EC ARM64 **simulation**, not iOS hardware or the shipped
ARM64EC ABI. It does not preserve caller-clobbered state, emit a FEX call site,
classify native CPU-state memory IR, deliver a guest fault or run a title.
[Compiled-helper evidence](../../docs/evidence/2026-10-02-guest32-scalar-arm-helper.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Checked scalar call preservation gate (host simulator only)

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_call_audit.py .work/guest32/decode-audit/native
# --sanitize instruments the C++ fixture, not the FEX archives or simulator.
```

`scalar_call_emit.cpp` uses the **real** FEX Arm64Emitter's static spill/fill and
ordinary-ABI dynamic push/pop methods around a compiled helper call. This is a
manually constructed call-ABI fixture, **not a memory IR handler, decoded x86
block or runtime integration**. A native argument descriptor supplies already
computed wide addresses; native CPU-state pointers remain native spill targets.
The result survives restoration in FEX's x3 temporary. Status is tested without
altering NZCV before EAX publication or a test-only continuation marker; rejection
records the fixed guest PC in a native descriptor and stops, not a guest exception.

Both the real helper and an adversarial AAPCS64 assembly wrapper pass 6381
calls each. The wrapper runs the real helper before clobbering every permitted
live GPR/vector register and NZCV, including the upper halves of v8-v15.
Checks cover all 24 allocated GPRs, all 30 allocated full SIMD registers,
STATE/call-return stack register, SP, NZCV, helper arguments/entry count, backing
accesses, native spill-write bounds and byte canaries. Only EAX on success may
change; rejected calls touch no guest bytes and cannot take the success marker.
Seven independently emitted broken callers are rejected for missing static,
dynamic, SIMD or flag preservation, premature destination publication,
unchecked continuation and wrong guest PC.

Outputs stay in `.work/guest32/scalar-call/` and `.work/guest32/scalar-arm/`.
This gate is non-EC ARM64 simulation with SVE/AFP disabled. The closed decoded load gate below now exercises one real memory handler;
general effective-address lowering, provenance classification, real fault
delivery, concurrent VM lifetime, ARM64EC/iOS execution and product integration
remain unimplemented.
[Call-preservation evidence](../../docs/evidence/2026-10-02-fex-checked-scalar-call.md).
**Not checked on the phone; Portal 2 remains unplayable.**

## Closed checked scalar-load lowering gate (host simulator only)

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_lowering_audit.py .work/guest32/decode-audit/native
# --sanitize covers test/frontend/memory-handler/g32 TUs, not other archives.
```

Patch `fex/0016` supplies an ABI-neutral, test-only branch in the real
LoadMemTSO handler, never enabled by a shipped target. The audit decodes
`MOV EAX,[EBX]` from execute-only separated backing at three page-crossing
PCs, runs the default optimizer/RA/validation pipeline, strictly checks its
closed allocated graph and compiles the complete real backend block. Only
this single i32 load without an offset is supported. Generic native memory
paths remain untouched, not automatically provenance-classified.

6390 simulated loads pass with the compiled helper and adversarial AAPCS64
wrapper, plus five lowering corruption controls. Sparse high backing has no
low guest-number mappings. Complete-width/permission checks, all live
GPR/full SIMD/NZCV preservation, backing/native canaries, helper arguments,
status-before-EAX publication and normal-exit reachability are checked.
Rejection preserves EAX, records the decoded block PC and stops before the
normal exit. Wide/native EBX values reject without truncation; real 32-bit
static spills preserve even these deliberately invalid upper bits. Only the
normal exit-linker literal is adapted to capture, not a memory instruction.

This is a **closed single-instruction host gate**, not general pointer
provenance, multi-instruction PC tracking, guest fault delivery, guest TSO
ordering or a production memory bridge. Dynamic addresses/destinations,
scalar stores/partial loads, other memory families, concurrent VM lifetime,
ARM64EC/iOS and Wine integration remain unresolved. Outputs stay in
`.work/guest32/scalar-lowering/`; this optional experiment is not part of CI.
[Lowering evidence](../../docs/evidence/2026-10-02-fex-checked-load-lowering.md).
**Not checked on the phone; Portal 2 remains unplayable.**

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

# Portal 2 milestone 1, step 2: Wine window (in progress)

## Result and scope

The first part of [step 2](../PORTAL2-PLAN.md#step-2-the-window-in-wine-patchesmadeira-unix-or-wine-port)
reserves an owned, uncommitted 4 GiB window on the phone before attempting the
i386 main image. The owner-identity follow-up below isolates child startup
image state from the session and makes unix-side WoW64 identity owner-aware.
The suballocation follow-up prepares owner-local PEB32 storage inside the
window; the initial-thread follow-up pairs it with window-backed native and
32-bit TEBs. Address arithmetic, startup-state selection, view splitting and
pairing helpers are host-tested from the actual patches. The fixed-image
follow-up below now maps Portal 2's main image in the window, retaining guest
image/entry addresses and publishing PEB32's image base. The parameter
follow-up now publishes a normalized, window-backed PE32 parameter block and
environment. Guest image placement now accepts in-range ASLR suggestions and
searches window-local gaps; nonzero relocations are host-tested with Wine's
relocation kernel, not yet exercised on the phone. Startup explicitly stops
before the unwired native WoW64-loader paths. **No i386 code executes. Step 2
and milestone 1 are not complete.**

Initial reservation build: `5a54d17` plus madeira-unix 0049 and the host test changes.
IPA: `.work/out/20261003-115558-ed95fc62/Playport-26.5-ed95fc62.ipa` (dev).
SHA256: `ed95fc62184fbc8a855dec1571f037d78c63dd58788e6b4283013d54bb5ab1a5`.
Only `libntdll_unix.a` changes in `app/artifacts.tsv`; PE manifests and pins
are unchanged.

## Implementation

**madeira-unix 0049** in `build/ntdll-unix/virtual_ios.c`:

- An i386 main image triggers reservation before its existing map attempt.
  This does not change the session's machine, global limits or TEB layout.
- Each reservation is keyed by the current thread's **TEB->PEB**, using
  `ios_jit_current_peb()`, not the mutable global `peb`. No identity or a full
  registry fails explicitly; neither falls back to another process's window.
- A Wine `file_view`, initially `PROT_NONE`, protects the entire 4 GiB from
  ordinary Wine allocations. No guest pages, including the low 64 KiB, are
  committed. This is virtual address space, not 4 GiB of physical memory.
- `ios_wow64_current_base` and `ios_wow64_base_for_peb` export native unix-side
  queries. They take a mutex, **are not async-signal-safe**, and are not yet
  wired to the fault handler or exported to PE WoW64. The explicit-owner
  query is for a Mach exception handler's target, not the handler's own TEB.
- The reservation is deleted on its owner's process exit, through the normal
  view cleanup. Lock order is window registry then virtual mutex.

`wow64_window.h` defines the arithmetic used by the native reservation
round-trip diagnostic and the host test. A nonzero guest address translates
as `B + zext32(g)`; guest NULL stays host NULL. The inverse accepts NULL or a
pointer strictly above B and below B+4G, rejects other pointers **without
truncation**, and leaves its output unchanged on rejection. A missing,
misaligned, sub-floor or overflowing base is rejected. Low nonzero guest
addresses still translate into the inaccessible guard; arithmetic grants no
access permission. Handles and integers are untouched.

`build/wow64/test.py`, a C-test entry in `pp test`, applies just this header
from the patch into a scratch repository under `$PLAYPORT_BUILD/c-test`, then
compiles `window_test.c` with UBSan. CI needs no Madeira checkout. It checks
NULL, low guard offsets, 64 KiB, 2/4 GiB boundaries, out-of-window/wide host
pointers, invalid bases, two disjoint windows and 200,000 round trips. This
is an arithmetic test, not a host test of the Wine registry or fault service.

## Phone runs

The phone reported **18% battery, no external power** before testing. Testing
was not skipped. One device-lock session upgraded in place, retaining the
container, then ran both titles even though Portal 2's expected failure
returned nonzero:

```sh
./pp install --no-build
./pp ui --play app-620 --until done --wait 90 --shot --out .work/ui-runs/portal2-window
./pp ui --play app-367520 --until first-frame+10 --shot --out .work/ui-runs/portal2-window-hk
```

Both installed/result events name the IPA SHA256 above.

**Portal 2:** `.work/ui-runs/portal2-window/pull/s1-host.log` shows the session
root starting the i386 child, a reservation at **B=`0x7038010000`**, size
`0x100000000`, guard `0x10000`, committed 0, roundtrip `0x400000`. The image
still tries to map at `0x400000`, under `0x7fff0000`, and returns
`STATUS_NO_MEMORY` (`c0000017`). The child's teardown releases the same
window, and the session reports error 8; the UI result is
`launch=failed run_exe=-7`, exit 1. The screenshot shows **Portal 2 could not
start**, with JIT and Runtime checked and Game failed. This is evidence of
reservation/lifetime, not successful image mapping or mixed-mode execution.

**Hollow Knight:** `.work/ui-runs/portal2-window-hk` passes, exit 0,
`until first-frame+10`. JIT takes 2.41 s; first frame is **9.40 s** from Play.
The screenshot shows the game's main menu. No pool exhaustion, refused FEX
allocation or nonzero runtime-limit counters. Its log contains no
`[wow64-window]` line: x86-64 launches do not reserve the new window.

`pp build` passed (77 IPA checks), explicit `pp verify <IPA>` passed,
`pp test` passed (483 Python tests, C tests including the new UBSan test, all
three Swift packages), `pp slots` passed (150 slots, 149 calls), and
`git diff --check` passed outside the format-patch file (its blank context
lines and mail signature have required trailing spaces). The source commit's
`git show --check` is clean. `pp build --plan` reports no trees to rebuild.
Logs and screenshots remain under `.work/`.

## Owner identity follow-up (same step)

Latest source at build: `da47ea0` plus madeira-unix 0050 and wine-unix 0008.
Dev IPA: `.work/out/20261003-122000-92f9c501/Playport-26.5-92f9c501.ipa`.
SHA256: `92f9c50115606327d2c7f7ce7e6afb83bc994b4503edef87f36b1440a4a6ea9f`.
Only `libntdll_unix.a` changes in the committed build records; pins, PE
manifests, FEX and DXMT are unchanged.

The old child startup overwrote `main_image_info` and `main_module` until
`unix_init_startup_info()` returned, then restored the session's values.
Concurrent session threads could observe the child during that interval;
failed startup terminates the pthread and never reaches the restore.

- **madeira-unix 0050:** image/module write slots select private state stored
  in the starting thread's already allocated Wine `thread_data`, keyed by its
  TEB->PEB. Main-image writers and environment setup use those slots/readers.
  The parsed image identity is available before reservation or a failing map.
  Only successful startup publishes the child in the existing identity
  registry; a full registry now refuses the child instead of borrowing the
  session identity. Other startup globals are not made private here.
- **wine-unix 0008:** iOS `is_wow64()` reads `ios_cur_image_info()`, leaving
  non-iOS Wine unchanged. `thread_data` holds the temporary startup pointer.
  No new Darwin TLV storage is used: its lazy allocation would be unsafe in
  identity readers called from fault handlers. This does not make the locked
  **window base queries** signal-safe.
- Native `init_teb` inherits `RtlGetCurrentPeb()` from its creator rather than
  the drifting global `peb`. CPU-area lookup and WoW64 stack machine selection
  use the **target TEB's owner**, not the calling debugger/thread's identity;
  an absent CPU area returns NULL. This does not allocate a window-backed TEB.
- `build/wow64/owner_test.c` compiles the new production header and the actual
  write-slot, storage-getter and `is_wow64()` functions recovered from the
  patch hunks, with UBSan. Two concurrent mocked i386 startups cannot change
  the ARM64EC session image/module. Tests cover missing storage, NULL/wrong
  owners, nesting rejection, separate slots and a thread exiting without
  restoring state. This tests selection, **not Wine layouts, the full identity
  registry, TEB inheritance or the window allocator**.

The final phone session upgraded in place, then ran both titles, continuing
past Portal 2's expected nonzero exit. Commands use the same options as the
initial runs above, with output directories:

- `.work/ui-runs/portal2-owner-final`: at reservation,
  `current_machine=0x14c session_machine=0x8664 is_wow64=1
  session_is_wow64=0`, `wow_teb=0x0`. Window B=`0x7038010000` is reserved and
  released. Main-image mapping still fails `c0000017`; UI result is
  `launch=failed run_exe=-7`, exit 1. The screen still shows **Portal 2 could
  not start** (JIT/Runtime passed, Game failed). This proves early identity
  separation, not a mapped image or successful WoW64 bootstrap.
- `.work/ui-runs/portal2-owner-final-hk`: exit 0, `first-frame+10`, first frame
  **9.69 s**, JIT **2.63 s**. Screenshot shows the main menu; no pool
  exhaustion, refused FEX allocation or nonzero runtime-limit counters.

Both result events carry the latest IPA SHA256 above. Before the first
owner-identity run the phone was at 35% battery, connected to external power
and charging. `pp build` passes 77 IPA checks; `pp test` passes 483 Python
tests, all C tests including both UBSan WoW64 tests, and all three Swift
packages. `pp slots` passes (150 slots, 149 calls). Both source commits pass
`git show --check`; the superproject diff outside format-patch files passes
`git diff --check`. `pp build --plan` reports no trees to rebuild.

## Suballocation follow-up (same step)

Latest source at build: `f7e39b4` plus madeira-unix 0051 and host tests.
Dev IPA: `.work/out/20261003-123557-40618838/Playport-26.5-40618838.ipa`.
SHA256: `40618838186dcf025a9f4cb7727af7a7cc161401775205164842a89834b2c410`.
Only `libntdll_unix.a` changes in the committed build records; pins and PE,
FEX and DXMT outputs are unchanged.

**madeira-unix 0051** replaces the registry's single view pointer with a
stable base and owner-local PEB32 storage. `wow64_views.h` splits a holdback
view into an allocation and up to two `VPROT_WOW64_HOLE` gaps. There is no
unmap/remap interval or `MAP_FIXED`; host protection and all descriptors are
obtained before modifying the tree. Invalid ranges, overlap, descriptor
exhaustion and protection failure leave the tree and output unchanged. The
native allocation wrapper selects the explicit owner under the window lock,
then takes `virtual_mutex`; no missing-owner fallback or signal-safe API.
Teardown walks every view inside the owner's disjoint range rather than
following a stale descriptor after a split.

Reservation now claims one RW/committed host page at guest `0x7ff00000` for
PEB32. This is **storage only**: not a native PEB copy, not populated, and not
linked through `wow_peb` or a paired TEB. The low 64 KiB and all other gaps
remain PROT_NONE. The allocator currently supports fixed guest placements
and reserved/RW views only; general VM routing, free/reuse, image/file and
executable views are not implemented.

`build/wow64/views_test.c` uses the production header, owner-selection wrapper
and teardown function extracted from the patch. Real 4 GiB PROT_NONE host
mappings back a **mock Wine view tree/page-metadata layer**; it does not test
Wine's rbtree/free-range bookkeeping or signal masking. With UBSan it tests
boundaries/overflow/alignment, untouched outputs on failure, both descriptor
failure positions, protection failure, complete gap coverage, exact-fit reuse,
zero-filled RW allocations, independent contents at identical guest addresses,
unknown/NULL owners, eight concurrent claims (one success per owner), real
SIGSEGV on the low guard, and teardown of one window leaving the other intact.

One phone-lock session upgraded in place and ran both titles, continuing past
Portal 2's expected nonzero result. Both result events name the SHA256 above.
The pre-run phone check reported 57% battery, not externally powered.

- `.work/ui-runs/portal2-suballoc`: B=`0x7038010000`, PEB32 host
  `0x70b7f10000`, guest `0x7ff00000`, bytes `0x4000`, `paired=0`.
  Child `Machine=0x14c`, session `Machine=0x8664`, `wow_teb=0x0`.
  Main-image mapping still fails `c0000017`, then the window is released;
  UI result `launch=failed run_exe=-7`, exit 1. Screenshot shows **Portal 2
  could not start**, JIT/Runtime passed, Game failed. This checks allocation
  and split-view teardown on Wine/iOS, not PEB contents or guest execution.
- `.work/ui-runs/portal2-suballoc-hk`: `first-frame+10`, exit 0; first frame
  **8.29 s**, JIT **2.50 s**. Screenshot shows the main menu. Pool exhaustion,
  FEX-band refusals and all runtime-limit counters remain zero.

`pp build` and explicit `pp verify` pass (77 IPA checks), `pp test` passes
(483 Python tests, C tests including the three WoW64 UBSan tests, all three
Swift packages), and `pp slots` passes (150 slots, 149 calls). The source
commit's `git show --check` and the superproject's non-patch whitespace check
pass. `pp build --plan` reports no trees to rebuild. Logs/screenshots stay
under `.work/portal2-suballoc` and `.work/ui-runs/`.

## Initial TEB-pair follow-up (same step)

Latest source at build: `41b38b0` plus madeira-unix 0052.
Dev IPA: `.work/out/20261003-125233-3ea1b61a/Playport-26.5-3ea1b61a.ipa`.
SHA256: `3ea1b61a1f411ed26661c2aea45c4209234272879d2a5ccbc76d15c8175cc405`.
Only `libntdll_unix.a` changes in the committed build records; pins and PE,
FEX and DXMT outputs are unchanged.

**madeira-unix 0052** bootstraps the initial thread, not general WoW64:

- The old native TEB is near 4 GiB, while the window is around `0x7000000000`.
  A signed 32-bit `WowTebOffset` cannot span that distance. Claim one 16 KiB
  RW view at guest `0x7fe00000` and move the pristine native TEB there, beside
  TEB32 at guest `0x7fe02000`. Offsets are ±`0x2000`; Wine's debug-info page
  fits after TEB32. Production compile-time assertions check the real layouts.
- Copy native state, preserving stack/external pointers and GdiTebBatch's
  syscall table/frame. Rebase its self, empty activation-list and Unicode
  pointers. Reject a source with an existing pair, CPU area, live activation
  list or nonstandard self-references. This is before child PE code executes.
- Native pointers stay host-relative. TEB32's self, PEB, activation-list,
  Unicode buffer and native backlink (`GdiBatchCount`) are guest addresses.
  Client IDs remain integers. PEB32 receives selected bootstrap scalars from
  the owner and parsed image; loader, heap, image and process parameters stay
  NULL. No native PEB-layout copy and no global `wow_peb` assignment.
- `thread_data` and its thread-list entry do not move. Under the window and
  virtual locks, publish the new TEB through the patcher pthread TLS key and
  `data->teb`, preserving signal/kernel-stack storage. The loader refreshes its
  local TEB after startup. No extra `signal_alloc_thread` call is needed: it
  is a no-op at this pin. The phone's pre-PE syscall frame is still NULL;
  the host test separately exercises preservation of a non-NULL frame.
- Retain the old native TEB outside the session free list. Restore it and its
  TLS pointer **before** deleting the window, since exit logging and the
  process-thread longjmp still need a valid TEB. Refuse teardown from the
  wrong thread or after TLS publication failure rather than unmapping a live
  pointer. This is initial-thread-only lifetime management, not a solution
  for arbitrary live sibling threads. Secondary WoW64 thread allocation
  explicitly returns `STATUS_NOT_SUPPORTED` until that path is implemented.

`build/wow64/pair_test.c` uses the production `wow64_pair.h` and pairing/
restore functions extracted from the patch, with **mock Wine types and view
claims**, real 4 GiB host mappings and pthread TLS, under UBSan. It checks
self/PEB/backlink and embedded-buffer conversion round trips; offset symmetry;
IDs; scalar-only PEB32; native syscall/stack state and list-entry preservation;
missing/wrong owner and incompatible source rejection; view/TLS failure before
publication; wrong-thread/TLS-failed restoration; restoration before protecting
the old pair inaccessible; and two concurrent owners with identical guest
addresses. It does not test Wine's actual rbtree, signal masking, Mach exception
handling, full PEB initialization or execution after a successful image map.
The build compiles the actual Wine layouts and the phone checks the lifecycle.

One phone-lock session upgraded in place and ran both titles, continuing past
Portal 2's expected nonzero result. Both result events name the SHA256 above:

- `.work/ui-runs/portal2-pair`: B=`0x7038010000`, native TEB
  `0x70b7e10000`, TEB32 `0x70b7e12000`, PEB32 `0x70b7f10000`.
  Logs show self32=`0x7fe02000`, PEB32=`0x7ff00000`, native backlink32=
  `0x7fe00000`, reverse offset -8192, OS 10.0, subsystem 2 and NULL image/
  parameters. Child `Machine=0x14c` remains separate from session `0x8664`;
  `wow_teb` is now non-NULL. TLS publication matches, then the unchanged image
  map fails `c0000017`. Exit restores the old native TEB (`tls_match=1`) and
  releases the window. UI result `launch=failed run_exe=-7`, exit 1; screenshot
  still shows **Portal 2 could not start**, JIT/Runtime passed, Game failed.
- `.work/ui-runs/portal2-pair-hk`: `first-frame+10`, exit 0; first frame
  **8.13 s**, JIT **2.35 s**. Screenshot shows the main menu. Pool exhaustion,
  FEX-band refusals and all runtime-limit counters remain zero.

`pp build` and explicit `pp verify` pass (77 IPA checks), `pp test` passes
(483 Python tests, C tests including four WoW64 UBSan tests, all three Swift
packages), and `pp slots` passes (150 slots, 149 calls). The source commit's
`git show --check` and the superproject's non-patch whitespace check pass.
`pp build --plan` reports no trees to rebuild. Logs/screenshots stay under
`.work/portal2-pair` and `.work/ui-runs/`.

## Fixed-image follow-up (same step)

Source at build: `37e9394` plus madeira-unix 0053 and host tests.
Dev IPA: `.work/out/20261003-133126-6da1d49c/Playport-26.5-6da1d49c.ipa`.
SHA256: `6da1d49c614ab6045e8d3a6a5604d308bddc59967c898696f4a9b7881c0e4e5f`.
Only `libntdll_unix.a` changes in the build records; pins, PE, FEX and DXMT
are unchanged.

**madeira-unix 0053** uses Wine's existing PE header/section mapper, not a
second loader. The owner base is queried before taking `virtual_mutex`,
preserving registry lock order. Fixed preferred guest placement is claimed
inside that window, respecting the low guard, 16 KiB rounding and the
image's 2/4 GiB large-address-aware limit. Server ASLR suggestions are ignored
for now; collisions fail rather than falling back to a host allocation.

Unix module pointers and wineserver VM views name **host storage**; returned
image info, the PE header and PEB32's image base name **guest identity**.
Relocation delta is zero at the preferred guest base, never B. A new view flag
retains logical EXEC while host protection drops native EXEC and bypasses
pool copies; these images do not enter the global sub-floor image table.
On mapping failure, anonymous PROT_NONE backing atomically replaces any file
pages, leaving a reusable holdback rather than unmapping the reservation.
A replacement failure retains the descriptor until owner teardown.

`build/wow64/image_test.c` compiles `wow64_image.h` and the actual modified
`mprotect_range` recovered from the patch. UBSan tests use real mappings,
private file backing, and **mock Wine views/page bytes/protection conversion**:
NULL/invalid inputs, rounded 2/4 GiB edges, wide-address rejection, untouched
failure outputs, descriptor/protection failure, identical guest addresses in
disjoint windows, logical EXEC with physical NX/read-only/RW pages, rollback
failure, zero-filled retry, guard and teardown isolation. Non-window views
still take `mprotect_exec`. This does not test Wine's full rbtree, server VM
queries, nonzero guest relocations, general VM or FEX execution.

One phone-lock session upgraded in place and ran both titles. Both result
events name the SHA256 above:

- `.work/ui-runs/portal2-image-final`: B=`0x7038010000`, image host
  `0x7038410000`, guest/header/PEB32 image `0x400000`, size `0x5c000`,
  transfer address `0x4017d1`, delta 0. `virtual_map_main_module` returns
  informational `STATUS_IMAGE_NOT_AT_BASE` (`40000003`) because the server
  records high host storage. Startup then deliberately terminates with
  `STATUS_NOT_SUPPORTED` (`c00000bb`), before the old parameter builder or
  session ARM64EC PE loader can consume incompatible pointers/layouts.
  TEB restoration and window release still succeed. **No i386 DLL load or
  instruction execution is claimed.** UI result remains
  `launch=failed run_exe=-7`, exit 1; screenshot shows **Portal 2 could not
  start**, JIT/Runtime passed and Game failed.
- `.work/ui-runs/portal2-image-final-hk`: `first-frame+10`, exit 0; first
  frame **8.24 s**, JIT **2.51 s**. Screenshot shows the main menu. Pool
  exhaustion, FEX-band refusals and runtime-limit counters remain zero.

`pp build` and explicit `pp verify` pass (77 IPA checks), `pp test` passes
(483 Python tests, all C tests including five WoW64 UBSan tests, all three
Swift packages), and `pp slots` passes (150 slots, 149 calls). Source
`git show --check` and the non-patch whitespace check pass; `pp build --plan`
reports no trees to rebuild. Logs/screenshots stay under `.work/portal2-image`
and `.work/ui-runs/`.

## Process-parameter follow-up (same step)

Source at build: `31f0b9c` plus madeira-unix 0054 and host tests.
Dev IPA: `.work/out/20261003-135019-5390ca2b/Playport-26.5-5390ca2b.ipa`.
SHA256: `5390ca2bb181754cd7f9aeaf39043d7fc75b59ab9fc8addca289c24444aa34c8`.
Only `libntdll_unix.a` changes in the build records; pins, PE, FEX and DXMT
are unchanged.

**madeira-unix 0054** uses Wine's existing native startup-data builder, then
packs a PE32 copy into one owner-local RW view at guest `0x7e000000`. The
bootstrap placement is fixed and capped at 16 MiB; it is not a general process-
parameter allocator. All eight string buffers and the environment live in
that same view. Addresses are checked guest offsets, not truncated host
pointers; standard/console/current-directory handles remain plain integers.
RuntimeInfo remains an opaque byte blob, including odd byte lengths. String
capacity padding is zeroed; environment size and double-NUL termination are
validated. Unsupported drive-directory/package pointers and overflowing
scalar fields fail explicitly, before allocation/publication.

PEB32's parameter pointer is published only after packing succeeds. Heap
option scalars, processor count, debug/global flags and critical-section
timeout are taken from the **owner**, not the session. `load_global_options`
now receives the current PEB explicitly: it previously wrote the mutable
file-scope `peb` despite `init_peb`'s owner-local shadow. The global `wow_peb`
is still untouched. PEB32 loader/heap pointers remain NULL; this is **not full
PEB/loader initialization**. The temporary native parameter allocation is
released at the retained fail-closed boundary, before the session's ARM64EC
loader can run on this i386 child. The window view lives until owner teardown.

`build/wow64/params_test.c` compiles the production packing header and the
publication function extracted from the patch, with UBSan, **mock Wine
layouts/allocation and real disjoint window mappings**. It checks invalid/
NULL inputs, normalized flags, malformed strings/environments, binary and
empty fields, padding, unchanged outputs/storage on rejection, allocation
failure and duplicate/wrong-owner publication, oversized heap options,
integer handles, a 16 MiB size limit, exact top-of-window bounds, unchanged
source parameters and independent contents at identical guest addresses.
It does not test Wine's actual layouts/rbtree, server serialization, general
VM, native WoW64 loader, guest heap creation or i386 execution. The build
compiles Wine's actual layouts, and the phone checks publication/lifetime.

One phone-lock session upgraded in place and ran both titles, continuing
past Portal 2's expected nonzero exit. Both result events name the SHA256
above. The pre-run phone check reported 48% battery, not externally powered.
Commands are as above, with output directories:

- `.work/ui-runs/portal2-params`: B=`0x7038010000`, parameter host
  `0x70b6010000`, guest `0x7e000000`, size `0x4000`; PEB32 image remains
  `0x400000`. Command-line buffer is guest `0x7e0004e8`, environment is
  guest `0x7e000568`, 5,670 bytes; normalized=1, loader=0, heap=0. Startup
  then deliberately terminates with `STATUS_NOT_SUPPORTED` (`c00000bb`)
  before the native WoW64 loader. TEB restoration and window release still
  succeed. **No i386 DLL loading or code execution is claimed.** UI result
  remains `launch=failed run_exe=-7`, exit 1; screenshot shows **Portal 2
  could not start**, JIT/Runtime passed and Game failed.
- `.work/ui-runs/portal2-params-hk`: `first-frame+10`, exit 0; first frame
  **9.25 s**, JIT **2.44 s**. Screenshot shows the main menu. Pool exhaustion,
  FEX-band refusals and runtime-limit counters remain zero.

`pp build` and explicit `pp verify` pass (77 IPA checks), `pp test` passes
(483 Python tests, all C tests including six WoW64 UBSan tests, all three
Swift packages), and `pp slots` passes (150 slots, 149 calls). Source
`git show --check` and the non-patch whitespace check pass; `pp build --plan`
reports no trees to rebuild. Logs/screenshots stay under `.work/portal2-params`
and `.work/ui-runs/`.

## Guest-placement follow-up (same step)

Source at build: `855eb14` plus madeira-unix 0055 and host tests.
Dev IPA: `.work/out/20261003-141205-a3cac212/Playport-26.5-a3cac212.ipa`.
SHA256: `a3cac212b94653f15de2f25062e2ebb6b308d5fc2479dce3b4a8af5ca5d9bb8c`.
Only `libntdll_unix.a` changes in the build records; pins, PE, FEX and DXMT
outputs are unchanged.

**madeira-unix 0055** adds guest-space placement around the existing fixed
claim primitive, without changing Wine's PE section mapper:

- In-range, aligned server ASLR suggestions are tried for movable dynamic-base
  images, then the preferred base, then an owner-local gap. Dynamic DLLs search
  top-down; others bottom-up. All candidates respect the guard, 64 KiB allocation
  alignment, host-page rounding, large-address-aware 2/4 GiB limit and inclusive
  caller bounds. Wide/unaligned hints are ignored, never truncated. Stripped or
  flat images stay fixed. Descriptor/protection failures do not trigger fallback.
- Gap search walks containing window views, not Wine's host free ranges, which
  correctly consider the whole window unavailable. General VM/free routing and
  coalescing adjacent holdbacks are still absent.
- Host storage and preferred/selected guest identity stay separate. PE32 fixups
  use only the selected-minus-preferred guest delta. Validate every block/type/
  target before modifying any target, rejecting missing directories, unsupported
  types, out-of-image targets and directory self-modification. Wine's existing
  relocation-block kernel is moved into a shared header; HIGH/LOW/HIGHLOW use
  memcpy and unsigned arithmetic for unaligned targets and modulo-2^16/32 adds.
  Native DIR64/THUMB handling is unchanged. No new PE loader is implemented.
- After completed mapping, normalize the server's `STATUS_IMAGE_NOT_AT_BASE`
  warning for window images only. Its host VM base differs from guest ImageBase
  even at the preferred guest base; passing this warning to the native loader
  would make it apply the host window offset as a second relocation. Server
  failures and non-window warnings remain unchanged.

`build/wow64/placement_test.c` compiles both production headers from the patch,
with UBSan, real disjoint window mappings and the existing **mock Wine view
metadata**. It tests hints/collisions, bottom/top gap selection, inclusive bounds,
2/4 GiB rounding, stripped/flat rejection, allocation/protection failures with
unchanged outputs, isolated owners, rollback/retry, guest-only positive/negative/
wrapping and unaligned HIGH/LOW/HIGHLOW fixups, malformed and bad-later-block
rejection before any mutation, multiple valid blocks, native DIR64 and status
normalization. It does not run the PE section mapper, wineserver or native loader.
**Nonzero relocation and collision placement are not phone-validated yet.**

One phone-lock session upgraded in place and ran both titles, continuing past
Portal 2's expected failure. Commands use the same options as previous runs;
both result events carry the SHA256 above. Before testing, battery was 44%,
not externally powered.

- `.work/ui-runs/portal2-placement`: B=`0x7038010000`, preferred/selected
  guest image `0x400000`, host `0x7038410000`, size `0x5c000`, transfer
  `0x4017d1`, delta 0. `virtual_map_main_module` now returns **success (0)**,
  not `40000003`; parameters remain published, loader/heap remain NULL.
  The retained loader boundary returns `c00000bb`, restores the TEB and
  releases the window. **No i386 DLL loading or instruction execution.**
  UI result `launch=failed run_exe=-7`, exit 1; screenshot shows **Portal 2
  could not start**, JIT/Runtime passed, Game failed.
- `.work/ui-runs/portal2-placement-hk`: exit 0, `first-frame+10`; first frame
  **9.26 s**, JIT **2.42 s**. Screenshot shows the main menu. Pool exhaustion,
  FEX-band refusals and runtime-limit counters remain zero.

`pp build` and explicit `pp verify` pass (77 IPA checks), `pp test` passes
(483 Python tests, all C tests including seven WoW64 UBSan tests, all three
Swift packages), and `pp slots` passes (150 slots, 149 calls). Source
`git show --check` and the non-patch whitespace check pass. Logs/screenshots
stay under `.work/portal2-placement` and `.work/ui-runs/`.

## Conversion inventory and remaining work

The initial inventory found that the plan's original assumption about
unix-side `is_wow64()` was incorrect at the Wine pin: it read **global
`main_image_info.Machine`**, while `get_wow_teb()` read `WowTebOffset`.
Child startup overwrote/restored the image global; the follow-up above
fixes that identity path. `virtual_alloc_first_teb` still returns early for
the child's already allocated TEB, so it cannot create the child's WoW64
TEB/PEB as it does for a real Wine process. `wow_peb`, `teb_block_size`,
`user_space_wow_limit` and their allocators are still global. Those must
become owner-aware too; changing only `get_ptr` would expose the wrong
layouts and limits.

A reproducible initial grep inventory on the patched Wine PE source:

```sh
rg -n '\b(ULongToPtr|PtrToUlong)\s*\(' \
  .work/run/pe/wine/dlls/wow64 .work/run/pe/wine/dlls/wow64win
rg -n 'wow_peb|wow64_params|PtrToUlong|ULongToPtr' \
  .work/run/unix/mythic/build/ntdll-unix/{env,virtual,loader,thread,signal_arm64}_ios.c
rg -n 'is_wow64|WowTebOffset|user_space_wow_limit' \
  .work/run/unix/wine/dlls/ntdll/unix/unix_private.h
```

| File (under Wine `dlls/`) | `ULongToPtr` | `PtrToUlong` |
| --- | ---: | ---: |
| wow64/process.c | 9 | 7 |
| wow64/security.c | 4 | 4 |
| wow64/sync.c | 1 | 7 |
| wow64/syscall.c | 10 | 23 |
| wow64/system.c | 0 | 11 |
| wow64/virtual.c | 11 | 6 |
| wow64/wow64_private.h | 17 | 4 |
| wow64win/gdi.c | 3 | 6 |
| wow64win/user.c | 0 | 31 |
| wow64win/wow64win_private.h | 10 | 1 |

These **65 + 100 textual uses are not an audited conversion set**: some are
handles or integers, and raw casts/helpers add more. No sites have been
routed yet. In particular, callbacks/APCs pack guest addresses in integers;
blind macro replacement would change their ABI.

Next in this same step: general VM routing and remaining PEB32 loader/heap
initialization, then phone validation of nonzero image relocations when the
loader can reach an image needing them. Startup parameters are window-backed,
not a general allocator; only the initial TEB is paired.
General paired thread allocation, reuse/free and multi-thread teardown are
pending, and secondary WoW64 threads are explicitly rejected. Remove the
fail-closed startup boundary only after its downstream paths are wired.
The fixed-view suballocator does not yet implement general VM or free/reuse. WoW64 identity
is owner-aware, but the legacy `wow_peb`, TEB free lists and WoW64 allocation
limits remain global; this bootstrap leaves them unchanged. Other startup
globals (`peb`, argv, startup info) still rely on serialization. Then PE-visible
base query and file-by-file pointer/return-value conversion; stack/context/
callback/APC/exception setup; and target-owned whole-window Mach fault servicing
with a count. The existing global sub-floor image table cannot represent the
same guest address in two different process windows. Do not advance to step 3
or mark step 2 done from this bootstrap test.

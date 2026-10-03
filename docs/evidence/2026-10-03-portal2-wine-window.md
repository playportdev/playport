# Portal 2 milestone 1, step 2: Wine window (in progress)

## Result and scope

The first part of [step 2](../PORTAL2-PLAN.md#step-2-the-window-in-wine-patchesmadeira-unix-or-wine-port)
reserves an owned, uncommitted 4 GiB window on the phone before attempting the
i386 main image. The owner-identity follow-up below isolates child startup
image state from the session and makes unix-side WoW64 identity owner-aware.
Address arithmetic and startup-state selection are host-tested from the
actual patches. **Portal 2 still fails at its low-address image mapping;
no paired TEB32/PEB32 is allocated and no i386 code executes. Step 2 and
milestone 1 are not complete.**

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

Next in this same step: window suballocation and owner-local paired
TEB32/PEB32 allocation. WoW64 identity is owner-aware now, but the legacy
`wow_peb`, TEB free lists and WoW64 allocation limits remain global. Other
startup globals (`peb`, argv, startup info) still rely on serialization.
Then image/VM mapping inside the reserved window (currently a holdback, not
a suballocator); guest-relative image metadata/relocations;
PE-visible base query and file-by-file pointer/return-value conversion;
stack/context/callback/APC/exception setup; and target-owned whole-window
Mach fault servicing with a count. The existing global sub-floor image table
cannot represent the same guest address in two different process windows.
Do not advance to step 3 or mark step 2 done from this reservation test.

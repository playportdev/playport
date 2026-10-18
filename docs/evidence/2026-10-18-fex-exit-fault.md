# FEX faults at process exit with a warm disk cache (PLA-395)

**Linear:** [PLA-395](https://linear.app/playportdev/issue/PLA-395),
[PLA-394](https://linear.app/playportdev/issue/PLA-394),
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Plan:** [low-VA CEF](../plans/2026-10-16-cef-low-va-build.md).
**Fix:** `patches/fex` 0047. Branch `dev/pla-291-rockstar-launcher`.

**Question:** With a warm FEX disk cache (decision 0056), the first Launcher.exe,
RockstarErrorHandler, `RockstarService start` and dxdiag fault when they exit, in
`libarm64ecfex.dll+0x1d46c` (`ContextImpl::CompileBlock`, a load from null+0x48). The
processes never reach `exit_process`, keep their JIT pool copies, and the next Launcher.exe
waits forever on a lock in the dead process's FEX code tracker. Cold-cache and cache-off
Opens do not fault. Why?

## The fault

Host logs are `$PLAYPORT_BUILD/ui-runs/<run>/pull/s1-host.log`. Offsets are in the
`libarm64ecfex.dll` of the build (symbols from `llvm-symbolizer`).

In `20261018T075924`, thread 0048 (the first Launcher.exe):

- l.13974: `NtTerminateProcess(handle=0x0)`, then `RtlExitUserProcess` goes on to
  `LdrShutdownProcess`. On iOS, Wine process-attaches the FEX DLL (ntdll
  `load_arm64ec_module`, so that mingw's `DllMainCRTStartup` runs FEX's static
  constructors). So the shutdown also detaches it, and the CRT runs the static destructors
  of `Source/Windows/ARM64EC/Module.cpp` (`CTX`, `SyscallHandler`, `InvalidationTracker` and
  the others, l.195–202). In `DllMainCRTStartup`, `DllMain` is called before `_CRT_INIT`
  runs the destructors.
- l.13976–14560: 570 `[vfree]` lines from the teardown, which frees rpmalloc spans and
  FEX's code buffer (`[jit-pool] tail FREE rx=0x13e190000`). The cold-cache Open
  `20261017T201653` makes 23 frees there, then reaches
  `NtTerminateProcess(handle=0xffffffffffffffff)` and `exit_process`.
- After the code buffer is freed, one more decommit (`base=0x7c150e1000 size=0xf000`)
  goes through the ARM64EC `NtFreeVirtualMemory` wrapper to FEX's `NotifyMemoryFree`.
  The tracker is destroyed, but a destroyed `std::optional` still reads as engaged. So the
  call reaches `InvalidationTracker::InvalidateFreedInterval` →
  `InvalidateIntervalInternal`, whose first statement is the virtual
  `CTX.GetCodeInvalidationMutex()` (`InvalidationTracker.cpp:707`). `CTX` is a reference
  to the freed context.
- The stale vtable slot read `0x30000010a`. The ARM64EC call checker treated it as x64
  (`$iexit_thunk$cdecl$i8$i8` on the stack), and FEX's JIT, entered with a guest state
  holding host pointers (rsi = `VirtualFree`, the rdx/r8 of the decommit), went through
  `ExitFunctionLink` to `CompileBlock(0x30000010a)`. Its
  `SyscallHandler->PreCompile()` (`Core.cpp:2202`) read the vtable of the freed syscall
  handler, at `0x7c150b00b0`: zero, rpmalloc's free-list link. That gives the load at
  null+0x48 (l.14614–14632, `[mach_exc] pc PE: libarm64ecfex.dll+0x1d46c`; the frame chain's
  first return address, `+0x153a40`, is in `InvalidateFreedInterval` right after that
  virtual call, and the next is in ntdll).
- The exception handler could not deliver: l.15209 `[exc-stack] cannot deliver exception …
  aborting thread`.

RockstarErrorHandler (0054, l.15320) took the same path, with the same `rip=0x30000010a`.
Its exception then faulted again in a loop until the emulator stack ran out
(l.16511–16519). The `[stack-ovf] … ORIGINAL CALLER after 16 recursive frames … container
being destroyed` line is that handler's generic hint. Here the recursion is the
exception re-delivery, not a destructor. `RockstarService start` (00e4, l.32636–32643) and
dxdiag (0194, l.41102–41109) end the same way.

**Why only a warm cache:** a warm cache keeps the disk cache's in-memory index (about
4,000 hits in the first Launcher.exe). The teardown then frees enough memory that rpmalloc
still decommits spans after the context is freed. With a cold cache the last free comes
before that, and nothing calls into the dead objects.

The second Launcher.exe's wait on `tracker+0x50` of the first (PLA-394 report) is a
consequence: the aborted thread never released it, and the dead process kept its pool
copies.

## The fix

`patches/fex` 0047 (`Source/Windows/ARM64EC/Module.cpp`, iOS only):

- FEX now has its own `DllMain`. On `DLL_PROCESS_DETACH` it sets `ProcessDetaching`
  before the CRT runs the destructors.
- While that is set, every notification that reaches the tracker returns:
  - memory alloc, free and protect;
  - image map, section map and unmap;
  - the instruction-cache flushes and memory-dirty notifications;
  - the read-file notification.
- The teardown itself is unchanged: it still frees FEX's memory and returns the code
  buffer to the pool.

Games keep the disk cache on. None of the recent Hollow Knight runs exits through
`NtTerminateProcess` (the driver ends the app), so no game run shows this signature. A game
that exits on its own with a warm cache would have taken the same path.

## On the phone

IPA `f42c95fc9a2326ab8da9b52f641afcdf6c0de051b459f03ac4566d95903d7d8b` (fex 0047), one lock
session. The Rockstar launcher's saved settings were `{"runtime":"env.FEX_SMCCHECKS=none",
"diskCache":true}` for both Opens, then cleared.

- **Hollow Knight `20261018T093427`:** first frame +10.16 s. The final screenshot shows the
  title menu with the touch controls.
- **Open 1 `20261018T093540`:** this run warmed the cache for the new FEX build. The first
  Launcher.exe's first `[diskcache]` line has 43 hits.
  - 0 `cannot deliver exception`, 0 faults at `+0x1d46c`, 0 `EMULATOR STACK EXHAUSTED`.
  - 3 `exit_process` and 5 pool `RECLAIM` lines.
  - Final pool: head 472 MiB (454 live), tail 425 MiB (401 live), head exhausted ×24, tail
    refused ×1, tail fatal 0.
  - Sign In form with its text and the cookie notice at 240 s.
- **Open 2 `20261018T094035`, warm:** the first Launcher.exe has 3,915 hits and the second
  4,096 (0 misses).
  - 0 exit faults of any of these kinds.
  - The first Launcher.exe (l.13534–14239), RockstarErrorHandler (l.14431–15067) and
    `RockstarService start` (l.31696) reach `exit_process`. Their RECLAIMs free 0x3fec000,
    0x1ba4000 and 0x24a8000 bytes, the same as the cold Open `20261017T201653`.
  - This run started no dxdiag.
  - Final pool: head 463 MiB (454 live), tail 433 MiB (401 live), head exhausted ×4, tail
    refused 0, tail fatal 0. Band peak 13,641 MB.
  - Four Social Club helpers still ended with `c0000017` at l.61515–62575.
  - Screenshots:
    - 45 s: "Connecting to Rockstar Games Services".
    - 60 and 90 s: the Sign In form (Email, Password, Auto Sign In) with its text, under
      the cookie notice.
    - 150 and 240 s: the same.
  - Social Club's log reaches `FINISHED` at 4,745 ms.

The tail is no smaller than with the cache off (~420 MiB in `20261018T085305` and
`20261018T090949`), but the head ran out far less often (4 against 40–80). A less greedy pool
tail is the next lever. Rockstar's text logs are kept in the build area
(`agent-notes/pla370-cef/inputs/pla395-rockstar-logs/`).

With the fault fixed, the launcher's disk-cache workaround (81082f9) is reverted, and its
Open uses FEX's default, the cache on.

## After the revert

IPA `7d544b538865311316e583ef8ca45d11803d8cd4a10fb6ad28b10d80355011dc` (the revert of
81082f9, so the launcher's disk cache is on by default).

- **`20261018T095302`, saved settings cleared (`{}`), so no `FEX_SMCCHECKS=none`:**
  - The first Launcher.exe got 3,864 hits. No exit fault (0 `cannot deliver exception`,
    0 at `+0x1d46c`), 3 `exit_process`.
  - The pool's tail grew to 561 MiB (481 live), against a head of 336 MiB (251 live).
  - From 90 s the screen showed Rockstar's "The CEF browser for the Rockstar Games Launcher
    crashed and could not restart" dialog.
  - Every earlier Open used the owner's `FEX_SMCCHECKS=none`, so this run is not a
    comparison for the cache.
- **`20261018T095950`, with only `{"runtime":"env.FEX_SMCCHECKS=none"}`, the disk cache at
  its default:**
  - 4,076 hits. No exit fault, 3 `exit_process`.
  - At 45 s: "Connecting to Rockstar Games Services". From 60 s the screen is black: no
    form.
  - The pool ran out (`[jit-pool] tail CAP: refusing …`, l.57803), ending head 464 MiB
    (448 live) and tail 433 MiB (433 live), with head exhausted ×18, tail refused ×5 and
    tail fatal 1.
  - This is the same pool limit the cache-off Opens hit some of the time (b91356c), not the
    exit fault.

So the fix holds in all four Opens with a warm or cold cache. Whether the sign-in page
appears still depends on the pool, which is the next work (a less greedy tail).

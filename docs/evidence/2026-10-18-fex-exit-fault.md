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

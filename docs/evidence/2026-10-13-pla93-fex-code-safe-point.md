# PLA-93: a real suspend does not hold a thread in FEX's module or a function it called

**Date:** 2026-10-13. **Linear:** PLA-93 (sweep 15c of PLA-112). **Plan:**
[compat speedrun](https://linear.app/playportdev/issue/PLA-633), queue item 15c.
**IPA (dev):** `3b39063b3b46a8fb44d114408db51d57a61cd8254bf40f58b7dc98acd6bc8f44`, built from
the change (`patches/madeira-unix` 0143) on `1473299`.

**Result.** The last known windows are closed: a thread in a JIT-pool copy of FEX's module, or in
a PE function FEX called, is no longer held. 10 Hollow Knight plays to `first-frame+30` and 10
plays through the freeze window (the new-game menu into King's Pass) ran clean: no freeze, no
`[fexlock] STUCK`, the Knight on every freeze-window screenshot. Portal 2 reaches its menu. The
new deferral fired twice in the 20 plays, both times in FEX's x64→EC transition stub, so it
costs a few retries and nothing more. Like the 2026-10-08 series, clean plays support the fix
but cannot prove a rare deadlock gone; no freeze has been seen since 2026-10-08.

## What was left

Before this change, `rs_at_safe_point` (`build/wineserver/mach_ios.c`) did not hold a thread
in host code, in a syscall (0137), in a syscall callback, or while FEX's TEB stamps showed a
WritePriorityMutex shared hold (TEB+0x16f0), a write hold (TEB+0x16c8, fex 0028 with
madeira-unix 0129) or the CodeBufferWriteMutex stamp (TEB+0x16e8, 0097). Two gaps remained
(triage 15a):

1. **The stamps' CAS windows.** `WritePriorityMutex::lock`/`try_lock` and the shared paths set
   the stamp after the CAS that takes the lock, and `unlock`/`unlock_shared` clear it before the
   CAS that releases it. A hold landing between them froze an owner the stamps did not show.
2. **FEX's other locks are not stamped.** A suspender that then needs FEX (Mono's collector
   runs guest code before it resumes anyone) waits on any of them for ever.

## FEX's internal locks (fex tree at the pin plus `patches/fex`)

| Lock | Kind | Where it is held | Covered by |
| --- | --- | --- | --- |
| `CodeInvalidationMutex`, lookup and other `WritePriorityMutex`es | FEX's own futex mutex | compile, link, invalidation | TEB stamps (shared, write); their CAS windows by the new pc rule |
| `CodeBufferWriteMutex` | stamped | code buffer writes | TEB+0x16e8 |
| `ThreadCreationMutex` | `std::recursive_mutex` in ARM64EC (an ntdll critical section), `std::mutex` in WOW64 | thread create/exit, RWX read notifications | pc / lr / frame rule |
| `InvalidationTracker::IntervalsLock`, `ImageTracker::ImagesLock`, `OvercommitTracker` | `std::shared_mutex` (ntdll SRW lock) | memory and image notifications, faults | pc / lr / frame rule (most also run in a syscall callback) |
| `SharedCodeBufferManager::LatestMutex`, `ThreadPoolAllocator::AllocationMutex`, `IntrusiveArenaAllocator::AllocationMutex`, `DiskCache` mutexes | `std::mutex` (ntdll SRW lock) | compile (under the shared stamp), allocation | pc / lr / frame rule |
| `64BitAllocator::AllocationMutex` | `ForkableUniqueMutex` | not built for MinGW | none needed |
| `SpinWaitLock`s, rpmalloc's locks | atomics in FEX's module | lookup, allocation | pc rule |

Each is taken and held only in FEX's module's code, or in an ntdll function FEX called
(`RtlAcquireSRWLock*`, `RtlEnterCriticalSection`), which returns to FEX once it owns the lock.

## The change

**`patches/madeira-unix` 0143.**
- ntdll's JIT-pool image table (`virtual_ios.c`) marks a copy of `libarm64ecfex.dll` or
  `libwow64fex.dll` when it records it; a child's copy inherits the mark.
  `ios_jit_pool_image_kind(pc)` answers lock-free: FEX's module, another PE image, or neither.
- `rs_at_safe_point` also defers a thread whose pc is in FEX's module, or whose pc is in another
  PE image copy while `lr` or the return address in its frame record (`[fp+8]`) is in FEX's
  module. Translated code and FEX's dispatcher loop are in FEX's code buffers, not its module,
  so a thread running guest code is still held at once.
- The retry and its back-off are unchanged. Logged, 64 lines: `[real-susp] fex-code defer`
  (`by=pc|lr|frame`, pc, lr, fp, InSimulation), and `fex_code=` in the stats line.

The fex-side alternative (move the stamps outside the CAS windows) was not taken: it closes
gap 1 only, needs eight more edit sites in `WritePriorityMutex.h`, and the thread-exit cleanup
(ml612) trusts the shared stamp to mean a hold, which a stamp before the CAS would break.

## Runs

Every run on IPA `3b39063b`, default settings, in two `pp phone lock` sessions (run directories
under `$PLAYPORT_BUILD/ui-runs/`).

**Series A**, `pp ui --play app-367520 --until first-frame+30 --shot --wait 90`, `s15c-hk-1..10`:

| Run | First frame | Freeze | Screenshot | Suspends (first 8 logged) | in-fex / fex-code defers | Late holds | STUCK |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | +9.96 s | no | main menu | 8, all deferred (`held=2`) | 0 / 0 | 0 | 0 |
| 2 | +8.64 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 3 | +9.85 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 4 | +8.72 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 5 | +9.76 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 6 | +9.98 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 7 | +8.95 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 8 | +9.82 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 9 | +9.04 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |
| 10 | +10.05 s | no | main menu | 8, all deferred | 0 / 0 | 0 | 0 |

Each has 35 `is_ec=1` context reads (`[ec-getctx]`). Up to `first-frame+30` the collector's
rounds never reach a hold, so this series checks start-up only.

**Series B, the freeze window**, `pp ui --pad --play app-367520 --until first-frame+25
--leave-running --wait 90`, then `pp pad push hk-new-game --wait`, 10 s, `pp phone shot`, `pp phone
log`, `s15c-win-1..10`:

| Run | First frame | Freeze | Screenshot after the script | in-fex / fex-code defers | Late hold (tid, tries, pc) | Stats line (`tick`) | STUCK |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | +8.85 s | no | Knight in King's Pass | 0 / 0 | `00e4`, 5, JIT | deferred=35 retries=68 | 0 |
| 2 | +8.95 s | no | Knight | 0 / 0 | `00e4`, 6, JIT | deferred=35 retries=68 | 0 |
| 3 | +10.18 s | no | Knight | 0 / 1 (`by=pc`) | `00e4`, 7, JIT | deferred=35 retries=74 | 0 |
| 4 | +10.01 s | no | Knight | 0 / 0 | `00e4`, 6, JIT | deferred=35 retries=65 | 0 |
| 5 | +10.16 s | no | Knight | 0 / 0 | `00e4`, 6, JIT | deferred=35 retries=68 | 0 |
| 6 | +9.90 s | no | Knight | 0 / 1 (`by=pc`) | `00e4`, 6, JIT | deferred=35 retries=74 | 0 |
| 7 | +10.24 s | no | Knight | 0 / 0 | `00e4`, 5, JIT | deferred=35 retries=74 | 0 |
| 8 | +9.91 s | no | Knight | 2 / 0 (`002c`, syscall callback, shared stamp) | `00e4`, 6, JIT | holds=1 deferred=23 retries=153 in_fex=2 | 0 |
| 9 | +10.15 s | no | Knight | 0 / 0 | `00e4`, 4, JIT | deferred=35 retries=71 | 0 |
| 10 | +9.96 s | no | Knight | 0 / 0 | `00e4`, 5, JIT | deferred=35 retries=74 | 0 |

The `tick` line is written at the 128th suspend operation, before the late hold. Each play has
one late hold of `00e4`, in translated code (InSimulation 1, no stamps), as on 2026-10-08. The
two `fex-code` deferrals were `00e4` at libarm64ecfex.dll RVA `0x12cee0` (`ios_ec_xlate_loop`)
and `0x12ce04` (`ExitFunctionEC`), FEX's x64→EC transition, resolved with `llvm-symbolizer`
against `$PLAYPORT_BUILD/run/fex/build-arm64ec/Bin/libarm64ecfex.dll`; the thread was held in
translated code one to three retries later.

**Portal 2 gate**, `pp ui --play app-620 --until first-frame+30 --shot --wait 90` (`s15c-p2`):
first frame +5.74 s, main menu on the screenshot, no deferral lines, no STUCK.

## Limits

- A FEX lock held by a thread more than one call deep in another PE module (FEX → ntdll → an
  ntdll helper) is not seen. The acquisitions above complete one level down.
- Deferral itself is not a stop: a deferred thread runs until a retry holds it (1 ms, backing
  off to 32 ms), as one in host code always did. Upstream's cooperative suspend at FEX's
  `SuspendDoorbell` would close that, and is a separate change.
- The plays used the default graphics; the 2026-10-08 series alternated DXVK and D3D12.

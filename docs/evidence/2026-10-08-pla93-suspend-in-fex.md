# PLA-93: a real suspend's hold is deferred while the thread is inside FEX

**Date:** 2026-10-08. **Linear:** PLA-93 (a stability blocker of PLA-72). **Plan:**
[Vulkan performance](../plans/2026-10-06-vulkan-performance.md), Progress (stability).
**IPA (dev):** `363c123408d708034a0c17459edfe3262ee54e84974356bb0452226ccac32237`, built from
commit `dedb498` (the change is `59a107e`, its build records `dedb498`).

**Result.** The fix is in, and 10 Hollow Knight plays through the freeze window ran clean, 5 on
DXVK and 5 on D3D12. Before it, 2 plays of about 20 froze, so 10 clean plays support the fix but
do not prove it. If the fix did nothing and the rate stayed near 1 in 10, about a third of
10-play series would still have no freeze. None of the 10 plays needed the new deferral: there
were no `in-fex defer` lines. So these runs show that the change costs nothing and breaks nothing.
They do not show the deadlock prevented.

## The freeze

This summary comes from the investigation (PLA-93, run `vk-st-n60-vkd3d-1`, and the DXVK run
`vk-nat-dxvk-wa7-ctl` with the same signature):

1. The freeze starts in Hollow Knight's new-game menu, about `first-frame+37`, right after Mono's
   collector (main thread `002c`) runs its suspend rounds.
2. `Loading.PreloadManager` (`0118` on D3D12, `00e4` on DXVK) is logically suspended, but its
   Mach hold is deferred. The thread leaves a timed in-process wait.
3. It then takes FEX's `CodeInvalidationMutex` for writing. This is a memory or read-file
   notification's code invalidation, which the ntdll ARM64EC wrappers run with the CPU area's
   `InSyscallCallback` set.
4. The deferred hold's retry (`patches/madeira-unix` 0010, 0048) takes FEX's PE code in the JIT
   pool for a safe point, and Mach-holds the thread there.
5. `002c` read-waits on that mutex and never resumes the threads it suspended. The log shows
   `[fexlock] STUCK read-wait … owner … tid=0118`, and 6 suspends against 3 resumes.

## The change

**`patches/madeira-unix` 0097** (wineserver `mach_ios.c`, `rs_at_safe_point`).
- The hold is now also deferred, with the same retry and the same 1 ms to 32 ms back-off, while
  any of these is set:
  - the target's `TEB->ChpeV2CpuAreaInfo->InSyscallCallback` (TEB+0x1788 → +1);
  - FEX's WritePriorityMutex shared-hold depth (TEB+0x16f0, `Instrumentation[7]`, uint32);
  - its CodeBufferWriteMutex stamp (TEB+0x16e8, `Instrumentation[6]`).
- All three are read with `ios_safe_read`.
- `InSimulation` alone (guest code in the JIT) stays a safe point, because a stop-the-world finds
  its threads there.
- Upstream Wine (`signal_arm64.c` `usr1_handler`) suspends a thread with `InSimulation` or
  `InSyscallCallback` set only cooperatively, through the doorbell.
- Offsets checked at the pins:
  - Wine `include/winternl.h`: `ChpeV2CpuAreaInfo` at `/1788`, `InSimulation` 000,
    `InSyscallCallback` 001.
  - FEX `WritePriorityMutex.h`:
    - `NoteReadAcquired`/`NoteReadReleased` keep the depth at +0x16f0;
    - `IosEmissionLocksHeldBySelf` reads +0x16f0 and +0x16e8.
  - FEX at the pin no longer writes +0x16e8, because upstream removed the CodeBufferWriteMutex
    (`JIT.cpp` ml455 comment). That read is therefore always 0 and costs only the read.
- New lines, 64 each:
  - `[real-susp] in-fex defer` for each deferral the change adds;
  - `[real-susp] late hold` for each hold a retry takes, with tid, tries, pc, sp, `insim`,
    `insc`, `wpm_depth` and `cbw`;
  - `in_fex=` in the stats line.

**`patches/madeira-unix` 0098** (diagnostics).
- `ios_wpm_owner_report()` prints `[wpm-owner]` for a WritePriorityMutex's write owner: its Mach
  `susp=`, run state, pc, lr, sp and a 12-frame fp chain.
  - It finds the owner in the thread registry by the TEB the mutex stamps, and checks it against
    the tid.
- The thread sampler now prints every thread whose Mach suspend count is above 0 on every pass,
  past its 64-thread cap, and each line carries `susp=N`.

**`patches/wine-unix` 0022** (diagnostics). `[hot-lock]` calls that report when the dumped word
at the waited address (rounded down to 8 bytes) has the write bit set.

## Runs

The phone was an iPhone18,4 on iOS 27.0, on the charger at 100 %, and every run was warm. The
installed IPA was `363c1234…`. Run directories are under `$PLAYPORT_BUILD`.

**Gate** (`pp ui … --until first-frame+10 --shot`): every run reached its first frame and ran on.

| run | title, settings | JIT | first frame | screen |
| --- | --- | --- | --- | --- |
| `ui-runs/20261008T135320` | Hollow Knight, default (Vulkan, DXVK) | 2.66 s | +10.57 s | main menu |
| `ui-runs/20261008T135412` | Hollow Knight, `{"graphics":"dxmt"}` | 2.69 s | +10.11 s | main menu |
| `ui-runs/20261008T135503` | Hollow Knight, `{"graphics":"vulkan","arguments":"-force-d3d12"}` | 2.56 s | +9.15 s | main menu |
| `ui-runs/20261008T135555` | Portal 2 (app-620) | 2.58 s | +5.81 s | Source intro |

**Freeze check.** The plays alternated DXVK (`{"graphics":"vulkan"}`) and D3D12
(`{"graphics":"vulkan","arguments":"-force-d3d12"}`). Each one was:

```
pp perf --out .work/perf-runs/pla93-N-ROUTE --secs 70 --no-hud --shot first-frame+65 \
        --pad first-frame+25:hk-new-game --settings '…'
```

This walks through Start Game, the profile and the calibration screens into King's Pass. A freeze
would show as `[frames]` lines that stop, a 5 s bucket at 0 FPS, or `[fexlock] STUCK`.

| run | first frame | FPS mean | lowest 5 s bucket | last `[frames]` (before the kill at +70) | STUCK | late hold |
| --- | --- | --- | --- | --- | --- | --- |
| `perf-runs/pla93-1-dxvk` | +10.24 s | 49.6 | 25.0 | 13:59:21.271 n=3872 | 0 | `00e4` tries=4 insim=1 |
| `perf-runs/pla93-2-d3d12` | +9.47 s | 53.3 | 25.0 | 14:02:02.530 n=4272 | 0 | `0118` tries=5 insim=1 |
| `perf-runs/pla93-3-dxvk` | +9.48 s | 49.9 | 25.0 | 14:04:36.060 n=4032 | 0 | `00e4` tries=4 insim=1 |
| `perf-runs/pla93-4-d3d12` | +9.38 s | 53.3 | 25.0 | 14:07:10.168 n=4288 | 0 | `0118` tries=4 insim=0 |
| `perf-runs/pla93-5-dxvk` | +10.57 s | 49.9 | 28.9 | 14:09:44.311 n=3984 | 0 | `00e4` tries=5 insim=1 |
| `perf-runs/pla93-6-d3d12` | +9.45 s | 53.2 | 27.4 | 14:12:18.319 n=4176 | 0 | `0118` tries=5 insim=1 |
| `perf-runs/pla93-7-dxvk` | +10.62 s | 49.7 | 29.5 | 14:15:05.849 n=3952 | 0 | `00e4` tries=5 insim=1 |
| `perf-runs/pla93-8-d3d12` | +9.43 s | 53.3 | 25.0 | 14:17:39.715 n=4288 | 0 | `0118` tries=6 insim=1 |
| `perf-runs/pla93-9-dxvk` | +10.21 s | 49.9 | 29.3 | 14:20:13.278 n=3984 | 0 | `00e4` tries=5 insim=1 |
| `perf-runs/pla93-10-d3d12` | +9.26 s | 53.2 | 27.4 | 14:22:51.314 n=4192 | 0 | `0118` tries=5 insim=1 |

So there were 0 freezes in 10 plays. Every play's screenshot at `first-frame+65` shows the Knight
in King's Pass.

### What the new lines show

- **The late hold is the thread from the freeze.** Each play has exactly one late hold, and it is
  `Loading.PreloadManager`: `00e4` on DXVK and `0118` on D3D12, the same thread that owned the
  mutex in both frozen runs. Here the retry caught it in guest code (`insc=0 wpm_depth=0`), which
  is a safe point. A sample line:

  ```
  [real-susp] late hold #1 tid=0118 tries=5 pc=0x11dd07d48 sp=0x73f6250000 insim=1 insc=0 wpm_depth=0 cbw=0
  ```

  In `pla93-4-d3d12` the hold landed with `insim=0 insc=0`: native ARM64EC code, outside FEX.
- **No hold was deferred inside FEX.** No play has an `in-fex defer` line, and every stats line
  reads `in_fex=0`. The change did not act in these 10 plays. The window it closes (the retry
  landing while that thread is in FEX's invalidation) is rare, and its rate is the freeze's.
- **Suspend cost.** Mono's GC pause length is not in the log. The real-suspend counters are the
  proxy, and they match the earlier runs at `e6bd82a4…`:

  | | holds | deferred | late holds | retries |
  | --- | --- | --- | --- | --- |
  | these 10 plays (first `ml730 tick` line, at 128 ops) | 1 | 19 | 1 | 160–188 |
  | `vk-nat-dxvk-wa7-ctl-2`, `vk-nat-dxvk-sm-1`, `vk-nat-dxvk-wa7-1` | 1 | 19 | 1 | 199–229 |

  The first-frame times (+9.3 to +10.6 s) and the FPS means (DXVK about 49.8, D3D12 about 53.3)
  are as before.
- **The diagnostics.**
  - The sampler printed `susp=` on every line.
  - Only one sample had `susp=1`: in `pla93-1-dxvk`, a native thread in another sampler's
    momentary stop.
  - The DXVK plays each have 12 `[hot-lock]` dumps (DXVK's idle waiter crowds). None had a
    write-owned FEX word, so `[wpm-owner]` never printed. On the phone that path has run only in
    the negative case.

## Residual risk

- **FEX write holds outside a syscall callback are still not covered.** FEX does not stamp the
  CodeInvalidationMutex's write owner in a TEB slot; `NoteWriteAcquired` writes only the mutex's
  own `OwnerTeb`/`OwnerTid`. A write hold taken with `InSyscallCallback` clear could still be
  Mach-held. Two examples are `HandleRWXAccessViolation` from exception dispatch
  (`Source/Windows/Common/InvalidationTracker.cpp:403`) and the Mono back-patcher mark
  (`FEXCore/Source/Interface/Core/Core.cpp:1446`). Closing that needs a FEX TEB stamp in
  `NoteWriteAcquired`/`NoteWriteReleased` (`patches/fex`), which this chunk does not add.
- **A deferred thread keeps running during the GC.** This is the same gap as today's deferrals
  at the other unsafe points: a correctness gap for Mono, not a deadlock. A thread with a leaked
  `+0x16f0` depth is never held; its retry backs off to 32 ms, as for a thread in host code.
- **The root fix is larger and was not taken.** It would make a logically suspended thread
  suspend itself when it returns from an in-process wait, which is upstream's cooperative model.
- **The proof is incomplete.** 10 clean plays at a 1-in-10 baseline is support, not proof, and the
  new deferral never fired. The next freeze, or its absence over more plays, decides it. If it
  freezes again, `[wpm-owner]` (owner `susp=`, pc, fp chain) and the sampler's `susp=` lines name
  the owner's state.

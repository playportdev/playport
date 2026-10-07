# Plan: performance review of the patch series against comparable projects

**Linear:** [PLA-79](https://linear.app/playportdev/issue/PLA-79).
**Review:** partial; the source snapshot below is historical. Defaults, x87,
MaxInst and dependency updates have since landed; remaining hypotheses still need
reconciliation and evidence. Coordinate overlapping items with PLA-75, PLA-76 and
PLA-72 rather than treating this as a second work queue.

**Date:** 2026-09-30. **Status:** review and plan. The code was read and the
series were applied to scratch trees; nothing was built, installed or run on
the phone, so every cost below is a hypothesis until a `pp perf` A/B shows it.
**Tree:** `e700809`. **Extends:**
[the 2026-09-28 follow-up plan](finished.md#performance-follow-up-after-the-runtime-audit). Its
measurement rules apply to every experiment here.

Scope: thermal throttling, hitches and lag. The areas reviewed:

- Playport's and Madeira's patches to FEX, rpmalloc, Wine, DXMT and Mesa;
- the app host;
- the build flags;
- Valve's `proton_11.0` Wine and Proton's ARM64 configuration;
- FEX releases 2503–2609 and FEX main;
- Winlator and the Android launchers built on it, and Apple's guidance for games.

Tags: **[code]** is read in the source. **[hyp]** is a cost or rate not yet
measured.

## Where the power goes (settled, for context)

The power-budget and thermal records show the following:

- At native 2736×1260 and 120 FPS, play draws about 8.7 W, and the phone
  sustains about 4.5 W.
- The process's CPU accounts for only 1–1.5 W of that. The rest is GPU and
  memory/fabric.
- First-use hitches are CPU work on code that runs for the first time: FEX
  translations, Mono's JIT and invalidation. Shader compiles are not the cause.

The ranking below follows that split. Items that cut GPU work are first, then
items that cut CPU work that runs all the time, then items that cut
first-use (hitch) work.

## A. Presentation: the largest power lever

### A1. The 720/60 default is still unimplemented [code]

Commit `9cbd5e5` changed only the plan and design documents.
`LaunchSettings.resolve` (`app/PlayportKit/Sources/PlayportKit/LaunchSettings.swift:104`)
still falls back to the cohort's `recommendedScreen`, then native, and to
frame limit `0`. `titles.json` gives Hollow Knight no `screen`, so it starts
at native resolution with no frame limit. That is the configuration that
reaches pressure 20 and loses the P cores.

A Winlator-based Android launcher defaults to 1280×720 with a 60 FPS limiter that is on by default,
and has an optional adaptive cap that steps down when frames are missed.
Proton is not relevant here.

**Do:** implement the plan's default of a 720-row screen and 60 FPS, then
measure it against native/free-running, following section 1 of the follow-up
plan.

### A2. The limiter sleeps before the frame is submitted [code mechanism, hyp effect]

The mechanism, in `PacedMetalLayer.nextDrawable` (`app/Sources/S1Probe/HostIO.swift:404`):

- It calls `Thread.sleep` on DXMT's encode thread.
- DXMT calls `nextDrawable` inside `Presenter::encodeCommands`, which runs
  before `cmdbuf.commit()` for the whole frame. So the frame's roughly 28
  passes wait on the CPU for the sleep.
- Only then does the GPU start, and the present lands at whatever vsync
  follows (vsync mode 0: `TitleScreen.swift:44`).

The effect, and what it means for existing measurements:

- A late wake plus about 6 ms of GPU work can miss a 120 Hz slot. This is a
  candidate cause of the 501 frames of exactly 25.01 ms in the
  [GPU leads](finished.md#hollow-knight-leads-from-the-first-gpu-captures).
- `[FRAME_STATS] drawable_block` times this sleep, so lead 5 is mostly the
  limiter, not a stall.

Apple's porting guidance and DXMT upstream (`d3d11.preferredMaxFrameRate`)
both pace frames through Metal with `presentDrawable:afterMinimumDuration:`,
not with a CPU sleep. DXMT already has that path: vsync mode 1 in
`winemetal_unix.c`. The "iOS 27 min-duration stalls" note that turned it off
predates the relaunch fixes.

**Do:** with a 60 FPS limit, A/B these two variants and count frames of
25 ms or more and `SystemLoad`:

1. Vsync mode 1 and no sleep.
2. A limiter on the game thread in `MTLD3D11SwapChain::Present`, as DXVK does.

### A3. The display link and the guest monitor always say 120 Hz [code]

`TitleScreen.swift:47` and `:62` set `MADEIRA_SCREEN_HZ` and
`preferredFrameRateRange` from `UIScreen.maximumFramesPerSecond`, whatever
the frame limit. With a 60 FPS limit, the panel still runs at 120 Hz, and a
game's own vsync or `targetFrameRate` still aims at 120.

Apple gives games priority at 30 and 60 Hz when the range asks for them.

**Do:** when the limit is above 0, set the range and `MADEIRA_SCREEN_HZ` to
the limit.

### A4. DXGI `SyncInterval` is discarded [code]

`d3d11_swapchain.cpp` computes the vsync duration, and the flush discards
it (`(void)data->after`). So a game's in-game vsync, or `Present(2)`
(half-rate), has no effect, and the game renders up to the panel rate.

**Do:** honour it through the same `afterMinimumDuration` path as A2.

### A5. Smaller GPU items [hyp]

- `framebufferOnly = false` on the drawable (`dxmt_presenter.cpp:20`, a
  macOS finding). Apple's guidance is `YES` for compression. One-line A/B.
- `MTL_HUD_ENABLED=1` is set unconditionally, in release too
  (`HostIO.swift:374`). Every perf run so far had the HUD visible.
- MetalFX spatial upscaling already exists in DXMT upstream
  (`DXMT_METALFX_SPATIAL_SWAPCHAIN`). It is a way to render below 720 rows
  without the image falling apart. Temporal upscaling is not usable, because
  it needs motion vectors that D3D11 does not provide.

### A6. `LSSupportsGameMode` is missing from `app/Info.plist` [code]

Only `GCSupportsGameMode` is there. Apple says Game Mode "might not turn on"
without it. **Do:** add the key.

## B. CPU work that runs all the time, in Madeira's runtime

### B1. The in-process wineserver never sleeps, and it scans every client fd [code]

In Madeira `build/wineserver/fd_ios.c`:

- The loop waits at most 1 ms. On each pass it tries a non-blocking `read()`
  on every client fd (one per guest thread, plus msg fds), because iOS
  cannot poll `AF_UNIX` sockets.
- Every client request also signals a counting semaphore that is never
  coalesced. Madeira's own comment (ml584) measured 2,935 passes a second,
  so once requests outpace the loop, it stops sleeping at all.
- The loop runs at USER_INTERACTIVE.

That is roughly (threads) × (1,000 + requests/s) failed reads a second
[hyp]. This may be most of the wineserver thread's measured 4–10 % of a
core in Hollow Knight and 22–40 % in The Witcher 3. Decision 0023 covers
madsync, not this scan; the fix below does not need madsync.

**Measure first:** read `iter`, `synIN` and `semEarly` from the existing
`[srv-poll]` heartbeat in a dev log.

**Fix:**

- a per-thread "request pending" flag, set by the client before it signals;
  the loop reads only flagged fds;
- signal only when the server is asleep;
- keep the 1 ms tick only while an INET socket or pending async I/O needs
  it; otherwise sleep to the next timer, or 16 ms for the shared clock page.

### B2. PE-side `GetTickCount` and `timeGetTime` cost Mach exceptions [code, hyp rate]

KUSER_SHARED_DATA at `0x7ffe0000` sits under iOS's 4 GB page zero, so every
load from it is emulated. The loads are in kernelbase and kernel32
`GetTickCount*`, `timeGetTime`, and ntdll `NtGetTickCount`.

Madeira removed this for win32u only (`message_ios.c`), calling it "a top
residual fault source in gameplay". Frame loops call these constantly, so
they are a candidate for much of play's steady 700–950 exceptions a second.

**Measure:** count `[EXC_SAMPLE]` fault addresses in `0x7ffe0xxx`.

**Fix:** a `wine-pe` patch that reads the relocated shared-data address, as
win32u already does.

### B3. Diagnostic work on every Mach exception [code]

In Madeira `signal_arm64_ios.c`:

- an unconditional `mach_vm_region` snapshot at entry, which takes the
  vm_map lock that FEX and Mono `mprotect` contend for during loads;
- a NEON state fetch on every exception.

That is 3–4 extra traps on every exception, on one serial thread. It
matters because loads take tens of thousands of exceptions.

**Fix:** query the region only on the unhandled or logging path, and fetch
NEON only for SIMD emulation. **Measure:** `[fault-cost]`.

### B4. Windows thread priorities never reach QoS [code]

- Every guest thread is USER_INTERACTIVE: `ios_eco_apply_self`, `wine-port/0054`.
- `ThreadPriority` stops at the server, whose `apply_thread_priority`
  returns early on iOS.

So `SetThreadPriority(LOWEST)` on Unity's loading and job workers, and on
audio threads, does nothing. The QoS record got 1.9 W → 1.55 W CPU by
naming such threads by hand, and made periodic stalls worse.

**Do:** map LOWEST/IDLE to background, BELOW_NORMAL to utility, and higher
priorities to interactive, applied at the thread's next wait as ECO is.
A/B it per title, following section 4 of the follow-up plan.

**Measured (2026-10-05, [Portal 2 thread QoS](../evidence/2026-10-05-portal2-thread-qos.md)):**
madeira-unix 0078 logs the priorities. Portal 2 sets LOWEST on DXVK's shader
workers and TIME_CRITICAL on two threads. Hollow Knight sets LOWEST on its 16
background job workers and TIME_CRITICAL on DXMT's encoder and finisher. No
mapping was made: lowering the shader workers would lengthen the
first-pipeline hitches.

### B5. Smaller runtime items [code, hyp cost]

- **Sleep(1) cost.** After 256 calls less than 2 ms apart, each `Sleep(1)`
  first does an adaptive `usleep(100)` yield, which means two wakeups
  (`wine-port/0053`–`0054`). Skip the yield when `NtDelayExecution` has a
  non-zero delay.
- **Split-page stores.** Each store into a split 16 KiB host page does
  `mach_vm_remap`, protect and deallocate (`madeira-unix/0005`). Count
  `[split-page]` lines.
- **Suspend retries.** Safe-point suspend retries every 1 ms
  (`madeira-unix/0010`), which lengthens Mono's stop-the-world GC pauses.
  Check `[real-susp]` retries.
- **QPC counter layout.** The QPC histogram `qpc[256]` straddles cache lines
  shared between threads (`ntdll_misc.h`). The counters of the follow-up
  plan's §3 are otherwise small (under 0.5 % of a core), so §3 is lower
  priority than B1–B3.

## C. FEX: the ARM64EC port's own costs

### C1. Every icache flush is a Wine syscall [code, hyp cost]

`fex-port/0028` makes `IOSFlushOneInstr` call `NtFlushInstructionCache`.
It runs on every compiled block and every link and unlink patch: about
138k compiles a run, and tens of thousands of calls in one load hitch.

The patch's reasoning is that the syscall IPIs every core. But Darwin's
`sys_icache_invalidate` on arm64 is a user-space `dc`/`ic` loop. What the
syscall adds is the ARM64EC syscall path, and possibly
`BTCpu64FlushInstructionCache`, which takes `CodeInvalidationMutex`
exclusively and walks every thread.

**Do:**

1. Count the calls.
2. Find what actually fixed the Thumper ILLs. The patch comment points at
   `dc cvau` by RX address, then `dsb ish; ic ivau; dsb ish; isb`.
3. A/B the inline sequence against the syscall on JIT time in hitch windows.
4. Run the Thumper desktop again for correctness.

### C2. Extra work on every x64↔EC transition [code]

In `Module.S` (`fex-port/0026`, `0037`, `0061`):

- **Counters.** Sharded `ldadd` counters are spaced 64 bytes apart, but
  Apple cores have 128-byte lines, so neighbouring shards false-share.
  Every 64th call adds another global `ldadd`.
- **Alias cache.** The last-hit cache is one global shared by all threads.
  If the target is already a pool address, the alias table walk may run in
  full on every call [hyp].
- **FFS bypass.** The bypass branches to the PE address, which then takes
  an exec-fault redirect: about 33 µs each, by the code's own figure.

At up to about a million transitions a second, these add up.

**Do:**

- build the counters in dev only;
- store the last hit per thread;
- skip the walk early for pool addresses;
- branch the bypass to the pool target.

### C3. The call-return guard costs something on every CALL and RET [code]

`fex-port/0022` and `0024` add an inline bounds check and an x17 reload.
They exist because 4 KiB guard pages cannot be enforced on 16 KiB pages.

**Do:** use 16 KiB guard regions and restore upstream's page-fault guard.
Measure Hollow Knight's main-thread Mi/f, since its Mono code is call-heavy.

### C4. The iOS host feature set leaves out features the chip has [code]

`fex-port/0009` sets features by hand and does not run FEX's
`OverrideFeatures`. It leaves out:

- FRINTTS: every `CVT(T)SS2SI` and `CVTPS2DQ` takes the multi-instruction
  path;
- RPRES: `RCPPS` and `RSQRTPS` become divides and square roots;
- ECV, CSSC and WFxT;
- AVX.

`CPUMIDRs = {0}` makes the guest's CPUID report one core [hyp: check how
Unity and The Witcher 3 size their job pools from it].

**Do:** pass every `hw.optional.arm.FEAT_*` from `HostCPU.swift`, as LRCPC2
already is, fill `CPUMIDRs` from `hw.ncpu`, and A/B.

### C5. Build flags [code]

- **FEX.** `build/stages/fex.sh:79` builds with `-DENABLE_LTO=FALSE` and no
  tuning. FEX's CMake then picks `-march=armv8-a+crc` and "fits native" to
  the *build workstation*, so host atomics become LL/SC loops. The JIT's
  output is unaffected.
- **Unix side.** It builds for `arm64-apple-ios17.0` with no `-mcpu`. That
  defines no `__ARM_FEATURE_ATOMICS` (checked with clang).
- **DXMT unix side.** `airconv` and `winemetal_unix` build at `-O2` without
  `-DNDEBUG`, and the on-device LLVM has `LLVM_ENABLE_ASSERTIONS=On`
  (`build/stages/dxmt-base.sh`, `dxmt-combined.sh`).

**Do:** add `-mcpu` for the oldest supported chip (and `TUNE_CPU`/LTO for
FEX), set NDEBUG, and turn assertions off. These changes rebuild trees, so
their records must be committed with them.

### C6. Diagnostics on FEX hot paths in release [code]

- `WritePriorityMutex` scans a 16-slot holder array on every shared lock.
- `CompileBlock` does global atomics and walks the alias table on every L1
  miss.
- The L1 lookup cache is capped at 128K entries, against 1M upstream.

**Do:** gate all of these on one flag read once.

### C7. The call-return reset still costs hitch time [code, challenges the follow-up plan]

Roughly two thirds of the 1,477–1,681 `mprotect_exec` lines in the 175 ms
and 241 ms menu hitches are resets. At 27 µs each, that is about 25–45 ms
per hitch. Each reset also takes `CodeInvalidationMutex` exclusively and
logs a line.

**Do:** zero only the used part of the stack, and drop the log line.

## D. What Valve, Proton and FEX main have that the pin does not

- **FEX disk cache.**
  - Proton turned `FEX_DISKCACHE=1` on by default on 2026-09-26 (Proton
    `09d3d6e5`).
  - Valve's second half of the cache series is on FEX main, not in
    2609.1: `f9623af07`, `aa9ae2793`, `3f8f886f6`, `56a4f11dd`,
    `5efc3212d`, `b5ac608fc`, `7a82b07bf`, `b37aae728`, `83d8317da`,
    `47557a618`. FEX main is 92 commits past 2609.1.
  - Decision 0029 restarts the app after every game, so every launch
    translates from cold, and the cache matters more here than on a desktop.
  - Blockers: The Witcher 3's warm-start crash in rpmalloc, and the cache
    key not covering LRCPC2 (decision 0021). Re-check both after a FEX
    move.
- **`MaxInst=500`.** Valve ships it globally. It is already §2 of the
  follow-up plan and remains the cheapest experiment here.
- **Inline `PCMPxSTRx`.** FEX `638329278` makes these instructions 10–19×
  faster. It can be picked onto 2609.1 alone (it bumps the cache version).
- **`X87ReducedPrecision=1`.** Global in Proton and in a Winlator-based launcher's default
  preset. It matters little for x64 titles; try it per title where x87 code
  shows up.
  **Done (2026-10-05, decision 0048, [Portal 2 CPU](../evidence/2026-10-05-portal2-cpu-spin.md)):**
  global now. Portal 2's main thread fell from 23.9 to 14.8 M instructions a
  frame and the CPU's power from 562 to 343 mW. Spin-waits were not the cost:
  PAUSE as ISB changed nothing in Portal 2 or Hollow Knight and was dropped.
- **CPU topology override.** Valve's `edd5fa7c08e` and `a75c78b4079` were
  left out because they touch replaced files. Proton uses it on aarch64, and
  on this phone games see six identical cores [hyp: fewer visible cores
  cut worker contention and heat].
- **`NtUserGetAsyncKeyState` recent bit** (Valve `4aa2ab99c59`). It removes
  one server round trip per key poll. Low impact, low risk.
- **TSO.** A Winlator-based launcher's presets that turn TSO off corrupt
  real programs (its PR #2026), which matches Hollow Knight's hang with TSO off.
  Keep TSO on, and verify that per-module `VolatileMetadata` is actually
  applied: `NotifyImageMap`'s fallback path registers ranges without it
  [hyp]. Count `AddForceTSOInformation` calls per module.

## E. Correctness risk found on the way: `wine-valve/0092`

For `--target=arm64ec-w64-mingw32`, clang defines `__x86_64__` (checked).
So `FlushInstructionCache` takes the x86 branch, which returns TRUE without
calling `NtFlushInstructionCache`, and FEX's invalidation hook is never
reached. With `patches/fex/0003` turning SMC detection off once Mono's
backpatcher is found, a second JIT in the same game (CEF, V8, LuaJIT) can
run stale code.

**Do:** guard the x86 branch with `!defined(__arm64ec__)`.

## Order

1. A1 + A2 + A3 together: a 720/60 default, paced by Metal, with a 60 Hz
   display link. Then A6.
2. B1 (read `[srv-poll]` first), B2 and B3: runtime work that runs all the
   time and on every exception.
3. C5 build flags and C4 features. These are cheap, but each needs a
   rebuild and a Hollow Knight play.
4. `MaxInst=500` (follow-up §2), then C1, C2 and C7 for hitches.
5. The FEX move past 2609.1 for the disk cache and `PCMPxSTRx`: a manual
   rebase with its Hollow Knight play (decision 0008).
6. E: a small fix, whenever `wine-valve` is next touched.

Also, every `pp perf` so far ran the dev app, whose samplers (the 250 ms
census and thread-sample bursts that suspend every thread) are inside the
power figures. Record the variant with every result, and confirm final
numbers on `--variant release`.

## Sources outside the repository

- Proton `FEX_Config.json` and the `proton` script (`proton_11.0`,
  bleeding-edge `315e8053`); FEX `Config.json.in` and the release notes
  2503–2609 on GitHub.
- A Winlator-based Android launcher: `Container.java`, `FEXCorePresetManager.java`,
  `Box86_64PresetManager.java`, `XServerScreen.kt` (the frame limiter),
  `AdaptiveFpsCapController.kt`, PR #2026.
- DXMT `dxmt.conf` (`preferredMaxFrameRate`, MetalFX spatial).
- Apple: *Optimizing iPhone and iPad apps to support ProMotion displays*,
  `LSSupportsGameMode`, and the Game Porting Toolkit skills
  *presenting-metal-drawables* and *using-metalfx-temporal-upscaler*.

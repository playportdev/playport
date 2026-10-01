# Plan: runtime risks in JIT, threading and memory

**Date:** 2026-09-27. **Kind:** plan, nothing done yet. **Pins read:** `madeira`
8c050d0, `fex` FEX-2609.1, `stikjit` 1.6.0, as in `pins.lock`.

## Where this comes from

A survey of iOS 26 JIT, Proton on ARM and the Android Steam front ends, set
against our implementation. None of it argues against the design, which matches
what the survey found:

- JIT memory blessed by an attached debugger, with a writable alias;
- a pool sized before the debugger detaches;
- one process;
- no 32-bit games, since nothing can be mapped below 4 GB;
- PE images copied into the pool, with TXM's silent `mprotect(PROT_EXEC)`
  failure detected (`virtual_ios.c` around line 9204);
- x18 handled in three layers.

What follows are the places where it is exposed, most serious first. In this
plan, `virtual_ios.c` and the other `*_ios.c` files are in
`upstream/madeira/build/ntdll-unix/`.

> **Order with the Wine plan.** [Wine from Valve's Proton branch](2026-09-27-wine-on-proton.md)
> runs first. It brings in, or cherry-picks, Valve's ARM64EC cooperative
> suspend, its inproc-sync rework and the FEX settings Proton uses. So it may
> already have changed items 3 (sync) and 4 (FEX memory ordering) by the time
> this plan starts. Re-measure both on the post-Wine-plan build before doing
> the work described for them below. Items 3 and 4 can be struck if they no
> longer hold.

## 1. Whether JIT keeps working after the next iOS update

**Exposure.**

- SideStore's JIT page (June 2026) says iOS 26.6 and 27 "only work with a
  few apps". iOS 27 on A15 and later chips is unresolved (StikDebug issue #463,
  2026-09-17).
- We embed StikJIT 1.6.0 (`build/stages/stikjit.sh`). StikDebug is at 3.1.6,
  whose iOS 27 fix covers A13, A14 and M1 only.
- Every launch depends on this, and no code of ours controls it.

**Work.**

- Track StikDebug releases and the iOS 26.x and 27 JIT reports. Re-test on
  each iOS point release before updating the phone.
- Measure what moving the `stikjit` pin to a StikDebug 3.x release costs:
  - the script protocol (`app/PlayportJIT/playport-universal.js`);
  - the idevice library notice;
  - `prepare_memory_region`.
- Record which iOS versions are known good in DEVICE.md, and keep the reference
  phone on a known-good version until a new one is tested.
- **Done when** DEVICE.md names the tested iOS versions, and a pin-move
  procedure for `stikjit` exists.

## 2. The pool is fixed and single-shot

**Status (2026-09-28):** the launcher stress of work item 3 ran with the dev
build's test title *PoolStress*
([decision 0026](../decisions/0026-a-dev-test-title-for-the-jit-pool.md),
[evidence](../evidence/2026-09-28-launcher-stress.md)). No child process had
started since the wine-11.18 port, which madeira-unix 0039 fixes. A child
takes 19.6 MiB of head and 16 MiB of tail. An 896 MiB pool holds 24 alive at
once, 13 at 512 MiB. A dead child's images are not reused. The private ntdll
copy of decision 0019 stands. The .NET (Mono) stress is still to do.

**Exposure.** The pool is 896 MiB (`TitleMode.swift`, `poolMB`), with one
debugger attach per process, and it never grows.

- A full head fails image loads with `[jit-pool] EXHAUSTED`.
- A full tail shrinks FEX's CodeBuffer to 1 MB, then faults at `0xdead`
  (`patches/fex-port/0041`).
- Each pseudo-process holds a private ntdll copy in the pool, and a smaller pool
  ran out before (ARCHITECTURE.md).
- Guest JITs (Mono, V8) use the anonymous-alias table, which is capped at 4096
  entries.

**Work.**

1. Log the pool's head, tail and alias-table use in the result event, and add a
   `pool:` mark at exit.
2. Record the high-water mark for every cohort title, and add it to evidence.
3. Stress it:
   - a launcher that starts child processes (a cohort title with a launcher, or
     a test exe that spawns N children);
   - a .NET game (Mono JIT).
4. Show pool exhaustion in the UI as its own outcome ("out of JIT memory"), not
   as a generic failure.
5. Decide from the data whether pseudo-processes can share one read-only ntdll
   copy (relocated once, at a fixed pool address) instead of one each.
6. Size the pool from the device's memory limit instead of a constant.

**Done when** the high-water marks are recorded and exhaustion has its own
outcome.

## 3. Only in-process sync is fast, and it is off

**Decided 2026-09-28: sync stays as it is**
([decision 0023](../decisions/0023-in-process-sync-stays-off.md),
[evidence](../evidence/2026-09-28-server-sync.md)). The Wine plan left it
unchanged. `pp perf` now counts the server requests per frame. Hollow
Knight's main thread spends 0.8 % of its time in round trips. The Witcher 3
makes about 425 requests a frame, but its GPU sets the frame rate, and
turning in-process sync on changed only the CPU's power.

**Exposure.**

- Every wait goes to the wineserver thread. In-process `madsync` is opt-in
  (`patches/madeira-unix/0014`), and it is off because a blocked madsync wait
  never runs system APCs.
- Proton has fsync and ntsync because server-side waits are slow.
- `madsync` is one global mutex plus a Mach semaphore per waiter. Darwin's
  futex equivalent, `os_sync_wait_on_address` (iOS 17.4 and later), is not used
  anywhere.
- Hollow Knight's main thread is 99 % busy
  ([baseline](../evidence/2026-09-26-hk-native-baseline-wine-11.18.md)), and
  nobody has measured how much of that is server round trips.

**Work.**

1. Count server requests per frame by type (`select`, the event, mutex and
   semaphore calls) in `pp perf`, for Hollow Knight and Witcher 3.
2. If waits are a real share of the main thread:
   - make APCs work under in-process sync, by waking a blocked waiter when the
     server queues a system APC for its thread;
   - replace the global mutex with per-object waits on
     `os_sync_wait_on_address`, following the ntsync object model.
3. A/B the result with `pp perf`.

**Done when** there is a measured per-frame server-call count, and a decision
either to leave sync as it is or to enable in-process sync with APCs working.

## 4. FEX's memory ordering has a known gap

*May already have changed by the Wine plan; re-measure first.*

**Status (2026-09-28):** it still held after the Wine plan. Proton's FEX
profiles are applied per game, the ordering is a per-game launch setting,
and LRCPC2 comes from the host ([decision 0021](../decisions/0021-fex-ordering-per-game.md),
[evidence](../evidence/2026-09-28-fex-memory-ordering.md)). Vector
ordering costs The Witcher 3 about 4 % of its frame rate and both cohort
titles about 5 % more CPU work per frame.

**Exposure.**

- The runtime uses scalar ordering with half-barriers
  (`tso=1 halfbar=1 vector=0 memcpyset=0`, `patches/fex-port/0045`). Vector
  loads and stores and `rep movs` are left unordered. That is recorded as a
  known accuracy gap.
- Apple's hardware TSO bit is not reachable on iOS, so ordering is all in
  software.
- Multithreaded engines (Unity jobs, Unreal task graphs) can break under this
  without crashing: wrong results, hangs.

**Work.**

1. Take Proton's per-AppId FEX profiles (`FEX_APP_CONFIG`, written by the
   `proton` script) as data. Map them onto the settings our FEX build honours.
2. Expose the ordering settings as a per-game launch setting, like the graphics
   backend. Use the profile's values as defaults.
3. For each cohort title, run once with vector ordering on and compare the
   frame time with `pp perf`, so the cost is known.
4. Check whether host feature detection should set `SupportsTSOImm9` (LRCPC2)
   on A17 and later. Features are hardcoded in `patches/fex-port/0009`.

**Done when** the profiles are applied per game, and the vector-ordering cost is
measured on the cohort.

## 5. Virtual address space is tight

**Status (2026-09-28):** the thread count no longer limits the band
([decision 0024](../decisions/0024-dxvk-picks-its-compiler-threads.md),
[evidence](../evidence/2026-09-28-fex-band.md)). Every play logs the band's
use (`band:`). Each thread takes 50 MB: two rpmalloc spans, a call-return
stack and an L1 cache. The L2 cache and the 8 GB `VirtualMemSize` table are
off on iOS. A recursion through rpmalloc's name hook leaked 3.7 GB before the
first frame, and is fixed. Call-return stacks now pack at the band's top.
Hollow Knight holds 3.3 GB with 50 threads, and the video plays. DXVK's own
six compiler threads start with 12.9 GB free, and the compiler-thread limit
is removed. Hollow Knight on Vulkan still freezes in the menu or at Start
Game, with two threads as with six, so a Vulkan play past the menu is not
shown.

**Exposure.**

- FEX and rpmalloc have a 16 GB host band (`0x7c..0x80_0000_0000`). Hollow
  Knight's video threads exhausted it
  ([hk-video](../evidence/2026-09-26-hk-video.md)).
- The DXVK compiler-thread limit works around it (decision 0015) but does not fix
  it.
- Witcher 3 needs `jumbo-mb` holdbacks.

**Work.**

1. Log the band's use per thread. Find what each FEX thread reserves: the
   per-thread `VirtualMemSize` of 8 GB, the L2 cache and rpmalloc spans.
2. Reserve lazily, or share per-thread structures, so that the thread count
   stops limiting the band.
3. Remove the compiler-thread workaround once a play with the default thread
   count passes.

**Done when** Hollow Knight's video and a DXVK game both run with default thread
counts.

## 6. Constants found by trial

**Exposure.**

- The pool floor `0x119000000` exists because FEX's dispatcher literal-pool
  fixups broke lower down ("mode A", cited at `wine_host.c:739`). The cause is
  not understood.
- The TSD slot for the TEB varied across devices (275, 276, 280, 284) until it
  was looked up at run time (`patches/fex-port/0052`).
- Each FEX or iOS update can move such things.

**Work.**

- Find the real cause of mode A: which fixup assumes a distance or an
  alignment. Replace the floor with the actual constraint, or with an assertion
  that fails loudly.
- Add a start-up self-check that logs the pool address, the TSD slot and the
  host page size, and refuses a launch with a clear outcome when any
  assumption fails.

**Done when** mode A is explained in ARCHITECTURE.md, and the self-check is in
the result event.

## 7. Distribution depends on the memory entitlement

**Exposure.**

- Increased Memory Limit comes from our patched xtool
  (`build/toolchain/xtool-1.20.1-increased-memory-limit.diff`, and
  `verify-ipa.py` checks it).
- A tester who re-signs the IPA with SideStore, which currently drops the
  entitlement (SideStore issue #1616), gets about 3.3 GB instead of 8 GB. The
  pool alone takes 896 MB of that.
- Nothing tests or documents this case.

**Work.**

- At launch, read the process memory limit (`os_proc_available_memory`, or the
  jetsam limit). Show it in Settings.
- Refuse a play, or warn, when the limit is below what the title needs.
- Document in DISTRIBUTION.md which signing tools keep the entitlement.

**Done when** Settings shows the limit, and a low limit gives a clear message
instead of a jetsam kill.

## 8. Smaller open items

| Item | Where | Work |
| --- | --- | --- |
| W+X requests silently lose WRITE (ml999, report only) | `virtual_ios.c` around line 9225 | Find the titles that hit it with the report enabled. Then either handle W+X as a toggle between the RW and RX aliases, or fail it loudly. |
| x18 instructions whose trampoline is out of branch range are left to fault | `virtual_ios.c` around line 4456 | Count the misses per title. Place trampoline islands inside large images. |
| The anonymous-alias table is capped at 4096 entries | `virtual_ios.c` around line 2224 | Record the high-water mark (item 2). Grow the table, or make it a map. |
| Split-lock atomics are not atomic | `signal_arm64_ios.c` around line 2657 | Only a record: it is a known limit, and titles that hit it are logged. |

## Order

Item 1 is watched all the time. Then 2, 7 and 6, which are cheap, add
visibility and give clear failures. Then 3 and 4, after the Wine plan and only
if they still hold, and then 5. Each item ends with a `pp ui --play` of Hollow
Knight, and a `pp perf` where performance is involved. Results go in
`docs/evidence/`.

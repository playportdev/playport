# Plan: Madeira layer audit, deep dives

**Linear:** [PLA-75](https://linear.app/playportdev/issue/PLA-75).
**Review:** partial; the audit below is the original research snapshot. T3 was
implemented by madeira-unix 0090 ([evidence](../evidence/2026-10-07-pool-x64-images.md));
T13's NSI tables were addressed by PLA-58/PLA-71 with
[documented limits](../evidence/2026-10-07-nsi-adapters.md). Reconcile other findings
against current patches before implementing them; those two fixes do not close
this whole audit.

**Date:** 2026-10-06. **Kind:** plan, research only: nothing changed, nothing built, no phone used. **Pins read:** `madeira` 8c050d0 (frozen, decision 0054) with `patches/madeira-unix` 0001–0085, as built in `.work/run/unix/mythic/build/`. The FEX tree is `.work/run/fex`, with `patches/fex-port` and `patches/fex` applied. **Logs read:** `.work/agent-notes/va-exhaustion/v2/{hk,dd1-3,p2,w3*}/pull/s1-host.log`, from the IPA `965b7f27…` (0082–0085). The Hollow Knight log (`v2/hk`, about 48,900 lines for one play to first-frame+10) is the main source for the counts below.

## Method

I grepped and read the built trees. That covered `ntdll-unix/{virtual,signal_arm64,server,process,thread,loader,env,audio_null,nsi_unixlib}_ios.c`, `wineserver/{fd,main,request,mach}_ios.c`, the FEX Windows frontend and `Core.cpp`, the app's `WineHost/wine_host.c`, `WineHostRuntime.swift` and `Dev/Diagnostics.swift`, decisions 0009, 0019, 0023, 0024, 0027, 0030, 0036 and 0051, and the VA-exhaustion plan, evidence and notes. Each claim below names its code site, and where possible a log line from those runs.

- Line numbers are from the current build tree and will move as patches land. Function names are the stable reference.
- "Release" means the switches in `WineHostRuntime.quietRuntime()`: `MADEIRA_QUIET`, `MADEIRA_NO_DIAGNOSTICS` and `WINEDEBUG=-all`.
- Dev builds set none of them. `tools/` parses none of the warmer or census lines named below; I grepped `tools/` for `footprint`, `phys-map`, `slot#`, `window]`, `ca-shmem`, `zone-check`, `alert-ring` and `lock-census`.

Every Wine-side patch below goes into `patches/madeira-unix` (the wineserver files are in that tree too). It needs `Class:`, `Evidence:` and `Offered-upstream: no`, and it is gated on Hollow Knight (`app-367520`) to `first-frame+10`. The FEX-side patches go into `patches/fex`. The other installed titles used as gates are Death's Door (`epic-65d73e3be8824829b5b788bd849b6559`, with `tools/pad/dd-new-game`), Portal 2 (`app-620`, i386/WoW64), The Witcher 3 (`app-292030`, disk cache off), Among Us (`app-945360`) and Shogun Showdown (`gog-1104084973`).

---

## T1. The wineserver loop busy-polls and fakes readiness on every client fd

**What.** On iOS the wineserver never blocks in `poll`/`kqueue`. `main_loop` sleeps at most 1 ms on a Mach semaphore. Every iteration then:
- runs a zero-timeout `poll()` over the INET fds;
- for every client fd (`i >= ios_client_fd_start`), marks POLLIN as ready without checking (`revents |= POLLIN`) and calls `fd_poll_event`, which tries a read that fails with EAGAIN;
- marks POLLOUT as ready on every fd that asks for it.

**Where.** `wineserver/fd_ios.c`:
- `init_epoll`: "SKIPPING kqueue on iOS, using poll()";
- `main_loop`, the `#ifdef WINE_IOS` block, roughly lines 1170–1505;
- `ios_fd_is_inet`, whose cache is never invalidated when a poll slot is reused. Its own comment calls this "a latent correctness bug".

The client side signals `ios_srv_wake_sem` on every request without coalescing. The code's own note says the semaphore count "never reaches zero" once requests outpace the loop, so the loop stops sleeping. It cites 2,935 iterations/s (ml584).

**Evidence.**
- `[xp-t]` lines in the HK log put the wineserver thread (`m6870991`, named at `wineserver_main starting … on thread m6870991`) at 18–31 ms of CPU per ~300 ms window. That is 90–115 M instructions, or 7–10 % of a core, at the main menu. The game's main thread in the same windows is 41–80 ms.
- `[srv]` shows about 1,600 requests/s. The request work is real, but the fake-readiness pass costs about (iterations/s × client fds) failed reads on top of it. HK has about 54 threads.
- The `[srv-poll] iter=` heartbeat (every 50,000 iterations) appears in no log under `.work`, so the iteration rate on the current tree has not been seen.

**Why it is wrong.** The premise, "poll/kqueue don't work for Unix domain sockets in the app sandbox" and "ioctl(FIONREAD) is broken for AF_UNIX on iOS", dates from Madeira's early socketpair-injection work and was never re-tested. If kqueue works on these socketpairs, the server can block and the thread drops to the cost of the requests themselves.

**Gain / risk.** Gain: a few % of a core and its heat for every title, the whole session (thermal limits are what cap these titles; see the thermal evidence records). Risk: wineserver wake latency is what Thumper's frame pacing depended on (fd_ios.c comment), so a regression shows as missed frames or stalls.

**Touches.** Every title. Decision 0054 (fastsync on: fewer server waits, but `select` is still 556/s in HK).

**Confidence.** High that the loop does this. Medium on how much of the 7–10 % it accounts for.

**Steps.**
1. *Dive.* Make the heartbeat print every 5 s instead of every 50,000 iterations: iterations, synIN, synOUT, semEarly, semSlept, and the `nb_users` count. A dev-only `Class: diagnostic` patch, not kept. Run HK `--until first-frame+30` and Portal 2. Record iterations/s and failed reads/s.
2. *Dive.* In the same diagnostic build, add a one-shot self-test at `init_epoll`: create a socketpair and a pipe, register both with `kqueue` (`EVFILT_READ`) and `poll`, write one byte, and check readiness. Log the result. This decides between fixes (a) and (b).
3. *Fix (a), if kqueue works.* Use the existing `main_loop_epoll` kqueue branch. Add an `EVFILT_USER` or pipe wake for injected client fds and for the `g_wineserver_should_stop` flag. Drop the fake readiness.
4. *Fix (b), if it does not.* Keep polling, but drain the semaphore once per iteration. Test POLLIN with `recv(MSG_PEEK|MSG_DONTWAIT)` or FIONREAD before calling `fd_poll_event`. Mark POLLOUT ready only for fds with queued output. Invalidate `ios_fd_is_inet`'s cache in `add_poll_user`/`remove_poll_user`.
5. *Gate.* `pp perf --secs 120` on HK with `hk-new-game`, before and after, comparing the wineserver thread's ms/s in `threads.txt` and FPS. Then HK `first-frame+10`, Portal 2 `first-frame+20` (request-heavy: `2026-10-05-portal2-hitches-requests.md`), Death's Door with `dd-new-game` to `first-frame+60`, and The Witcher 3 `first-frame+30`.

---

## T2. FEX's call-return stack reset costs a 16 MB decommit and recommit, about 800 times a second

**What.** On each code invalidation that hits translated blocks, `ContextImpl::InvalidateThreadCachedCodeRange` calls `ResetCallRetStack`. That calls `FEXCore::Allocator::VirtualDontNeed` over the whole 16 MB stack, which on Windows is `MEM_DECOMMIT` plus `MEM_COMMIT`. In Wine that is `decommit_pages`, which maps 16 MB fresh over the range, then `mprotect_exec`, which calls `vm_protect`, then refaults on touch.

Mono's call-site backpatching (`MonoBackpatcherWrite`, see `2026-09-26-hk-mono-trampoline.md`) drives this on the Unity main thread.

**Where.**
- `fex/FEXCore/Source/Interface/Core/Core.cpp`: `ResetCallRetStack` and `InvalidateThreadCachedCodeRange` (the "ml610" note explains why the full 16 MB clear was restored).
- `fex/Source/Windows/Common/InvalidationTracker.cpp` (`[inv-census]`).
- `ntdll-unix/virtual_ios.c`: `decommit_pages` (the mmap-over branch) and `mprotect_exec`.

**Evidence (HK).**
- `E 2C [callret] ml610 resets=1024 … site=core` at 16:34:16.0.
- `resets=17408 … reset_us=474490 max_us=1770` at 16:34:35.9. That is 16,384 resets in about 20 s, all on thread `002c`.
- `[callret-gen] gen=1 resets=1260 unique_threads=2 redundant=1258`.
- `[inv-census]` shows 987 of 1,024 invalidations from the "aligned" source, at 29 ms per 1,024.
- In dev each reset also writes an `err:virtual:mprotect_exec` line and a `[span-census] ALLOC` line (`ALLOC #17696 … live=17683`; the "live" count never falls, because decommits are not counted as frees).

**Why it is wrong.** On Linux this reset is one cheap madvise. On iOS it is a 16 MB remap per Mono backpatch. Only the part between the current call-return stack pointer and its default location holds live predictions. Entries below the pointer have been popped, and a CALL rewrites them before any RET reads them.

**Gain / risk.** Gain: about 24 µs per reset is spent in the reset alone, about 2.3 % of HK's main thread at the menu, plus refaults (and log I/O in dev). It applies to every Mono/Unity title. Risk: a stale predictor entry left above the pointer branches into an invalidated translation. That is a correctness hazard, so the zeroed range must cover everything a RET can read.

**Touches.** HK, Death's Door, Among Us, Shogun Showdown (Unity titles). FEX series (`patches/fex`).

**Confidence.** High on the counts. Medium-high on the bounded clear being correct; it needs FEX review of `BranchOps.cpp`'s guard window and `Dispatcher.cpp`'s JITCallback sentinel push, which tests the whole 16 MB.

**Steps.**
1. *Dive.* Track a per-thread low-water mark of `callret_sp`, read at each reset (cheap: one load from the frame). Log its distribution. Read the RET underflow path: what reads above `DefaultLocation`?
2. *Fix.* Replace `VirtualDontNeed` with a `memset` of `[min(sp, low-water), DefaultLocation + guard]`. Keep a full decommit every Nth reset, or when the low-water mark passed some MB, to keep ml609's memory finding. The `[callret]` line keeps its counters.
3. *Gate.* HK `pp perf --secs 120` with `hk-new-game` (main-thread Mi/f and FPS), then HK `first-frame+10`, Death's Door with `dd-new-game` to `first-frame+60`, Among Us to `first-frame+20`, The Witcher 3 to `first-frame+30` as a non-Mono control, and Portal 2 for the WoW64 frontend.

---

## T3. Pure x86-64 images are copied into the 512 MiB JIT pool

**What.** `mprotect_exec`'s `PROT_EXEC` branch copies every image whose exec request fails into the pool. That includes pure x86-64 PEs: no `.hexpthk`, so the copy is "NOT marking jit … as EC" and is not x18-patched. FEX translates x86 code from the PE address. The [x86-ptr] notes call a pool address in guest control flow "POISON", so the copy never runs and its `.data` is not the live one.

**Where.** `virtual_ios.c`, `mprotect_exec` → JIT-pool path, about lines 9690–10950: "copied image", the `is_arm64ec_hybrid` test, and "skipping x18 patcher for non-ARM64 PE".

**Evidence (HK `[jit-pool] image`).**

| Image | Size |
| --- | --- |
| `playport-session.exe` (`?`) | 0x10000 |
| `WindowsPlayer.exe` | 0xa9000 |
| `UnityPlayer.dll` | 0x211e000 (33 MB) |
| `mono-2.0-bdwgc.dll` | 0xa43000 (10 MB) |
| `steam_api64.dll` (x86-64 gbe, `build/stages/steamapi.sh`) | 0x809000 (8 MB) |

All have `tramp+0x0`. Together that is about 52 MB of `title: pool: head_mb=138`. These are dirty pages, so device RAM as well.

**Why it is waste.** Pool space is the limit decision 0036 is about (Kingdom Come: Deliverance needed the other 384 MiB). Large x86 executables (The Witcher 3's, KCD's) are copied whole.

**Gain / risk.** Gain: pool head (about 38 % in HK) and RAM. Risk: some lookup may still read the copy. Candidates: `ios_jit_translate_addr`, the IAT-sync data-pointer rule, `ios_va_is_x86_code`, the healer, `wine_host.c pc_bucket`/`ios_jit_pool_image_pc`, `ios_pe_module_name`. The module must stay registered in `ios_jit_mappings` with its `.text` bounds, without a pool copy.

**Touches.** Every x86-64 title; decisions 0019, 0036.

**Confidence.** Medium. The waste is certain; whether nothing reads the copy is not.

**Steps.**
1. *Dive.* List every reader of `ios_jit_mappings[i].jit_base`. For each, decide what it needs for an x86 image. Check whether `ios_jit_add_mapping` and its users accept `jit_base == pe_base` (no copy).
2. *Fix.* For `Machine == 0x8664` without `.hexpthk`, register the mapping, record `.text`, and return without a copy. The PE view stays non-exec, as FEX needs.
3. *Gate.* HK `first-frame+10` with `title: pool:` head before and after. Death's Door with `dd-new-game` to `first-frame+60`. The Witcher 3 `first-frame+30` (the largest x64 exe installed). Portal 2 `first-frame+20`: i386 images go through the WoW64 path; check it is untouched.

---

## T4. Steered-arena bookkeeping can free live memory

**What.** `ios_steer_reclaim_dead` releases steered 512 MB-class reservations whose recording thread has exited, once both steer targets are full and `steer_armed` is set. Two bugs:
1. The guard against freeing an arena with contents (`ios_steer[].inuse`) is set only for allocations at `>= 0x7C00000000`. Since 0085, arenas are steered into `[0x7400000000, 0x7800000000)`, so commits inside them never set `inuse`.
2. `ios_steer[]` entries are never invalidated when the guest releases an arena itself. Reclaim later calls `NtFreeVirtualMemory(MEM_RELEASE)` on that base, which bottom-up placement probably reissued to another allocation.

The code's own ml332 note says "'owning thread died' was never a valid release condition at all".

There are related heuristics:
- a per-thread cap of 24 steered arenas, after which requests fall back into the window (ml462, a CEF livelock guard);
- a fallback into the FEX band (what froze HK's cinematics before 0085), still active once armed;
- steering only in `NtAllocateVirtualMemory`, not in `…Ex` (VirtualAlloc2 users such as mimalloc are never steered);
- in The Witcher 3, the jumbo hold covering the steering range (evidence "Left").

**Where.** `virtual_ios.c`: `ios_steer_reclaim_dead` (about line 5598), the steer valve in `NtAllocateVirtualMemory` (about 19056–19170), the `[va-exit]` inuse marking (about 19410, duplicated at about 20604 in `…Ex`), `ios_thread_died`/`ios_thread_alive`.

**Evidence.** Code only; no run has reached reclaim since 0085. The trigger needs both targets full, which a long session with many reserve-only arenas can reach.

**Why it is wrong.** Windows reservations belong to the process and are never released by a thread exiting. This frees VA the guest still holds, or VA another owner now holds: silent memory corruption.

**Gain / risk.** Removes a latent corruption. Risk of the fix: without reclaim a title that leaks reserves fails honestly with `STATUS_NO_MEMORY` instead.

**Touches.** Any title with reserve-only arenas (Unity's 512 MB arenas, Death's Door's 18). Decision 0054.

**Confidence.** High on the mechanism. Low on frequency.

**Steps.**
1. *Fix.* Delete `ios_steer_reclaim_dead`, `ios_tid_dead`, `ios_thread_died`'s steer use, and the `inuse` marking. Keep `ios_steer[]` only if `[steer]` logging needs it.
2. *Fix.* Raise or drop the per-thread cap; keep a total cap instead. Decide whether the FEX-band fallback stays (it starves FEX threads) or the request fails.
3. *Fix.* Apply the same steering to `NtAllocateVirtualMemoryEx` when there is no address requirement.
4. *Gate.* HK `first-frame+10`, Death's Door ×2 to `first-frame+25` (`[steer]` lines all `above ceiling`, `refused=0`), The Witcher 3 `first-frame+30` (jumbo hold present), Portal 2 `first-frame+10`.

---

## T5. Hinted ≥1 GB reserves: a retry ladder, a size lie and "soft" grants

**What.** A hinted `MEM_RESERVE` of 1 GB or more that fails at its hint does not fail, as Windows does. The code tries, in order: 16 GB-aligned slots with the hint's offset kept (PartitionAlloc's guard layout); the jumbo hold; the cage, reporting 8 GB when the view is 64 KB short and recording the tail as "soft"; then a kernel pick. For 16 GB and up it ends with `[soft-pool] GRANTED soft …`: success with VA that is not a Wine view and not mapped. Later commits there are "materialised" with `anon_mmap_fixed`, outside Wine's view tracking. That is the same kind of lie 0083 removed for 4 GB.

**Where.** `virtual_ios.c`, `NtAllocateVirtualMemory`: "task#29 CEF plan C" (about 19191–19385), `ios_soft[]`, `ios_soft_find`, the commit-side materialise block (about 18694–18765), `ios_jumbo_census`, `ios_bigres_*`.

**Evidence.** Code; none of the cohort hit it in these logs.

**Why it is wrong.**
- Hinted reserves must fail on conflict.
- An unbacked grant makes `VirtualQuery` say MEM_FREE for memory the guest believes it holds.
- `NtProtectVirtualMemory`/`NtFreeVirtualMemory` on it fail.
- The size lie breaks `VirtualQuery`-based allocators.

The callers it was built for (Chromium's PartitionAlloc and V8 cage in CEF) do not run in Playport; games with an embedded CEF would now get lies instead of failures.

**Gain / risk.** Gain: correctness, and about 600 lines with their per-commit table scans. Risk: The Witcher 3's exact 8 GB ask must still reach the jumbo hold (0017, 0083).

**Touches.** The Witcher 3 (jumbo hold); any title embedding CEF; decision 0054.

**Confidence.** High.

**Steps.**
1. *Dive.* Confirm from `w3*/pull/s1-host.log` which branch serves The Witcher 3's 8 GB (`[jumbo-hold] ml996` vs `[cage] grant`).
2. *Fix.* Keep only "hinted reserve failed → the jumbo hold if it fits → fail". Remove the soft grants, the cage size lie, `ios_soft*`, the slot walk, and `ios_bigres*`/`ios_jumbo_census` unless the host reads them (it does not).
3. *Gate.* The Witcher 3 `first-frame+30` (8 GB ask served, `refused=0`), HK `first-frame+10`, Death's Door `first-frame+25`.

---

## T6. The pool warmer's diagnostics run in release, every ~2 s, for the session

**What.** `ios_pool_warmer_thread` (started at JIT pool init in every build) does much more than warm pages.

Every full cycle (~2 s):
- `[ca-shmem-probe]`: 4 `vm_allocate` + `vm_deallocate` of 100 KB (an ml896 CoreAnimation experiment);
- `malloc_zone_check(NULL)`: a whole-heap validation that takes the malloc zone locks;
- `ios_pump_sample()`: a CEF-era census of the "chrome_ipc pump", with `[alert-ring]`, `[waiters]`, `[hot-lock]` hex dumps, and `[lock-census]` doing `thread_get_state` and frame walks on waiting threads;
- `[footprint]` via `task_info`.

On other schedules:
- `[pool-rot]` .text sweep every 5 cycles;
- `ios_slot_probe` (PartitionAlloc slots), two `ios_window_inventory` walks and `ios_bigres_report` at cycle 1 and then every 150 cycles. One walk covers the 486 GB "layerkit-span", which crosses iOS's ~33,000 low regions and the 32,796-region pool alias;
- the `[phys-map]` walk over every region (68,684 in HK) at cycle 2 and every 150 cycles;
- a TCP loopback self-test at cycle 1;
- a 250 ms `task_info` cadence once the footprint passes 2,400 MB.

Separately, every process start arms a `[Wine WATCHDOG 2s]` block that suspends the main thread (`server_ios.c`, `server_init_process_done`). It is not gated in either variant.

**Where.** `virtual_ios.c` `ios_pool_warmer_thread` (about lines 666–1190), `signal_arm64_ios.c` `ios_pump_sample`, `unix/sync.c` `ios_alert_ring_dump`/waiter dump, `server_ios.c` WATCHDOG.

**Evidence.**
- HK: `[slot#0] … DIRTY regions=32796`, `[phys-map] rev=ml359 cycle=2 regions=68684`, `[zone-check] armed and PASSING at cycle=1 (0 ms per check)`. That is the only cost ever logged, measured on an empty heap.
- `[alert-ring]` and `[hot-lock]` dumps every cycle.
- Two `[Wine WATCHDOG 2s]` blocks per launch.
- None of these is gated by `MADEIRA_NO_DIAGNOSTICS` (only `[span-census]`/`[valloc]`/`[vfree]` are, via `ios_no_diagnostics()`).
- 0076 already showed one census costing 154 ms of a P-core inside a 596 ms Portal 2 hitch.

**Why it is waste.** Everything except the page warming answered a CEF, PartitionAlloc or CoreAnimation question that is closed. `malloc_zone_check` serialises against every other thread's malloc while it runs.

**Gain / risk.** Gain: wakeups, mach calls, malloc lock hold time, and log volume in release (about 1 line/s). Small to medium, and unmeasured for the zone check. Risk: low. Keep the page warming (it may still guard against the compressor taking blessed pages) and one footprint sample.

**Touches.** Every title, both variants; decision 0009.

**Confidence.** High that the work runs. Low on what the zone check costs on a 2–3 GB heap with xzone malloc.

**Steps.**
1. *Dive.* In a dev diagnostic build, time each warmer section per cycle into one line. Run HK and Portal 2 for 120 s.
2. *Fix.* Delete `ca-shmem-probe`, `zone-check`, `ios_pump_sample` and its alert, waiter and orphan dumps, `ios_slot_probe`, `ios_bigres_*`, the layerkit window inventory, and the loopback self-test. Put `[phys-map]` and the window inventory behind a dev-only switch, or drop them. Gate the WATCHDOG under `MADEIRA_NO_DIAGNOSTICS`, or delete it.
3. *Gate.* HK `first-frame+10`, Portal 2 `first-frame+20` (hitches), and a release-variant install and Play by hand if the owner is present. Otherwise say it was checked on the dev build only.

---

## T7. Dev runs, which every measurement uses, carry a 500 Hz thread-suspending profiler

**What.** `[PROF]` in `server_init_process_done` is skipped only under `MADEIRA_QUIET`, which dev builds do not set. It suspends the busiest thread about 500 times a second for the whole session; its own comment says "a few % of frame time plus heat". The `[thread-sample]` bursts (every 20 s, suspending every thread), `[xp]` every 250 ms and `[wprof]` also run in dev.

The dev runtime also logs per call: `err:virtual:mprotect_exec` on every protection change (17,000+ lines per HK play, from T2), `[cs-life]` per critical section deleted, and `[valloc]`/`[vfree]` ×3000. That is about 48,900 lines in 25 s.

**Where.** `server_ios.c` (about lines 4521–4720), `virtual_ios.c` `mprotect_exec`'s `ERR`, `Dev/Diagnostics.swift` (its "CPU sampling" key is the separate `WINE_IOS_PROF`).

**Evidence.**
- HK log: `[PROF] tid=0xb23b cpu=210 n=4096 top: …` and `[PROF-BT] …`.
- `pp perf`/`tools/perf.py` set nothing that turns it off.
- Decision 0009 notes `perf-run.py` needs the samplers; `[PROF]` is not among the lines it reads.

**Why it is wrong.** Every perf evidence record measures a runtime that suspends the game thread 500 times a second. Release does not.

**Gain / risk.** Gain: measurement validity, and dev frame times closer to release. Risk: none at runtime; losing `[PROF]` lines nobody reads.

**Touches.** Decisions 0009 and 0012 (any switch goes through the Diagnostics page).

**Confidence.** High.

**Steps.**
1. *Fix.* Make `[PROF]` opt-in (`MADEIRA_PROF=1`, set from a Diagnostics key, as `WINE_IOS_PROF` is). Make the `mprotect_exec` `ERR` a `TRACE`.
2. *Gate.* HK `pp perf --secs 120` twice, before and after, comparing main-thread Mi/f and FPS. Write the delta in an evidence record so older perf records can be read against it. HK `first-frame+10`.

---

## T8. The thread registry never frees slots and leaks port references

**What.** `ios_setup_mach_exception_handler` appends each thread to `ios_thread_registry[512]`. Slots are never freed: `ios_thread_count` only grows, and reuse happens only when the kernel recycles a port name. Each registration pins 4 extra send rights, which are never released, so names cannot recycle. After 512 threads have ever been created, a new thread is not registered: "Mach events on it will resolve to the slot-0 TEB (wrong process!)". Every lookup (`ios_lookup_thread`, `ios_teb_is_registered`, pump sample) is a linear scan, on the fault path too.

**Where.** `signal_arm64_ios.c`: `IOS_MAX_WINE_THREADS`, `ios_setup_mach_exception_handler` (about line 6069), `ios_thread_registry_forget` (WoW64 only).

**Evidence.** The Witcher 3 created about 50 Wine threads in 30 s (`[srv-own] init_thread tid=0024…00f4`), with fd reuse showing threads exiting. Titles with thread-per-task patterns, or long sessions, add up.

**Why it is wrong.** It is a hard cliff in a long session, it gives the wrong process's TEB for exceptions, and it leaks port names.

**Gain / risk.** Gain: correctness in long sessions. Risk: freeing a slot while the handler thread is reading it. Needs the same publish order the code already uses (teb, then barrier, then port).

**Touches.** Every title; long sessions.

**Confidence.** High on the mechanism. Unknown on how often it is reached.

**Steps.**
1. *Dive.* Log `ios_thread_count` in `title: limits:`. Run HK under `pp perf --secs 600` with `hk-walk` and see whether it grows with play.
2. *Fix.* Clear the slot (port, then teb) and drop the extra refs in the pthread exit path (`thread_ios.c`, next to `ios_thread_died`). Keep a free list. Optionally hash on the port.
3. *Gate.* HK `first-frame+10`, The Witcher 3 `first-frame+30`, Portal 2 `first-frame+10` (WoW64 uses `ios_thread_registry_forget`).

---

## T9. Wine's free-space model disagrees with iOS, and the main executable lands in iOS's low VA

**What.** Wine's view list treats `[4 GB, 64 GB)` (iOS's own, about 33,000 regions) and the GPU carveout `[64 GB, 448 GB)` as free. So:
- `VirtualQuery` reports about 450 GB of MEM_FREE that cannot be allocated;
- `GetSystemInfo`/`GlobalMemoryStatusEx` report 512 GB of user VA (ml990, `ullTotalVirtual=524287 MB`) when about 48 GB is usable;
- the scan for a relocated main executable starts at 4 GB and crawls.

**Where.** `virtual_ios.c`: `map_free_area_inner`/`ios_skip_occupied`, `ios_clamp_user_space_limit` (ml990), the `ml991` SystemBasicInformation log, and image placement for a main exe whose preferred base is refused.

**Evidence.**
- HK: `[va-scan] SLOW window=0x100000000..0x73ffff0000 size=0xa9000 … tries=759 … firstfail=0x100000000 errno=12 … iOS REFUSED A FREE ADDRESS`, then `image 0x128cf0000+0xa9000 (WindowsPlayer.exe)`, in iOS's low VA.
- Every builtin DLL first tries an impossible preferred base: `ml985: preferred base 0x6fffffeb0000 … REFUSED status=0xc000000d`, ×12 per process in the log head. They are then mapped elsewhere and relocated.
- Evidence "Left": 700–1,100 tries per launch.

**Why it is wrong.** Hooking libraries that walk `VirtualQuery` for MEM_FREE near a module (MinHook, Detours trampolines within ±2 GB) get addresses that always fail. An exe in iOS's low VA has only iOS land within ±2 GB. Engines that size reserves from `ullTotalVirtual` ask for the impossible (RDR2's 28 GB, ml990).

**Gain / risk.** Gain: launch time (one crawl), correct `VirtualQuery`, a usable neighbourhood for the exe. Risk: medium. Reserving ranges in Wine's view tree interacts with `address_space_start`, the 4 GB-floor change (0084) and WoW64's owned window (0049ff).

**Touches.** Every title; WoW64 (Portal 2).

**Confidence.** Medium.

**Steps.**
1. *Dive.* Read how upstream registers reserved areas (`mmap_add_reserved_area`, and the FEX `FEX_ONLY` area registered in `ios_reserve_fex_arena`). Check what `NtQueryVirtualMemory` reports for a reserved area (MEM_RESERVE with no view, rather than MEM_FREE).
2. *Fix.* Register `[address_space_start, 0x7000000000)` as host-owned, so scans skip it and `VirtualQuery` reports it as reserved. Place a main exe whose preferred base is refused inside the guest window. Optionally lower `ullTotalVirtual` to the guest windows' real size. Make builtin DLL bases default into the window, so they skip the refused first attempt.
3. *Gate.* HK `first-frame+10` (no `[va-scan] SLOW` for the exe), Death's Door `first-frame+25`, Portal 2 `first-frame+10` (WoW64 window), The Witcher 3 `first-frame+30`.

---

## T10. Layout constants still shaped for PartitionAlloc's three 16 GB pools

**What.** These constants remain from the three-pool experiment:
- the furniture ceiling `0x73ffff0000` (64 KB under a PartitionAlloc guard slot);
- `ios_spill_cap = 0x7800000000` (PartitionAlloc slot 2);
- `ios_steer_slot = 0x7C00000000`, which is the FEX band;
- `ios_is_arena_addr` (`>= 0x7400000000` means "PartitionAlloc arena");
- `[phys-map]` band names (`CEF-PA-POOL`);
- `wine_host.c pc_bucket`, which names PEs only in `[0x7000000000, 0x7400000000)`;
- image views, whose `limit_high` keeps them under the ceiling (the 16 GB window).

Since 0083–0085, `[0x7400000000, 0x7c00000000)` (32 GB) holds only steered arenas and above-ceiling placements.

**Where.** `virtual_ios.c` around lines 5330–5550 (the ml105–ml170 history), 11468, 12104, 12697, 19236–19250; `ios_usable_va_floor_get`; `wine_host.c` `pc_bucket`.

**Evidence.**
- The constants and their comments.
- The VA evidence: at the refusal, 30 GB above the ceiling was free.
- The Witcher 3's jumbo hold collides with the steering range.

**Why it is wrong.** Images and every caller with a `limit_high` compete for 16 GB, while 32 GB sits outside their reach for a reason that no longer exists.

**Gain / risk.** Gain: about 3× room for images and limited callers, and simpler placement rules. Risk: high. Many rules interact (clamp, 0082's above-ceiling scan, steering, jumbo hold, ARM64EC bitmap sizing, pool alias at `0x7000000000`, host-side address assumptions).

**Touches.** Every title; decisions 0036 and 0054.

**Confidence.** Medium.

**Steps.**
1. *Dive (host only).* List every hard-coded address in `ntdll-unix/*_ios.c`, the wineserver tree, `wine_host.c` and the FEX frontend (`IosJitTranslate`, band selector). For each, record what it assumes. Write a target map: guest window `[floor, 0x7c00000000)`, FEX band above.
2. *Fix* only after T4, T5 and T9 have landed, as one patch moving the ceiling to `0x7c00000000`. Retire the steer and spill constants; keep the jumbo hold; rename the census bands.
3. *Gate.* All installed titles to `first-frame+20`. Death's Door with `dd-new-game` to `first-frame+60`. The Witcher 3 `first-frame+30` (`refused=0`, jumbo served). Portal 2 `first-frame+20`.

---

## T11. Boot-time probes and the layerkit exclusion

**What.** At every start:
- `ios_va_profile` makes 9 fixed 16 KB probes (32–63 GB and 0x7c00000000; all but the last refused on this phone);
- `[layerkit-range]` allocates up to 128 × 256 MB `VM_MAKE_TAG(51)` chunks to measure CoreAnimation's range, then frees them. On this phone it reaches the cap: `128 x 256MB … span 0x1285b8000..0x7800000000 (486778 MB)`. That span covers the whole guest window. The first guest scan therefore fails (`err:virtual:map_free_area_inner couldn't map free area … size 0x4000`) and the exclusion is dropped (`ml901 exclusion DROPPED`). Until then `ios_in_layerkit` is checked on every scan step;
- the `[va-gaps]` map walk at pool init, the `[usd-map]` store test, the `[jit-pool] bump-probe` and the `ml993`/`ml992` memory probes;
- the UE5-specific `ios_tls38_poll` on every server wait and every `NtAllocateVirtualMemory` (it stops after 60 lines);
- the `[exec-alloc]` and `[bigres]` probes in the allocate path, duplicated in `…Ex`.

The JIT pool's RW alias exists as 32,768 separate 16 KB map entries (`[slot#0] … regions=32796`), which lengthens every Mach walk of the window. It comes from the helper's per-page blessing plus the remap (host side).

**Where.** `virtual_ios.c` `ios_va_profile` (about 13327), `map_free_area`/`ios_in_layerkit`, `ios_tls38_poll` (about 18110), `NtAllocateVirtualMemory`/`…Ex` probe blocks; `wine_host.c` pool setup.

**Evidence.** The HK log head, lines 140–250.

**Why it is waste.** The questions are answered. The layerkit measurement is meaningless on this device, and dropping the exclusion costs a failed scan.

**Gain / risk.** Gain: small (tens of ms at start, smaller code). Risk: low.

**Touches.** Every title.

**Confidence.** High.

**Steps.**
1. *Fix.* Remove `ios_va_profile`'s probes and the layerkit machinery (`ios_layerkit_*`, its map_free_area wrapper, its warmer inventory), `ios_tls38_poll`, and the ml968 experiment. Its kill switch is already off; ml969's alias is handled in T13. Halve the `…Ex` copy by sharing one helper with `NtAllocateVirtualMemory`.
2. *Dive, separately and host side.* Whether the pool RW alias can be made with one `vm_remap` after blessing (TXM permitting). If so, it is a `wine_host.c` change with its own gate.
3. *Gate.* HK `first-frame+10` (no `[layerkit-range]`, no failed `map_free_area_inner` at boot), Portal 2 `first-frame+10`.

---

## T12. The stale-pointer healer finds nothing to heal

**What.** Exec faults on PE addresses (calls through pointers that still hold an ARM64EC module's PE address instead of its pool copy) are each serviced by the single Mach handler thread. The healer queues an address after 256 faults and rewrites matching IAT, then `.data`, slots in pool copies. In HK every queued address is an ntdll EC address, and every heal rewrote nothing. The healer thread polls its queue every 100 ms for the session.

**Where.** `signal_arm64_ios.c` `ios_stale_va_enqueue`/`ios_stale_va_scanner`; `virtual_ios.c` `ios_jit_patch_stale_pointer`.

**Evidence.**
- HK: `[stale-heal] 0x73ffe0b7ec -> 0x1084e77ec, rewrote 0 slot(s)`.
- The same for `0x73ffdf5c90`, `0x73ffdfe7d0` and `0x73ffdf5cc0`.
- `[Wine WATCHDOG 2s] mach: msgs=3139 x18_fixes=1742`.

**Why it matters.** Each such call keeps costing a Mach round trip through one thread that serves every fault in the process. Where the pointer lives is unknown: the guest heap, FEX's tables, a TEB/CONTEXT, or a non-pool copy.

**Gain / risk.** Unknown until measured. Risk: a wider rewrite was what broke boot on 2026-07-04 (see the comments).

**Touches.** Every title.

**Confidence.** High that the heal fails. Low on the cost.

**Steps.**
1. *Dive.* With `WINE_HOST_DIAG` (`[EXC_SAMPLE]` every 4,096th message) and a one-off probe, find the fault rate per second for these addresses in play, and the caller's frame (LR, x30) at the fault. Locate the 8-byte slot holding the address (scan the faulting thread's stack, TEB, and FEX's thread state for the value).
2. *Fix* only once the slot's owner is known: rewrite at the producer (for example the export or forwarder resolution that hands out a PE address for an EC function). Turn the scanner into a blocking wait (semaphore) instead of a 100 ms poll.
3. *Gate.* HK `first-frame+10`, Death's Door `first-frame+25`, The Witcher 3 `first-frame+30`.

---

## T13. Behaviour that differs from Windows (smaller items)

Each item is low on its own.

- **CREATE_SUSPENDED is ignored.** `server_init_process_done` sets `data->suspend = 0` ("[Wine init_done] overriding suspend"). A launcher that creates a child suspended to patch or inject before `ResumeThread` races with it. Not hit in the cohort logs. *Dive:* check whether the thread-based CreateProcess can hold the first thread on a semaphore released by `NtResumeThread`. *Gate:* a title with a launcher, if one is installed; otherwise HK and Portal 2 `first-frame+10`.
- **ml969 "low alias" is on by default.** Built for RDR2's EMP.dll. In a process with an image based below 4 GB, a 4 KB RW allocation also gains a 32-bit name, so a truncated-pointer dereference that would crash on Windows is silently serviced (`virtual_ios.c` about 18300–18440, `MADEIRA_NO_LOW_ALIAS`). *Fix:* default off (RDR2 is not in the cohort). *Gate:* HK, Portal 2.
- **Process gate.** `NtCreateUserProcess` refuses `steamerrorreporter`, `gldriverquery`, `vulkandriverquery`, `steamsysinfo`, `hardwareupdater` and `unitycrashhandler64` with ACCESS_DENIED, matching a substring anywhere in the full path, not the base name (`process_ios.c` about 950). *Fix:* match the base name. Keep the list.
- **NSI.** Only the three TCP connection tables are served (`nsi_unixlib_ios.c`); every other module (interfaces, IP addresses) returns NOT_SUPPORTED, so `GetAdaptersAddresses`/`GetAdaptersInfo` fail. Not seen in the cohort logs (`[nsi-ios]` absent). *Dive:* what Unity's `deviceUniqueIdentifier` and network libraries do on failure.
- **Stack floor.** Every thread stack with a guard page is raised to 8 MB (ml424, CEF recursion). It costs only VA now that the window has room, but it changes stack-overflow points for engines that size small worker stacks. Leave it unless T10 shows pressure.
- **Audio timer.** `ios_timer_loop` sleeps `usleep(10000)` per period, so the period drifts and it wakes even when the stream is stopped (`audio_null_ios.c` about 980). *Fix:* absolute deadlines, and park while stopped. *Gate:* HK audio by ear needs the owner; otherwise `pp perf` underrun counters if any exist.

---

## T14. The session root is an x86-64 program, so FEX starts in the idle root

**What.** `app/SessionRoot/playport-session.c` is built for x86-64 (`build/stages/session-root.sh`). The root therefore loads `libarm64ecfex.dll` and about 14 DLLs into its own pool copies, and gets FEX thread state, a 16 MB call-return stack and FEX-band spans for its thread.

**Evidence.**
- HK: the root's images take the pool to `used=0x13f7000` (about 20 MB) before the game's first image.
- `E 24 [callret] zero-scrub` belongs to the root's thread.

**Why it matters.** Pool and RAM paid by every title for a process that only waits (decisions 0027, 0030).

**Fix.** Build the root as ARM64EC (`arm64ec-w64-mingw32`) or aarch64 if Wine's loader allows it there. This is outside Madeira's layer (Playport's own code), noted because it costs every launch.

**Confidence.** Medium on the gain; whether the ARM64EC loader still loads FEX for an ARM64EC root is the open question.

**Gate.** HK `first-frame+10` (pool head before the game's first image), Portal 2 `first-frame+10`.

---

## Order

Ranked by value against risk:

1. **T1** wineserver loop: every title, CPU and heat.
2. **T2** call-return stack reset: Unity/Mono main threads (FEX series).
3. **T3** x86 images in the pool: pool and RAM, decision 0036.
4. **T4** steered-arena reclaim: latent corruption; the fix is mostly deletion.
5. **T5** hinted-jumbo ladder and soft grants: lying grants; the fix is deletion.
6. **T7** dev profiler: measurement validity for everything after it. Do it early.
7. **T6** warmer diagnostics in release.
8. **T8** thread registry.
9. **T12** healer (dive first).
10. **T9** VA model and exe placement.
11. **T11** boot probes and layerkit.
12. **T10** layout redesign: last, after T4, T5, T9 and T11.
13. **T14** session root.
14. **T13** items as time allows.

**Parallel** (different files; research and drafting can run at once, the phone gate stays one writer at a time):
- T1 (`wineserver/fd_ios.c`, `server_ios.c` wake);
- T2 (`patches/fex`: `Core.cpp`/`CallRetStack.h`);
- T7 (`server_ios.c` `[PROF]` + `Dev/Diagnostics.swift`);
- T8 (`signal_arm64_ios.c` registry + `thread_ios.c` exit path);
- T12's dive (logging only);
- T14 (`app/SessionRoot`, `build/stages`).

**Serial** (all in `virtual_ios.c`'s allocation and placement paths, where hunks overlap and order matters): T4 → T5 → T11 → T9 → T10. T3 (`mprotect_exec` image path) and T6 (warmer, plus `signal_arm64_ios.c`'s pump) are separate regions of `virtual_ios.c`. They can be drafted alongside the serial chain but should land between its steps, not in the middle of one, so the series stays rebase-clean.

## Looked at and judged fine (do not redo)

- **The FEX band:** `ios_reserve_fex_arena` reserves 16 GB at `0x7c00000000` PROT_NONE, registered FEX-only. `ios_fex_band_stats` and `ios_jit_pool_stats` feed the host's `title: band:`/`title: pool:` lines (`wine_host.c`). Keep both.
- **ml990 and ml992:** clamping the user VA limit to the task maximum (512 GB rather than 128 TB) and reported physical memory to the memory limit are the right direction. T9 only asks whether 512 GB is still too generous.
- **0082, 0084 and 0085** as merged, apart from the reclaim and inuse interaction in T4.
- **The pool warmer's page touching itself** (cheap; may still protect blessed pages). The ml1052 grace wait applies only to ≥32 MB images at process start.
- **The KUSER_SHARED_DATA sub-floor window** and low-address fault emulation: forced by iOS's mandatory `__PAGEZERO`. ml968's low-allocation experiment is already off by default.
- **The task-level Mach exception port, EXC_BREAKPOINT decline and FEX's `brk #0xCAFE` suspend checks:** needed for FEX and for the StikDebug/another-app JIT routes (decision 0051).
- **`[dc-census]`** (capped at 16 samples), the `[decommit-zero]` 64-byte read-back, and `[span-census]`/`[valloc]`/`[vfree]`/`[inv-census]`, which 0018 and the FEX side already silence in release.
- **The NSI TCP-table unixlib** (`GetExtendedTcpTable` is generally useful); see T13 for the missing tables.
- **madsync:** compiled but off (decisions 0023, 0054).
- **Audio:** the detach quiesce and host suspend/resume in `audio_null_ios.c`.
- **The single Mach handler thread at `QOS_CLASS_USER_INTERACTIVE`:** architecture, not waste. Measure it only through T12.
- **The `MADEIRA_DESKTOP`-only `[srv-queues]` dump** in the wineserver loop is off unless that variable is set.

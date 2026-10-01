# Start-up profile: from Play to Hollow Knight's first frame

**Date:** 2026-09-25. **IPA:** dev, sha256
`c027c1551488063c2ec37afe2a02b31457c5fd35107c08b97f0e59b7c07b5f1e`, installed in
place with `build/build-and-install --no-build`. **Tree:** the commit that adds
this record (`WINE_HOST_LOG_STAMP`, `WINE_HOST_DIAG`, the thread ids of the
wineserver and guest threads), over `82070e1` (the launch timeline).
**Result:** Play to the first frame takes 11.4–13.1 s. The JIT pool takes
3.0–3.3 s of it; the rest (8.4–9.9 s) is the game's start inside the runtime,
CPU-bound on Unity's main thread and the one Mach exception handler thread,
and dominated by FEX's self-modifying-code tracking of Mono's JIT pages.

## 1. The timeline

`title: +<s> s` lines (LaunchCoordinator), Hollow Knight, iPhone18,4, iOS 27.0:

| run | how | runtime started | first frame |
|---|---|---|---|
| `ui-runs/timeline-2` | `ui-device-run.py --play app-367520` | 3.20 s | 13.08 s |
| `title-runs/timeline-quiet` | `title-device-run.py --cfg env.MADEIRA_QUIET=1 …` (the release switches) | 3.13 s | 12.69 s |
| `title-runs/stamp-1` | `--env WINE_HOST_LOG_STAMP=1` | 3.26 s | 12.40 s |
| `title-runs/stamp-3` | `--env WINE_HOST_LOG_STAMP=1 --env WINE_HOST_DIAG=1` | 3.04 s | 11.40 s |

The JIT step is 0.5 s of helper start and attach plus the bless of 57,344
pages (StikJIT already pipelines the writes 128 at a time). The release
build's quiet switches change the first frame by 0.4 s: the dev log is not the
cost.

## 2. Where the 9 s go

With `WINE_HOST_LOG_STAMP=1` every runtime line carries seconds since
`wine_host_init` (`stamp-1`): FEX up at 0.18 s, the Unity DLLs by 1.0 s, the
swap chain at 3.07 s, `steam_api64.dll` at 5.0 s, `Present #1` at 9.15 s. The
`[xp]` census puts the process at 270–430 % CPU throughout, nearly all on P
cores. Two threads carry it (`stamp-2`, where wine_host now names its
threads): Unity's main thread `-0024` (150–300) and native thread
`m943601` (about 100 from +1.9 s to +6.3 s). `m943596` is the wineserver thread
(5–30). From +6.3 s Wine thread `-00e8` runs alone until the first frame.

`m943601`'s share matches the exception count: 261,851 to 296,866 Mach
exceptions before `Present #1` (DXMT's `machexc_delta`), all served by one
handler thread (`signal_arm64_ios.c`) while the faulting thread waits.
`WINE_HOST_DIAG=1` turns on the runtime's `[EXC_SAMPLE]` (every 4,096th
exception): all 71 samples before the first frame were `EXC_BAD_ACCESS`,

| samples (x4096) | fault |
|---|---|
| 60 | a store into `0x7038000000..0x7838000000`, the guest heap (the range the runtime calls CoreAnimation's; its exclusion was dropped at start) |
| 6 | an exec fault at a PE address |
| 5 | a store into the JIT pool's RX range |

The stored-to pages were last set `PAGE_EXECUTE_READ` in 4 KiB steps (50 of
the 60 samples; 22,905 such calls in that range over the run). They are
Mono's JIT pages, under FEX's arm64ec self-modifying-code tracking: on thread
`0024` a page goes `PAGE_EXECUTE_READ`, a store faults, `[smc-atomic]`
handles it, the page goes `PAGE_EXECUTE_READWRITE` for one byte and back.
Before the first frame (`stamp-3`) that thread made 15,638 4 KiB
`PAGE_EXECUTE_READ` protects, each an `mprotect` of the whole 16 KiB host page
and an `NtProtect-sync` scan of 46 JIT mappings (22,631 scans), plus 14,211
`mprotect` calls of 16 MiB at `0x7c03000000` and 5,749 `Unhandled JIT SIGBUS`
lines. The runtime's own `[fault-cost]` counter: 180,311 emulated stores by
+5.3 s, 503 ms inside the handler.

## 3. What was tried

- `SMCChecks: full` in `AppConfig/hollow_knight.exe.json` (`title-runs/smc-full`):
  first frame 16.27 s, 261,851 exceptions before it. Worse, and not the source;
  the file was removed afterwards.
- `MADEIRA_WX=1` (demote a page written 32 times to RW) was not tried: the
  source records two builds that crashed with it and a stale-translation
  hazard.

## 4. What would cut it

In order of expected gain, all in FEX or the ntdll patches (a `patches/fex`
or `patches/madeira-unix` change and the full device gate):

1. Batch or skip the per-fault re-protect for Mono's code pages: the
   `PAGE_EXECUTE_READWRITE` to `PAGE_EXECUTE_READ` round trip per store, the
   16 KiB `mprotect` for a 4 KiB guest page, and the `NtProtect-sync` scan
   of every JIT mapping on each call.
2. Find what maps and protects the 16 MiB region at `0x7c03000000` 14,211
   times, which looks like a buffer re-made per invalidation.
3. More than one Mach exception handler thread, or handling the common store
   fault in the faulting thread's own signal path, so that thread `0024` does
   not queue behind the others.

## 5. Patch: a guest's own code pages without host EXEC

`patches/madeira-unix/0019` (IPA sha256
`e29509b708003c5f47f534804893c0cbef5401526e3be9da0d8a19ddfe539da0`, dev,
`pp install --no-build`). Anonymous executable guest memory keeps its pool
slot and alias, but the guest's view is mapped from the pool's RW side with no
EXEC, and a 16 KB host page is writable only while all of its committed 4 KB
pages are; a page FEX has set PAGE_EXECUTE_READ stays read-only and its stores
are emulated as before.

| run (`pp ui --play app-367520`) | path | first frame | Mach exceptions before it |
|---|---|---|---|
| `ui-runs/20260925T170815` | `MADEIRA_ANON_EXEC_POOL=1` (the old RX view), same IPA | 12.44 s | 298,544 |
| `ui-runs/20260925T170715` | 0019 | 9.86 s | 5,610 |
| `ui-runs/20260925T170935` | 0019 | 8.63 s | |
| `perf-runs/20260925T171105`, `T171931` | 0019 | 10.15 s, 9.77 s | |

Every 0019 run reached the main menu at 120 FPS (`20260925T170935`,
screenshot 40 s after the first frame) with no access violation raised to the
guest. Gameplay, on a later dev IPA with the same runtime (sha256
`495626e47c196b36f0ceb4faa7c71113173909141e98646a2b5933952257e0e7`): a new game
on profile 1, driven step by step with the scripted pad and a screenshot after
each step, reached King's Pass, and the Knight walked, jumped and slashed there
for 35 s (17,344 presents, no access violation); `perf-runs/20260925T174228`
then did the same unattended (`--vpad first-frame+25:hk-new-game.txt --vpad
first-frame+80:hk-walk.txt`, the Knight in King's Pass at first frame + 115 s).

Two earlier perf runs did not get there: a looping `hk-walk.txt` left in
`Documents/vpad.txt` played from the next launch's start, and `hk-new-game.txt`
did not expect the screen-scale and brightness calibration a new game shows.
Both drove the game's own menus and changed its settings (language, screen
scale), which were set back by hand; HUD Appearance Small, Show Achievements
Off and Backer Credits Off are what the menu shows now, and were not known
before. The app now plays only a script written after it started, and the
script takes both calibrations.

A first attempt, which also dropped the pool slot and let FEX's own write
trap take the store (`HandleRWXAccessViolation`, as on Windows), hung at
+1.4 s: FEX re-guards a page each time it compiles a block from it
(`MarkGuestExecutableRange`), so a store from code on the page it writes
faulted again before it could run, and a store FEX's iOS path performs itself
faulted inside its own handler. Keeping the alias for guarded pages avoids
both.

## 6. FEX's call/return stacks after 0019

Section 4's second item is gone with 0019. The 16 MiB region at `0x7c03000000`
is `FEXMem_CallRetStacks` (`[vname]`); before 0019 it was decommitted and
re-protected (`[vfree] … size=0x1000000`, `mprotect_exec(0x7c03000000,
0x1004000, rw-)`) 14,211 times before the first frame, once per guest exception
FEX handled. With 0019 (`perf-runs/20260925T174228`, 120 s of play after the
first frame) it was re-protected twice in the whole session, both at start.

## 7. The game start after 0019

Dev IPA with `WINE_HOST_SAMPLE` (this record's commit), `pp ui --play
app-367520` with the launch environment `WINE_HOST_LOG_STAMP=1`,
`WINE_HOST_SAMPLE=12` (`ui-runs/20260925T180403`): runtime started at 3.68 s,
game started at 3.69 s, first frame at 9.91 s, so 6.22 s of game start. A
stamped run without the sampler (`ui-runs/20260925T180013`) gave 6.13 s, so
the sampler costs about 0.1 s.

Phases (seconds since `wine_host_init`, from `ui-runs/20260925T180013`): the
process, the Unity DLLs and Mono by 0.82; the swap chain at 2.27;
`steam_api64.dll` at 2.92; from 3.6 Unity's `Loading.PreloadManager` thread
(`-00e8`) runs alone at one core until the first frame at 6.15. FEX compiled
7,224 blocks by 0.69 s, 50,000 by 3.6 s and almost none after
(`[CB_SUMMARY] real_compiles`).

The busiest thread's PC, 1 ms samples in 250 ms windows, added up to the first
frame (5.76 s sampled):

| where | s | share |
|---|---|---|
| `x64-JIT`: code FEX translated from the game (Unity, Mono, the preload) | 2.93 | 51 % |
| `libarm64ecfex.dll`: FEX compiling and dispatching | 1.13 | 20 % |
| waiting (`__ulock_wait2`, `__psynch_cvwait`, `mach_msg2_trap`): mostly the main thread waiting on the preload thread | 0.85 | 15 % |
| file metadata syscalls (`fstatat`, `openat`, `getattrlistat`, `getdirentries64`), mostly between 1.0 and 1.8 s | 0.39 | 7 % |
| `read` | 0.29 | 5 % |
| `memmove`, icache flushes, Wine's PE DLLs, its unix side | 0.18 | 3 % |

The Mach exception handler no longer appears. Nothing waits on the wineserver,
and 64 failed file opens are all there is of the lookup misses. What is left is
the game's own start running as translated code, plus FEX translating it for
the first time on every launch. The levers from here: translated-code speed
(FEX's TSO and memory-model options for this title), not translating the same
50,000 blocks on every launch (a persistent FEX code cache), and the 0.4 s of
path lookups in Wine's case-insensitive file layer.

# Hollow Knight frame hitches: CPU work on first-run code, not shader compiles

**Date:** 2026-09-25. **Tree:** the commit that adds
[dxmt 0005](../../patches/dxmt/0005-Log-shader-and-pipeline-compile-times-and-pipeline-w.patch),
the DXMT shader-cache path in `app/Sources/WineHost/wine_host.c` and
`hitches.txt` in `harness/device/perf-run.py`. **Builds:** lane builds
(`PLAYPORT_BUILD=$PLAYPORT_BUILD/lanes/perf`, `build-from-pins --from stage`
after `build-dxmt-patched.sh` and `build-dxmt-combined.sh` in the lane):
`cache1` and `cache2` ran the IPA with the shader-cache path only, sha256
`19112eb60eaf2e132408fd69b4c103b8d8ff15f4b1473f42240e52e1ca5c40df`;
`timing1` and `nocache1` ran the IPA that adds dxmt 0005, sha256
`07d00cd106a55e681da05060538a2c60f881ee3a10192def305f43eda02f54e2`.
Both were installed in place. **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0,
on a 15 W charger; every run under `flock $PLAYPORT_BUILD/device.lock`, 3 to
6 minutes apart, so not from a cold start.

**Result:** in Hollow Knight, shader and pipeline compiles cost 25 to 115 ms
across a whole launch, and a draw waited for a pipeline for less than 8 ms in
total. The visible stutter comes from elsewhere. Every frame of 25 ms or more
in play comes with a burst of guest code that runs for the first time:

- scene loads bring thousands of FEX block translations, hundreds of
  protection changes and tens of thousands of mach exceptions;
- the first nail slash brings about 0.5 s of 33 to 62 ms frames with about
  260 translations and no shader work at all.

Steady play has none of these, and no hitches. Separately, DXMT's on-disk
shader cache had never worked on iOS. It works now, but made no measurable
difference in this title.

## 1. DXMT's shader cache was off on iOS

DXMT stores converted shaders (DXBC to AIR, one entry per variant) in SQLite
under `confstr(_CS_DARWIN_USER_CACHE_DIR)`. In the app that call fails. A
launch before the fix (g720, from the 720-row record) logs it twice, once for
the reader and once for the writer (the writer's message has the reader's
name), and the container had no `Library/Caches/dxmt` ([`cache1-cache-path.txt`](2026-09-25-hk-hitch-attribution/cache1-cache-path.txt)):

```
2026-09-25 03:17:14.735 S1Probe[3523:431384] [CacheReader] Failed to resolve cache path
```

`wine_host_init` now sets `DXMT_SHADER_CACHE_PATH` to
`<container>/Library/Caches/dxmt/` (from `HOME`, before `HOME` becomes the
prefix), and DXMT takes an absolute path as is. After `cache1` the container
held `Library/Caches/dxmt/shaders_320.db` (4 KB) plus a 1,194,832-byte WAL.
After `cache2` the WAL was the same size: `cache2` found every shader in the
cache, and timing1 logs no cache errors. Metal's own pipeline cache was
already in use: the relative path DXMT asks for fails the same way (`Failed
to set Metal cache path, fallback to system default`, still logged), and the
system default `Library/Caches/<bundle id>/com.apple.metal` exists.

## 2. Runs

All four: `perf-run.py --secs 150|180 --env HOST_SCREEN=720 --vpad
45:harness/device/vpad/hk-new-game.txt --vpad 100:harness/device/vpad/hk-walk.txt`,
from the main menu through Start Game, profile 1 and the prologue into King's
Pass, then the walk, jump and slash loop. `nocache1` also had
`DXMT_SHADER_CACHE=0`, so it converted every shader again.

| run | shader cache | FPS median | share of 5 s at 120 | frames ≥25 / ≥50 / ≥100 ms |
|---|---|---|---|---|
| cache1 | empty, filled by this run | 119.9 | 0.78 | 41 / 12 / 5 |
| cache2 | warm | 119.9 | 0.86 | 33 / 12 / 4 |
| timing1 | warm | 120.0 | 0.83 | 36 / 16 / 4 |
| nocache1 | off | 120.0 | 0.83 | 38 / 12 / 4 |

The hitch counts are the same with the cache warm, cold or off. Tables are in
`*-summary.txt` and hitch lists in `*-hitches.txt`, beside this record.

## 3. Shader work is small and off the draw thread

From the `[shader-time]` and `[pso-wait]` lines
([`timing1-shader-lines.txt`](2026-09-25-hk-hitch-attribution/timing1-shader-lines.txt),
[`nocache1-shader-lines.txt`](2026-09-25-hk-hitch-attribution/nocache1-shader-lines.txt)):

| run | DXBC→AIR conversions | render PSOs | compute PSOs | libraries, functions | draws that waited |
|---|---|---|---|---|---|
| timing1 (warm) | 0 | 56, 24.6 ms, max 2.7 | 52, 0.6 ms | 67 + 142, 1.4 ms | 3, 4.2 ms total, max 2.4 |
| nocache1 (off) | 67, 88.9 ms, max 11.5 | 56, 21.9 ms, max 2.7 | 52, 0.7 ms | 67 + 142, 1.0 ms | 7, 7.7 ms total, max 2.3 |

Hollow Knight uses 67 shader variants in this route. DXMT compiles them on its
thread pool, and draws mostly find the pipeline ready.

## 4. What the hitches coincide with

`hitches.txt` gives, for each frame of 25 ms or more, what was logged from
the frame's start to its end, widened by 0.3 s: FEX block translations
(`jit`), `mprotect_exec` lines (`mprot`), mach exceptions (`mexc`), and
milliseconds of shader compiles and pipeline waits. From
[`nocache1-hitches.txt`](2026-09-25-hk-hitch-attribution/nocache1-hitches.txt),
the run that converted every shader:

```
       t      ms    jit  mprot   mexc  shc_ms wait_ms  vpad step
   14.13  175.06  10560   1681 116259    26.9     2.3                      <- main menu loads
   35.49   50.02   2108    343   6612     1.2     0.0  step 4/24 (script 2) <- prologue after profile 1
   43.70  241.75   3782   1477  17241     1.8     1.5  step 12/24 (script 2)
   87.23   62.52    262     21   1049     0.0     0.0  step 5/12 (script 3) <- first nail slash
   87.59   41.68    262      2    406     0.0     0.0  step 6/12 (script 3)
   90.57  110.37   4322    839  39167    25.6     2.4  step 10/12 (script 3)
  101.33   41.68   1396    295   3811     0.0     0.0  step 4/12 (script 3)
```

In the 5 s table's new columns, steady play shows `jit/s` 0 to 30,
`mprot/s` 1 and `exc/s` 700 to 950. The hitch windows show thousands of
translations. hk-walk's step 4 is `RIGHT X`, the first nail slash. That
slash gives 11 or 12 consecutive frames of 33 to 62 ms in all four runs. The
two runs that log shader work (timing1, nocache1) show none there.

## 5. What the protection changes are

In timing1, 22,937 of the 34,560 `mprotect_exec` lines are
`0024:err:virtual:mprotect_exec mprotect_exec(0x7c03000000, 0x1004000, rw-)`
from Unity's main thread. They are FEX's call-return stack being reset:
`ResetCallRetStack` decommits and recommits the whole 16 MB reservation
(`VirtualFree(MEM_DECOMMIT)` then `VirtualAlloc(MEM_COMMIT)`, which wine turns
into a fresh fixed anonymous mapping plus a protection change). FEX's
counter for the run
([`timing1-callret.txt`](2026-09-25-hk-hitch-attribution/timing1-callret.txt)):

```
E 24 [callret] ml610 resets=23552 bytes=376832MB per_reset=16384KB site=core by_site core=23512 cpubackend=40 jit-rollover=0
```

`site=core` is `ContextImpl::InvalidateThreadCachedCodeRange`. It resets the
stack whenever an invalidated code range held cached blocks. That happens on
self-modifying code, such as Mono's JIT writing or patching code, and on
unmapping. Upstream Linux FEX does the same reset with one `madvise`.

## 6. What this leaves for the stutter

- Shader compiles are not the cause in this title. The DXMT cache fix is
  still right for heavier titles, and dxmt 0005 will show whether they need
  it.
- The work is CPU work on code that runs for the first time. It is Mono's JIT
  compiling C# methods (itself x86 code running under FEX), FEX translating
  both the JIT's output and newly reached native code, and the invalidation
  cost around self-modifying code (call-return stack resets and mach
  exceptions). Candidates, not yet measured:
  - a cheaper `ResetCallRetStack` on iOS, zeroing only the used part rather
    than remapping 16 MB 23,000 times per run;
  - FEX's code cache for file-backed images (`CodeCache.cpp` is in the tree),
    for `UnityPlayer.dll` and `mono-2.0-bdwgc.dll`;
  - Mono AOT images: Unity's Mono already probes
    `Managed/mono/aot-cache/amd64/*.dll.dll` and finds none.

## 7. Later: the release build and the remaining waits (dxmt 0005, revised)

`[shader-time]` was a bare `fprintf(stderr)`, so the release app, which
silences diagnostics with `MADEIRA_NO_DIAGNOSTICS` and `DXMT_LOG_LEVEL=error`,
still wrote a few hundred of those lines to `playport.log` per launch. The
revised patch skips them when `MADEIRA_NO_DIAGNOSTICS` is set (`[pso-wait]`
was already below the release log level). It also times the geometry-emulation
and tessellation pipeline waits, which had kept a bare `ready_.wait`; their
lines read `[pso-wait] geometry|tessellation <ms> ms`, which `tools/perf.py`
already parses.

Dev IPA sha256 `1896a11c0f9229741e3290d6bcf8cbc4f88fee8db703e6b898fe18c1944ff2b2`,
Hollow Knight through the Play button:

| Run | Environment | First frame | `[shader-time]` lines | Screen |
| --- | --- | --- | --- | --- |
| to first-frame+25 | as shipped (dev) | +8.76 s | 245 | main menu, 120 fps |
| to first-frame+10 | game setting `MADEIRA_NO_DIAGNOSTICS=1` | +10.42 s | 0 | (not captured) |

The game's launch settings were cleared afterwards. Not checked: a title that
uses geometry or tessellation pipelines, so no `geometry`/`tessellation` wait
line has been seen yet.

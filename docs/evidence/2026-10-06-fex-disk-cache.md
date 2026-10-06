# FEX's disk cache: The Witcher 3's warm-start crash found and fixed

**Date:** 2026-10-06. **Branch:** `maxinst-500`. **Phone:** iPhone18,4, iOS 27.0, on
battery. **Title:** The Witcher 3 1.32 (classic branch, `bin/x64`), app 292030, on DXMT.
Closes the precondition of alignment item B1
([plan](../plans/2026-10-05-proton-arm64-alignment.md)): the warm-start crash
recorded in [2026-09-26-first-run-stutter.md](2026-09-26-first-run-stutter.md).

## How the cache was turned on

A dev build's game page now has a *Disk cache* picker (Default/On/Off,
`LaunchSettings.diskCache`, commit ceca136); every launch exports
`FEX_DISKCACHE`, off by default. A title's `env.FEX_DISKCACHE=1` runtime key does
nothing in this build: `madeira_cfg.h` documents `env.NAME` exports, but nothing at
the frozen Madeira pin or in the app implements them. The runs used
`pp ui --settings 'app-292030:{"diskCache":true}'`. The cache lives in the prefix at
`C:\users\playport\AppData\Local\fex-emu\DiskCache\<machine bucket>\RWCacheDB_<process bucket>.foz`.

## The crash (IPA `e2f5f4f6`, before the fix)

A cold start filled the cache (48,403 blocks stored, 73 MB). Of three warm starts,
the second exited `0xc0000005` 0.56 s after the game started, in loader init
(`Initializing dlls for witcher3.exe failed`). The faulting host code, a cached
block, was:

```
mrs  x8, tpidrro_el0 ; and x8, x8, #~7 ; ldr x8, [x8, #0x938] ; ldr x8, [x8, #0x1788]
```

the TEB read `fex-port` 0002 emits: the TEB from a pthread TSD slot, at an offset
(`IosTebTsdOffset`) baked into the block as an immediate. `0x938` is slot 295, the
TEB slot of the cold start and of warm starts 1 and 3 (`selfcheck` `teb key 295`).
Warm start 2 had TEB slot 291 (`0x918`); the cached block read slot 295, got 0, and
faulted at `0x1788`. The slot depends on the launch, and the disk cache's key did
not include it. *Inference:* the September crash (`[reclaim-census] FEX HEAP WAS
ZEROED`, rpmalloc's `page_available_to_free`) is the same wrong-slot read seen
elsewhere; it did not recur.

## The fix (`patches/fex` 0021, IPA `24117ffd`)

`DiskCache::Init` mixes `IosTebTsdOffset` into the process bucket hash, so each
offset has its own cache database. The machine bucket, which FEX prunes on mismatch,
is unchanged. Six starts, one locked session, each to `first-frame+60`:

| Run | TEB slot | First frame | Disk cache at the end |
|---|---|---|---|
| 1 | 295 | +18.51 s | hits 1,303, stored 48,500 (cold for this database) |
| 2 | 291 | +17.60 s | hits 1,301, stored 48,501 (cold for this database) |
| 3 | 291 | +16.47 s | hits 49,150, misses 1 |
| 4 | 291 | +16.26 s | hits 49,140, misses 6 |
| 5 | 295 | +16.07 s | hits 49,138, misses 7 |
| 6 | 295 | +16.19 s | hits 49,150, misses 1 |

No crash, no `HEAP WAS ZEROED`. A warm start reaches the first frame about 1.5–2 s
sooner. Each database is about 83 MB for this route (72.8 MB plus a 10.2 MB index);
the pre-fix database (`b1ccb08a…`) is left behind unused, since only the machine
bucket is pruned.

## After this record

- Decision 0056 turns it on by default, with `patches/fex` 0022 (off for WoW64),
  a 5 GB budget (cleared under 10 GB free) and Settings › Storage › Emulator cache. Was: the default stays off. Turning it on (Proton experimental and bleeding-edge set
  `FEX_DISKCACHE=1`) still needs, per B1: a Settings action that clears the cache
  (decision 0012), a size budget (about 83 MB per launch slot per game here, with
  at least two slots seen), and a decision record.
- Hollow Knight and Portal 2 were not run with the cache on this build.

## Hollow Knight: a second crash, rpmalloc at warm start (IPA `b3982ae2`)

With the cache on by default, Hollow Knight's first start filled it (hits 64,978,
misses 35,118, stored 35,072: much of its code is Mono's JIT output, which differs
between starts). **Every warm start then crashed** within 78 ms of the game
process's FEX start, before any block ran: `[rpm-avail] ml607 CORRUPT op=to_free
bad=0x100 class=0x74 page=0x7c07000000 heap=0x7c00a90000`, then a read of `0x3b0`
in rpmalloc in `xtajit64.dll` (its pool copy of the image at `0x71fd800000`), in
`load_arm64ec_module`. Counts: 1 of 2 after the first fill, then 5 of 5, then (after
clearing the cache through Settings › Storage › Emulator cache, which worked) 3 of
3 after a fresh fill, on TEB slots 291 and 295. With the cache off for the game
(its page's *Disk cache: Off*) it started normally. This is the September
signature; the TEB-slot fix (0021) is a separate, real bug.

**Outcome:** decision 0056's default is held off; the per-game setting, patches 0021
and 0022, the 5 GB budget and the Settings action stay. *Inference, to check:*
FEX reads the cache database into memory at start-up (the file mapper returns
nothing on iOS, `FEXUnixLib.cpp` `MapFile`), and Hollow Knight's database, with
Mono's anonymous code, may take a path through rpmalloc the iOS port mishandles.


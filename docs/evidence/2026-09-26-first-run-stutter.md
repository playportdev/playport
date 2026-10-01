# Hollow Knight: first-run stutter, three ideas measured

Status: measurement. The results changed two things: fex 0003 turns FEX's
SMC detection off once Mono's backpatcher is found, and fex 0004 adds the
disk cache and call-return reset counters. Neither the disk cache nor Mono
AOT is enabled.

**The question.** A first play stutters while FEX translates code the first
time it runs. Three ideas could make that cheaper:
- a cheaper `ResetCallRetStack`;
- FEX's disk cache of compiled code;
- Mono AOT images for the game's managed code.

**The runs.** Hollow Knight (app-367520) on the iPhone Air, each a single
`pp perf` run along the same scripted route: `tools/pad/hk-new-game.txt` into
King's Pass, then `hk-walk.txt` to the lumafly room. The run directories are
`$PLAYPORT_BUILD/perf-runs/hk-*`.

**The runs were not thermally controlled.** They came before `pp perf`
carried the power budgets forward and waited for pressure 0
([2026-09-26-witcher3-profile.md](2026-09-26-witcher3-profile.md) §1). Each is
one run, so the hitch counts are indicative only.

## Results

| run | change | first frame | frames ≥ 25 / 50 / 100 ms | FEX |
|---|---|---|---|---|
| hk-smckeep | none (`MADEIRA_KEEP_SMC=1`) | 9.6 s | 359 / 30 / 6 | 34,816 invalidations |
| hk-dcoff | SMC detection off (fex 0003) | 9.1 s | 342 / 17 / 6 | 31,744 invalidations |
| hk-dccold | + disk cache, empty | — | 374 / 20 / 5 | 81,887 hits, 55,358 stored |
| hk-dcwarm | + disk cache, filled | 8.5 s | 461 / 35 / 3 | 134,904 hits, 132 misses |
| hk-aot | Mono AOT images, no disk cache | 10.2 s | 392 / 33 / 3 | about 70 k compiles instead of 138 k; 13,312 invalidations |
| hk-aot-dcwarm | AOT + disk cache, filled | 8.4 s | 320 / 24 / 5 | 69,616 hits, 8 misses |

**The call-return stack reset.** fex 0004's `[callret]` line puts all resets
together at 0.63–0.72 s per run: about 23,500 resets at about 27 µs each,
2.3 ms at most. It is not worth optimising.

**SMC detection.** Once Mono's backpatcher is found, FEX's SMC detection only
repeats what the backpatcher already reports. With it off, the `av` class of
invalidations falls from 2,882 to 3, and 91 ms of handling goes with it.
Frames of 50 ms or more fell from 30 to 17 in this single pair of runs.

**The disk cache.**
- It works: a warm start takes 99.9 % of its blocks from the cache, 65 MB in
  `AppData\Local\fex-emu\DiskCache`.
- It does not reduce the hitches in play.
- A warm start crashed The Witcher 3: SEGV in rpmalloc's
  `page_available_to_free` inside `libarm64ecfex.dll`, with
  `[reclaim-census] FEX HEAP WAS ZEROED`.

It stays off.

**Mono AOT.** The images were compiled on the workstation (130 of 134
assemblies) and pushed once as an agreed one-off exception to decision 0012.
They were removed after the runs.
- AOT halves FEX's compile work and cuts invalidations from about 31,700 to
  13,300.
- The hitches do not change.

Shipping AOT images would need an in-app path, so it was not pursued.

## What remains

Every variant keeps two things:
- about 800 ms of stall at the King's Pass load;
- 60–150 ms hitches in play.

Their cause is not FEX translation alone, and is not known.
[2026-09-25-hk-hitch-attribution.md](2026-09-25-hk-hitch-attribution.md) has
the earlier attribution work.

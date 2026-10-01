# 0036: Every Play gets a 512 MiB JIT pool

**Status:** accepted, 2026-10-01. **Changes
[0019](0019-jit-pool-sized-from-the-limit.md)**: its sizing only. Running
out, and each pseudo-process's private ntdll copy, stay as 0019 has them.
The measurements are in the
[evidence record](../evidence/2026-10-01-kcd-memory.md).

## Decision

- **Size.** Every Play gets a 512 MiB pool, whatever the app's memory limit
  (PlayportKit `JitPool.sizeMB`). 0019 gave an eighth of the limit, between
  512 and 896 MiB: 896 MiB on the reference phone once Game Mode is on.
- **Unchanged.** The executable's reservation still holds 896 MiB. A dev
  build's *Simulated JIT memory* (`jitPoolSimulatedMB`) can still set any
  size up to that, larger or smaller.

## Why

**The pool is memory the game cannot have.** Blessing touches every page, so
the whole pool counts against the limit (8 GB with Game Mode). Kingdom Come:
Deliverance fills the rest:

- The game's heap is 4.5 GB and its textures 1.2 to 1.9 GB. That is at its
  lowest settings, and it ignores the video memory budget and the RAM it is
  told it has.
- With an 896 MiB pool its footprint reached 8,038 to 8,156 MB loading
  Rattay, and one play was killed there.
- With 512 MiB it reached 7,787 MB and walked on.

**No game measured needs more.** High-water marks with the larger pool:

| game | head | tail |
|---|---|---|
| Hollow Knight | 187 MiB | 145 MiB |
| The Witcher 3 | 206 MiB | 145 MiB |
| Kingdom Come: Deliverance | 182 MiB | 161 MiB |

The tail is what FEX was granted, not what it needs: FEX takes a 128 MiB
code buffer whenever the room allows one. 0019 found that Hollow Knight at
512 MiB still got that buffer. Kingdom Come played at 512 MiB with 170 MiB
of room left.

## Cost

- **A game that needs more head or tail** ends with "ran out of JIT memory"
  instead of running. 0019's larger pool gave up to 384 MiB more room. A
  launcher with many children (0019: about 20 MiB each) or Steam's CEF
  (700 MiB of head in Madeira's runs) would run out sooner. No installed
  game does either.
- **The cohort's `memoryMB` figures** in `titles.json` were measured with an
  896 MiB pool, so each overstates its game's need by about 384 MB. The
  error is on the safe side: a Play is refused or warned about sooner than
  needed.
- **Revisit** if a game runs out of the pool where a larger pool would fit
  under the limit. The answer then may be a per-game size.

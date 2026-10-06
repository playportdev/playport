# The runtime's smaller known limits (runtime risks, item 8)

**Date:** 2026-09-28. **Phone:** iPhone18,4, iOS 27.0, TXM present, on a
charger for most of the runs (battery 26 % to 38 %). Branch `fm/pp-rr-small`
on main `6a53077`. One dev IPA, installed with `pp install --no-build` at the start of each
device-lock session:

| IPA | sha256 | What it has |
| --- | --- | --- |
| `Playport-26.5-4c4b654c.ipa` | `4c4b654c1cf742b9bec11fe279bca9579e063a37b5b63b9fda51ce25efe47d72` | madeira-unix 0035 (the counts) and 0036 (W+X fails), the `limits:` lines |

Item 8 of the [runtime-risks plan](../plans/finished.md#runtime-risks) names
four limits. For each one, the question was whether any title reaches it. None
does, so each now fails loudly or is counted, as the plan allows, rather than
handled in full ([ARCHITECTURE.md, "Known runtime
limits"](../ARCHITECTURE.md#known-runtime-limits)).

## The logs before this branch

These are the phone logs kept in the build areas on the workstation: 281
distinct `s1-host.log` files from 2026-09-25 to 2026-09-28, grouped by the
executable each one ran. Every line counted here is written to stderr
unconditionally, so every one of these logs had the reports enabled.

| Title | Logs | `ml999` (W+X lost WRITE) | `[x18-tramp] REFUSED` | out of trampoline space | x18 `skipped` (sum) | `UNALIGNED-EXCL` | alias table FULL | alias slots, most |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Hollow Knight | 217 | 0 | 0 | 0 | 914 | 0 | 0 | 61 |
| The Witcher 3 | 59 | 0 | 0 | 0 | 116 | 0 | 0 | 1 |
| En Garde! | 5 | 0 | 0 | 0 | 14 | 0 | 0 | 0 |

- **x18 `skipped` is not a miss.** In every log, the only images with
  `skipped` above 0 are ntdll (`.text` 0x7ca65) and winhttp (0x23d75), with 2
  each. A scan of this build's arm64ec `ntdll.dll` and `winhttp.dll` finds 2
  `mov xzr, x18` (`0xaa1203ff`) in each `.text`. The patcher replaces that
  no-op with a NOP and counts it as skipped. The ntdll scan finds 790 x18
  sites, and the patcher reports 788 patched plus these 2. So no x18
  instruction was left to fault in any of these logs. 0035 adds an
  `unpatched` field to the `[x18-patch]` line that leaves the NOPs out.
- **Out of B/BL reach.** An image's trampolines are on the page after its
  copy in the pool (madeira-unix 0030), so they can be out of reach only for a
  `.text` larger than 124 MiB (`0x7C00000`, the patcher's guard). The largest
  x18-patched `.text` in the runs below is 0x217d36 bytes (2.1 MiB) in Hollow
  Knight and 0x48fdf6 (4.6 MiB) in The Witcher 3. En Garde!'s
  124 MB executable is x86-64, which the patcher does not touch. So no
  trampoline islands inside images were built.
- **The alias table.** The most any title used is 61 of its 4096 slots
  (Hollow Knight in King's Pass, as in the
  [jit-pool record](2026-09-28-jit-pool.md)), and running out already ends a
  launch as its own outcome (`pool=exhausted:alias`). So the table is neither
  grown nor made a map.
- **W+X.** On this phone `mprotect` never grants EXEC. 272 of the 281 logs
  have the fallthrough report (`EXEC not actually granted … falling through
  to JIT-pool path`). The other 9 have no `err:` lines at all: launches
  refused before the runtime started, or runs with the runtime's `ERR` lines
  off. None of the 281 has `ml999`. So the fast path that could drop
  WRITE is not reached, and W+X goes to the JIT-pool path, which serves it
  through the pool's RW and RX aliases. 0036 makes the fast path fail such a
  request with `EACCES` instead of reporting success.
- **Split locks.** No log has the misaligned-exclusive emulation
  (`UNALIGNED-EXCL`, ml431). `UNALIGNED-BACKPATCH` (8,422 lines in Hollow
  Knight's logs, 3,227 in The Witcher 3's) is a different path: it rewrites a
  misaligned `LDAR`/`STLR` in FEX's translated code into a plain access and a
  barrier. That is not a read-modify-write. The x86 guest's own split locks
  are FEX's (two CAS loops that can tear; `StrictInProcessSplitLocks` off),
  and FEX does not count them where the runtime can read them. That limit is
  recorded in ARCHITECTURE.md and not counted.

## On the phone with the counts

Every run ended with `limits: wx_dropped=0 x18_images=0 x18_sites=0
split_lock=0` in its result event. Each run's `limits:` and `pool:` lines are
in [timelines.txt](2026-09-28-runtime-limits/timelines.txt).

| Run | Result | `limits` | Pool (head, tail, alias) |
| --- | --- | --- | --- |
| `pp ui --play app-367520 --until first-frame+10 --shot` (Hollow Knight) | ok, first frame at +10.31 s | all 0 | 164 MiB, 145 MiB, 34 |
| `pp ui --play app-292030 --until first-frame+10 --shot` (The Witcher 3) | ok, first frame at +19.10 s | all 0 | 206 MiB, 145 MiB, 1 |
| `pp ui --play app-1654660 --until first-frame+10 --wait 120` (En Garde!) | the app exited before the stop condition | no line (see below) | none |
| `pp perf --secs 150 --pad first-frame+25:hk-new-game` (Hollow Knight, new game into King's Pass) | ok, first frame at +10.68 s, 102.1 fps mean, p10 82.3 | all 0 | 187 MiB, 145 MiB, 61 |
| `pp perf --title app-292030 --secs 150 --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk` (The Witcher 3, the Kaer Morhen save, walking) | ok, first frame at +18.94 s, 29.8 fps mean, p10 16.9 | all 0 | 206 MiB, 145 MiB, 1 |

- The raw logs of these five runs agree: no `ml999`, no `[x18-tramp]`, no
  `UNALIGNED-EXCL` and no alias table FULL, and every `[x18-patch]` line has
  `unpatched=0`.
- **En Garde!** stopped at the fault its
  [plan](../plans/finished.md#en-garde) records as open. It is a null read
  in ARM64EC code (`AV READ of 0` at guest `0x71fe809574`), re-delivered 2000
  times until the runtime ends the process (`[redeliv] terminating process`).
  The app ended before any `limits:` or `pool:` line reached its log. The
  log has no `ml999`, `[x18-tramp]` or `UNALIGNED-EXCL`, and its
  `[x18-patch]` lines all have `unpatched=0`.
- The frame rates are for the record only. The phone was on a charger for
  the Hollow Knight run, and the [jit-pool](2026-09-28-jit-pool.md) runs were
  not, so the two do not compare. Nothing in this branch runs on a frame's
  path: the counts are incremented only where a limit is reached, and read
  every 2 s.

## Not run

- **A W+X request on the fast path**, and a refused or partly patched x18
  image. None can be caused from the UI on this phone. The counts' plumbing
  from the runtime to the result event is exercised with zeros only. The Swift
  and Python sides have unit tests.
- **The release build** on the phone (it builds from the same trees; the
  `limits:` lines go to its `playport.log`).

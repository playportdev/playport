# 0163: The Witcher 3 keeps FEX's PAUSE (YIELD): WFE's frame rate came with five times the long frames

**Status:** accepted, 2026-10-28, with the owner, who asked for hitches to count, not only frame rate
(PLA-455). Supersedes [0162](0162-the-witcher-3-pause-as-wfe.md); `app-292030`'s row of
[0074](0074-per-title-compatibility-defaults.md)'s table is back to `short-reserve-mb=6144`.

## Context

- **What 0162 measured.** 0162 made `env.MADEIRA_FEX_PAUSE=wfe` (`patches/fex` 0083) The Witcher 3's default
  on its mean frame rate: +8.7 % on a rested phone.
- **What it did not look at.** The frame-interval tail. `hitches.txt` of the same runs, +60 to +150 s,
  shows it ([evidence](../evidence/2026-10-28-witcher3-perf.md#6-hitches-wfe-trades-them-for-frame-rate)):

  | Condition | Frames > 150 ms per 90 s, YIELD | Frames > 150 ms per 90 s, WFE | p99, YIELD | p99, WFE |
  | --- | --- | --- | --- | --- |
  | Rested, battery, 1302x600 (6 against 7 runs) | 1–6 | 6–16 | — | — |
  | Hot, back to back, 1564x720 (3 against 3) | 3–4 | 18–26 | 108–117 ms | 158–175 ms |
  | Hot, back to back, 1302x600 (2 against 2) | 4–8 | 23–27 | 100–117 ms | 150–183 ms |

- **What the mean showed hot.** The mean gain shrinks to +4 % (1564x720) and +9 % (1302x600). The worst
  frames under WFE reach 400–600 ms.
- **A likely cause, not yet confirmed.** A thread waiting in WFE counts as running: RenderDispatcher1/2 go
  from 25 % to 78 % CPU. With the P cores parked, only four E cores are left, so the main thread probably waits
  for one. A thread-placement trace (PLA-457) would confirm it.

## Decision

- **The Witcher 3's default.** It keeps FEX's PAUSE, which compiles to YIELD: its compatibility default
  runtime is `short-reserve-mb=6144` again.
- **0083 stays.** `env.MADEIRA_FEX_PAUSE=wfe` in a person's Runtime keys still selects WFE, for a person who
  prefers the higher mean.
- **Measuring a runtime default.** A runtime default is judged on the frame-interval tail as well as the
  mean:
  - frames over 100 ms and over 150 ms per window, and the p99, from `hitches.txt`;
  - measured on a hot phone, back to back with the arms alternating, as well as on a rested one.

## Costs

- **Mean frame rate.** The Witcher 3 gives up the 4–9 % mean that WFE gave.
- **The tail is still poor.** The YIELD tail on a hot phone is still 34–149 frames over 100 ms per 90 s.
  That is a separate problem (PLA-457).

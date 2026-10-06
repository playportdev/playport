# Hollow Knight gameplay baseline, first pass: five modes, one run each

**Status:** partial. Each of the plan's five modes ran once
([performance follow-up](../plans/finished.md#performance-follow-up-after-the-runtime-audit), step
1). None is repeated yet. **Date:** 2026-09-29. **Builds:** dev. 720 and native
free-running ran on
`a2f29a31dea07aca4f101855b1c769ecaaa5333ff11777b22a8bde7ceb19a5cc` (tree
`e700809`, no runtime change since the audited `63beae7`). 720/60, 900/60 and
900 free-running ran on
`4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d`: the PE set
without DWARF, and the counters flag, which a dev build leaves on. The two
builds do the same work, but they differ in the pool's size and are not the
same build. **Phone:** iPhone Air (`iPhone18,4`, A19 Pro, 2 P + 4 E cores),
iOS 27.0, Wi-Fi, on battery. Run directories:
`$PLAYPORT_BUILD/perf-baseline/{r720-1,native-1,r720c60-b,r900c60-b,r900-b}`
(not committed). A notification banner appeared over the game in one
screenshot; the phone had no Focus mode on.

## Route

Profile slot 1's game in progress changes whenever a run dies or rests in it,
since the game saves then: the first native run of the day
(`old-slot1-native-1`, not used) loaded it at the Dirtmouth bench. Both runs
here start a new game instead, which the game does not save until the Knight
dies or rests. The script they ran (`hk-slot2`, since replaced) pressed A,
DOWN, A. The profile screen opens on the last slot used, though, and wraps
through Back, which the screenshot at first frame + 28 s (before the DOWN) did
not show. So `r720-1` started its game in slot 3 and `native-1` in slot 4, as
planned: a new game, on time. In the three `-b` runs DOWN from slot 4 took
Back. The prologue's A presses then went through the main menu again and began
the game in slot 4 about 3 s later. All five reached King's Pass's lumafly room
by first frame + 150 s, at full health or close. `tools/pad/hk-new-slot.txt`
now presses only A, on whichever slot the cursor opens. Then `hk-walk` and `hk-roam` loop in King's Pass's lumafly
room until the app is killed at first frame + 720 s:

```
pp perf --secs 720 --cool 15 --settings '{"screen":"720"|"native","frameLimit":0}' \
    --pad first-frame+25:hk-slot2 --pad first-frame+75:hk-walk --pad first-frame+106:hk-roam \
    --shot first-frame+28 --shot first-frame+150 --shot first-frame+700
```

The phases below use the table's `t`, which is within about 1 s of the first
frame: prologue (25–75 s), the walk (75–106 s), and the roam loop early
(106–300 s) and late (300–720 s). Frame times are the Metal HUD's per-frame
intervals. The CPU, power and GPU columns are the means of the 5 s rows.

## Results

| mode | phase | FPS | p50 / p99 / p99.9 ms | ≥25 / ≥50 / ≥100 ms | GPU ms | P% | E% | P GHz | CPU mW | phone mW |
|---|---|---|---|---|---|---|---|---|---|---|
| 1564×720 | walk | 119.6 | 8.3 / 8.3 / 20.8 | 2 / 0 / 0 | 6.0 | 105 | 37 | 3.56 | 1419 | 5969 |
| 1564×720 | roam 106–300 | 103.2 | 8.3 / 33.4 / 66.7 | 495 / 48 / 13 | 5.9 | 84 | 146 | 1.59 | 607 | 4642 |
| 1564×720 | roam 300–720 | 104.4 | 8.3 / 29.2 / 58.4 | 922 / 103 / 16 | 5.8 | 80 | 172 | 1.31 | 510 | 3999 |
| 2736×1260 | walk | 117.9 | 8.3 / 16.7 / 20.8 | 1 / 0 / 0 | 8.0 | 99 | 51 | 3.10 | 1205 | 7948 |
| 2736×1260 | roam 106–300 | 73.8 | 12.5 / 37.5 / 54.2 | 774 / 33 / 4 | 10.0 | 0.4 | 247 | – | 232 | 4557 |
| 2736×1260 | roam 300–720 | 75.6 | 12.5 / 29.2 / 45.9 | 1626 / 21 / 3 | 10.5 | 0.4 | 241 | – | 244 | 4205 |
| 1564×720, 60 cap | roam 106–300 | 60.0 | 16.7 / 29.2 / 29.2 | 523 / 0 / 0 | 7.6 | 91 | 26 | 2.81 | 576 | 2883 |
| 1564×720, 60 cap | roam 300–720 | 60.0 | 16.7 / 29.2 / 29.2 | 1182 / 3 / 0 | 8.2 | 92 | 27 | 2.89 | 587 | 2789 |
| 1956×900, 60 cap | roam 106–300 | 60.0 | 16.7 / 29.2 / 29.2 | 580 / 0 / 0 | 12.5 | 94 | 29 | 3.13 | 652 | 3761 |
| 1956×900, 60 cap | roam 300–720 | 60.0 | 16.7 / 29.2 / 29.2 | 1253 / 0 / 0 | 12.4 | 96 | 29 | 3.12 | 642 | 3443 |
| 1956×900 | roam 106–300 | 115.2 | 8.3 / 20.8 / 25.0 | 41 / 3 / 1 | 6.2 | 114 | 132 | 1.73 | 777 | 4958 |
| 1956×900 | roam 300–720 | 100.1 | 8.3 / 25.0 / 41.7 | 490 / 21 / 2 | 6.2 | 60 | 193 | 1.31 | 468 | 4057 |

A 60 FPS cap on the 120 Hz panel shows one late frame as 25 or 29 ms
(an extra 8.3 ms refresh), so the capped modes' ≥25 ms counts are single
missed refreshes. None of them reached 50 ms more than three times in 10
minutes. The GPU's time per frame rises under the cap (8 and 12 ms against 6)
because it then runs at a lower clock, as its busy share shows (55–83 %).

| | 720 | native | 720/60 | 900/60 | 900 |
|---|---|---|---|---|---|
| battery | 65 → 58 % | 56 → 47 % | 56 → 51 % | 50 → 43 % | 41 → 33 % |
| first thermal pressure; first CPMS budget | 45 s; 71 s | 85 s; 90 s | none | 540 s (level 10); 720 s | 120 s; 133 s |
| lowest CPMS budget | 404 mW | 404 mW | none logged | 2874 mW | 660 mW |
| JIT pool head at the end | 226 MiB | 225 MiB | 141 MiB | 142 MiB | 141 MiB |

`r720c60-b` did not rest like the others: two short checking plays through
`pp ui` came just before it, and `pp perf --cool` counts only its own runs, so
it started at once. It still logged no pressure at all. `r900-b` started at
41 % battery.

Both runs started at nominal thermal state after a 15-minute rest, but that
rest followed runs on the phone the same evening. They are not a cold start
and do not compare with a rest of an hour.

## What it shows (one run each)

- **At native resolution the scheduler takes the game off the P cores.** From
  about 80 s on, the native run's P-cluster share is 0.4 % and every thread
  runs on the E cores. The GPU is 83–86 % busy at 10 ms a frame, and the game
  holds 74–76 FPS. That is what the 2026-09-25 720-row record found.
- **At 720 rows the game keeps the P cores, clamped to 1.31 GHz by 300 s.**
  It holds about 104 FPS for the rest of the run. The CPMS budget falls to
  404 mW in both runs. Neither holds 120 FPS past the walk.
- **The whole phone draws about the same in both** late in the run (4.0 W at
  720, 4.2 W native). The 720-row mode buys about 38 % more frames for the same
  power, not less power.
- **720 rows has the worse long tail.** It has 103 frames of 50 ms or more and 16
  of 100 ms or more in the late roam, against 21 and 3 native, though it has fewer
  frames of 25 ms or more. Its p99.9 is 58 ms against 46 ms native. These runs
  do not show whether that comes from P-core clamping, main-thread saturation at
  1.31 GHz or something else.
- **Neither free-running mode sustains 120 FPS.** 900 rows holds 115 FPS for the
  first five minutes and falls to 100 once the P cores are clamped. That is
  about 720's figure, on a different build and at lower charge, so the two do
  not rank.
- **Both 60 FPS caps hold 60 for the whole ten minutes**, on the P cores at
  2.8–3.1 GHz, with no frame over 50 ms after the walk. 720/60 draws 2.8 W for
  the whole phone and raised no thermal pressure at all. 900/60 draws 3.4–3.8 W,
  reached pressure level 10 at 540 s and a first budget at 720 s. That is
  about 1.2–1.4 W less than any free-running mode, with far better tails.
- These are the plan's candidates for a sustained mode. The plan needs image
  quality, a repeat and a longer run before either becomes a default.

## Not established

- Repeatability: a second pass of every mode. The differences in tail counts
  above are within what one run of a looping pad script can show.
- Whether 900/60 stays above its first budget past ten minutes.
- Image quality at 720 or 900 rows was not assessed.
- No title default changes on the strength of this.

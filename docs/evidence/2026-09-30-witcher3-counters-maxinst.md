# The Witcher 3: runtime counters off and FEX block size 500, a quick check

**Status:** one run of each, against a base run before and after. No
difference found. **Date:** 2026-09-30. Plan:
[performance follow-up](../plans/finished.md#performance-follow-up-after-the-runtime-audit), steps 2
and 3, the second title the plan asks for. Hollow Knight's A/B/B/A blocks are in
[the counters record](2026-09-29-release-counters.md) and
[the block-size record](2026-09-30-hk-maxinst.md). **IPA:** dev,
`4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d`.
**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, on battery (72 → 57 %).

## Runs

In the order base, counters off, block 500, base, each after a 15-minute rest:

```
pp perf --title app-292030 --secs 150 --cool 15 [--no-counters] \
    --settings '{"screen":"720","frameLimit":0[,"maxInst":500]}' \
    --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk
```

Continue loads the Kaer Morhen save ("Use your Witcher Senses to find the key
to the bedroom door"), and Geralt walks the room from 50 s. The screenshots
at first frame + 45 s are the same frame in all four runs. By 145 s each Geralt
is at a different place in the same room. The game's own frame limit was 30
FPS (its Options, as a person left it). At 720 rows the GPU needs 32–34 ms a
frame, so the cap costs at most a frame or so, and it keeps every run at the
same throughput. Each launch logged the switch it ran with. Directories:
`$PLAYPORT_BUILD/perf-w3/`.

| run | window | FPS | p99 / p99.9 ms | ≥50 / ≥100 ms | Mi instructions/frame | CPU % | P GHz | CPU mW | phone mW | GPU ms (busy) | FEX compiles |
|---|---|---|---|---|---|---|---|---|---|---|---|
| base 1 | load 20–60 s | 28.7 | 50.0 / 279 | 12 / 3 | 554 | 292 | 2.55 | 2574 | 7470 | 10.2 (39 %) | 68,696 |
| | walk 60–150 s | 29.9 | 45.9 / 58.4 | 11 / 1 | 501 | 361 | 2.04 | 1538 | 4819 | 32.3 (91 %) | |
| counters off | load | 28.9 | 45.9 / 217 | 6 / 2 | 621 | 288 | 2.79 | 2976 | 7358 | 13.3 (45 %) | 68,691 |
| | walk | 30.0 | 45.9 / 54.2 | 7 / 0 | 508 | 356 | 2.07 | 1606 | 4664 | 33.8 (95 %) | |
| block 500 | load | 28.9 | 45.9 / 221 | 6 / 2 | 628 | 290 | 2.78 | 2972 | 6338 | 13.9 (47 %) | 70,255 |
| | walk | 30.0 | 45.9 / 62.5 | 16 / 1 | 506 | 360 | 2.08 | 1570 | 4662 | 34.0 (95 %) | |
| base 2 | load | 28.9 | 45.9 / 213 | 10 / 2 | 634 | 287 | 2.79 | 2976 | 7023 | 13.5 (46 %) | 69,060 |
| | walk | 30.0 | 45.9 / 66.7 | 9 / 1 | 505 | 358 | 2.06 | 1592 | 4604 | 33.9 (95 %) | |

## Result

- **The first base run is the odd one out, not either change.** It alone met a
  power budget (2199, then 1688 mW) during the load, with the P cores at 2.55
  GHz against 2.79. Its load figures are lower for that reason. It started 13.5
  minutes after the Hollow Knight block's last run, where the others rested 15
  minutes after one of these.
- **Walking, all four agree:** 501–508 Mi instructions a frame, CPU 356–361 %
  with both P cores full, 1.54–1.61 W for the CPU, and the GPU 91–95 % busy.
  Base 2 differs from counters off by 0.5 % in work and 1 % in CPU power, and
  from block 500 by 0.1 % and 1.4 %. That is within what the two base runs
  differ by between themselves.
- **Block 500 compiles 2 % more blocks** (70,255 against 68,696 and 69,060)
  with the same work per frame and no change in the load's tail. The 16 frames
  of 50 ms or more while walking (against 9–11) are within the spread of a
  150 s walk in a room that streams in.
- **So The Witcher 3 agrees with Hollow Knight.** Turning off the counters and
  halving FEX's block ceiling change nothing these runs resolve, now in a game
  that keeps both P cores busy. FEX's 5000 stays. The counters stay off in the
  release app, since that costs nothing, but they are not a performance
  change.

One run each is a quick check, not the plan's repeated A/B.

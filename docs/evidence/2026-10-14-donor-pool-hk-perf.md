# Donor pool: Hollow Knight frame rate with the pool off and on

**Date:** 2026-10-14. **Branch:** `research/extended-memory`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216); the title is PLA-42.
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md), queue item "HK `pp perf` A/B".

**Setup:**

- iPhone18,4, iOS 27.0.1, on battery.
- IPA `Playport-26.5-b3cdca61.ipa`, SHA256
  `b3cdca61de83582b96504df22c6d381592f3451e285fce11142e6a498f6025de` (commit
  `7413ff3`, madeira-unix 0150).
- Hollow Knight (app-367520), with the title's saved settings.
- The owner played with a controller, 300 s from the first frame.

**Runs:**

- Off: `./pp perf --secs 300`, after `pp ui --action set:donorPoolMB=0`.
- On: the same, after `set:donorPoolMB=4096`.
- Each was its own `pp phone lock` session; the owner took a break between them.
- Scripts: `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/hk-perf-ab.sh` (the
  off half; its on half was stopped while cooling) and `hk-perf-on.sh`.
- Run directories: `$PLAYPORT_BUILD/perf-runs/hk-pool-ab-20261014/off` and `on`.

## Result

| | Off | Pool 4096 (3072 granted, cap) |
| --- | ---: | ---: |
| First frame | +10.82 s | +10.51 s |
| Mean FPS (p10, median, min) | 59.1 (59.5, 60.0, 41.7) | 57.5 (53.6, 60.0, 25.0) |
| Frame time / GPU time (ms) | 16.82 / 9.21 | 17.22 / 8.63 |
| Hitches >25 / >50 / >100 ms | 472 / 17 / 9 | 808 / 32 / 9 |
| Wineserver requests per frame | 26.6 | 27.6 |
| Thermal | nominal | nominal |
| Battery | 96 → 96 % | 85 → 82 % |

Frames per second, per 30 s window from the first frame:

| t (s) | 0 | 30 | 60 | 90 | 120 | 150 | 180 | 210 | 240 | 270 | 300 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Off | 53.3 | 60.0 | 60.0 | 60.0 | 60.0 | 58.4 | 60.0 | 60.0 | 59.9 | 60.0 | 59.6 |
| On | 53.3 | **44.3** | 59.8 | 59.8 | 60.0 | 59.2 | 58.6 | 59.9 | 59.7 | 59.9 | 59.8 |

**The whole difference is the 30–60 s window.** Outside it, the two runs
match to within about 1 FPS.

In that window the pool run differs as follows (`pp perf --compare --window 30:60`):

| | Off | On |
| --- | ---: | ---: |
| Hitches over 25 ms | 28 | 343 |
| Wineserver requests per frame | 26 | 51 |
| P-cluster clock | 2.77 GHz | 3.12 GHz |
| System power | 3.3 W | 5.0 W |
| GPU busy | 67 % | 37 % |

The pool's own work in that window:

- Its counters went from 736 to 5,100 MiB served: about 4.4 GiB of guest
  commits churned through it, and was released and zeroed again.
- The pool's work over the whole run was small: 308 ms zeroing and about 325 ms
  backing, with no call over 1 ms.

That much work is far less than the frame time lost in the window, which was
about 30 s × 25 %. So most of the dip is probably what the game was doing (a
load or area change, with twice the server requests), not the pool's cost.

But the off run did not churn like this, and one pair cannot separate the
causes. The game did something different there (more requests, more CPU, less
GPU), and in the pool run that work also went through the pool's hooks. This
may be a 4 GiB burst of allocation the pool made slower, or play that differed.

**Pool counters at +300 s:**

| Counter | Value |
| --- | ---: |
| Served | 2,481 calls, 5,194 MiB |
| Live | 742 MiB |
| Resident | 584 MiB |
| Compressed | 79 MiB |
| Refused | 0 |
| Unmatched | 0 |
| Map failures | 0 |
| Detaches | 0 |
| Resets | 2 |

## What this shows and does not

- **Steady play is unaffected.** The pool costs Hollow Knight nothing
  measurable at 60 FPS, and the first frame is the same.
- **A heavy allocation burst coincided with a 15 FPS drop for about 30 s in
  the pool run only.** The owner recalls, not with certainty, that the runs
  started differently:
  - the off run started with the hero already standing;
  - the pool run began with cutscenes and the hero falling to the ground.

  That fits a scene load in the pool run only: the 4.4 GiB churn and the
  doubled server requests. So the dip is most likely the game's content, not
  the pool. To confirm it, repeat with the same scripted route (a `pp pad`
  route) from the same save point in both runs.
- **The runs are not fully comparable:** one pair, played by hand, a break
  between them, and different battery levels.

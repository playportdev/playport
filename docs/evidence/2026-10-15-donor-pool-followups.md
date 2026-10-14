# Donor pool follow-ups: scripted Hollow Knight A/B; detach probe not run

**Date:** 2026-10-15 (00:09–01:03). **Branch:** `research/extended-memory`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216); the title is PLA-42.
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md), the HK A/B and the detach probe
left open by [the measure runs](2026-10-14-donor-pool-measure.md).

**Setup:**

- iPhone18,4, iOS 27.0.1, on the charger (65 % at the start, 96 % at the end), unattended mode on.
- Dev IPA SHA256 `21347e47434d8483d37353d352f0b6795ad66a0894ef5e1c328376b2ac4a3c7d`
  (commit `9e900b8`). No rebuild: the changes here are pad routes and a host test.
- Hollow Knight (app-367520), with the title's saved settings.
- The owner approved a new game in the empty profile slot 3, quit without saving.

## Hollow Knight A/B

### How the runs were driven

- Each run used `pp perf --no-hud --secs 300 --cool 15 --cool-max 25`, after
  `pp ui --action set:donorPoolMB=0` or `=4096`.
- The session scripts are in `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`:
  `followups-hk-ab.sh` and `followups-hk-retry.sh`, with their `.log` files.
- **Routes:** only committed routes and `pp pad wait-text` gates were used.
- **The gate before any press on a slot:**
  1. The main menu is read.
  2. `hk-profiles` presses Start Game. A "Quit Game?" dialog, if read, is closed by
     `hk-menu-back-start`; none appeared tonight.
  3. The profile screen must read "Select Profile".
  4. Slot 3 must read "New Game" (crop `0.26,0.56,0.37,0.64`).
  5. Slot 3's right fleur, which marks the cursor, must be read as `>` or `»`
     (crop `0.60,0.53,0.70,0.67`). On the host, the 2026-10-14 screenshot read `>` there.
     The same screenshot with the fleur painted out read nothing.
  6. Only then does the new route `hk-slot-new-game` press A, at first frame + 60 s.
     It is `hk-new-slot` without its Start Game press.
- **After the gate:** `hk-walk` at +106 s, `hk-roam` at +137 s, and `pp perf` kills the app
  at +300 s. Nothing pressed START, Save or Quit; the kill is the quit without saving.
- **Phases** (t from the first frame): menu 0–60, prologue and King's Pass load 60–106,
  walk 106–137, roam 137–300.

### The missed press, and the retry

The first pool-on run (`hk-4096`) did not reach the profile screen:

- The main menu was read with Start Game highlighted.
- `hk-profiles`' 150 ms A was played: `vpad: step 1/2` at 00:35:26.207, and the host wrote
  `buttons=0x1000`, then `0x0000` at 26.357.
- The game stayed on its main menu. No dialog and no profile screen were read, so the gate
  failed: the app was killed with nothing else pressed.
- **The stall at the press:** the 16-frame group over the press took 365 ms; a group at
  60 FPS takes 267 ms. That means a stall of about 100 ms.
  - Wine's `mprotect_exec` lines and `[span-census] ALLOC` lines (16 MiB) cluster at that
    moment.
  - The pool-off run had the same kind of burst at its press: as many `mprotect_exec`
    lines around it, or more. Its group over the press took 294 ms, and the press worked.
  - So the burst is the game's own, not the pool's. Whether the stall was longer because of
    the pool, and why the game missed a 150 ms press across a 100 ms stall, is not
    established. One sample.
- **The retry:** the supervisor approved one retry of the pool-on run with a fix of my own.
  The new route `hk-profiles-hold` holds A for 400 ms. With it, the run (`hk-4096b`) passed
  the full gate.

### Results

| | Off (`hk-0`) | Pool 4096 (`hk-4096b`) |
| --- | ---: | ---: |
| Pool | – | 4096 granted (fixed 4096), one donor |
| `--cool` wait before the launch | about 4 min | about 13 min |
| Thermal | nominal | nominal |
| First frame | +10.65 s | +12.54 s |
| Mean FPS, 0–300 s, `pp perf` | 57.5 | 57.8 |
| Mean FPS, 0–300 s, `[frames]` lines | 57.5 | 56.5 |
| Median FPS | 59.9 | 59.9 |
| 1 % low FPS, 0–300 s | 21.8 | 20.9 |
| Longest 16-frame group | 1.86 s (t 12.5) | 4.05 s (t 12.3) |
| Groups over 0.4 s | 33 | 37 |
| Peak `fpMB` | 3,561 | 3,006 |
| Server requests per frame | 24.9 | 26.6 |
| `c0000005` / "preserved" lines | 14 / 12 | 14 / 12 |

**How the figures were computed:**

- The `[frames]` figures come from the game layer's lines, one per 16 frames, with t = 0
  at the first `[frames]` line.
- The 1 % low is the mean of the slowest 1 % of the 16-frame groups' rates.
- `pp perf`'s own 5 s buckets do not show a 16-frame group that spans several seconds, so
  its mean misses the 4.05 s stall.
- The `c0000005` and "preserved" lines are Unity's known unaligned-byte accesses, handled
  through the alias emulator. They appear the same in both runs.

**By phase:**

| Phase (t, s) | Off: mean / median / 1 % low FPS | On: mean / median / 1 % low FPS | Server requests per frame, off / on | Peak `fpMB`, off / on |
| --- | --- | --- | ---: | ---: |
| Menu, 0–60 | 58.3 / 59.9 / 30.3 | 55.9 / 59.9 / 21.2 | 32.3 / 37.5 | 2,829 / 2,370 |
| Prologue and load, 60–106 | 45.7 / 59.9 / 9.5 | 43.4 / 59.9 / 5.0 | 37.6 / 41.3 | 3,561 / 3,006 |
| Walk, 106–137 | 59.9 / 59.9 / 55.9 | 59.2 / 59.9 / 38.2 | 21.5 / 21.5 | 3,467 / 2,807 |
| Roam, 137–300 | 60.0 / 59.9 / 59.1 | 59.9 / 59.9 / 52.8 | 18.9 / 18.9 | 3,508 / 2,826 |

**The two scene loads:**

| Load | Off | On |
| --- | ---: | ---: |
| Menu load (t ≈ 12 s) | 1.86 s | 4.05 s |
| King's Pass load (t ≈ 92 s) | 1.68 s | 3.19 s |

- The failed pool-on run (`hk-4096`) took 1.86 s for the menu load, the same as the off run.
  So the 4.05 s is not repeatable on every pool run.

**Power:** CPU power matched (550 vs 565 mW over the run). The phone's system power did not:
3.0 W off vs 4.1 W on, mostly in the first 106 s. Both runs were charging, at 70 % and 93 %,
so this is not taken as a pool cost.

**The pool** (`donor-pool: stats`; install is at runtime start, about 8 s before the first
frame):

| At | Served | Served MiB | Live | Resident | Compressed | Released MiB | Reuses | Zeroed MiB | Zero ms | Back ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| install + 60 s | 1,236 | 638 | 528 | 437 | 2 | 110 | 231 | 92 | 4 | 13 |
| install + 120 s | 2,447 | 6,081 | 683 | 520 | 76 | 5,398 | 1,392 | 5,379 | 357 | 382 |
| install + 300 s | 2,485 | 6,127 | 719 | 555 | 74 | 5,407 | 1,423 | 5,391 | 358 | 384 |

- About 5.4 GiB went through the pool between +60 and +120 s, which covers the prologue
  and the King's Pass load. Almost nothing went through it after that.
- Detaches, refused, unmatched, map failures, retired and purges were all 0. There were no
  "not leased" or "map failed" lines.
- The longest zeroing was 1.08 ms, and the longest backing call 1.15 ms.

### Verdict

- **Steady play costs nothing measurable.** The walk and the roam match: 59.9–60.0 FPS
  mean, the same median, and the same server requests per frame.
- **The cost is in scene loads.** In this pair the pool run's two loads took 1.5–2.2 s
  longer, and its 1 % lows were lower in every phase. The whole mean difference (1 FPS)
  comes from those loads.
- The pool's own measured work was 0.74 s (zeroing plus backing) over the whole run. That is
  less than the extra load time, and the same pool setting's menu load was normal in the
  failed run. So the pool is not shown to cause all of it.
- Together with the owner's A/B (a 44 FPS window in the pool run's load), this is the second
  pair in which the pool run's load is slower. It is one scripted pair: **not settled**, but
  a pattern to measure directly. Time the scene loads on several runs each, and the pool's
  calls inside them.
- The pool lowered peak `fpMB` by about 550 MiB in every phase.

### Slot 3

HK did not save slot 3:

- The retried pool-on run's gate read slot 3 as "New Game" after the off run.
- A check-only launch after both runs (`hk-check`, no slot pressed) read it again, with the
  cursor on it.
- Its screenshot shows slots 1, 2 and 4 unchanged: Dirtmouth 39 min, King's Pass 1 min,
  King's Pass 5 min.

So a new game in King's Pass, with the Knight hit but alive, does not autosave, and killing
the app is enough. The screenshots at +290 s show the Knight in the lumafly room in both runs,
with 3 of 5 masks off and 2 of 5 on.

## Detach probe: NOT RUN

The detach path (`protect.exe exec-rw` with the pool on) needs `protect.exe` in the app's
`Documents/Import/protect`. The app's library no longer lists any `dir-protect` title, and
pp has no command that copies a file to the phone:

- `pp phone` has status, kill, log, ls, pull, rm, shot and crashes.
- `tools/afc.py put` is reached only through phonelib's own code.

A one-off direct call would break the phone rules. A `pp phone put` would be a new
push-a-file tool, which decision 0012 rules out without the owner. With the supervisor's
agreement I skipped the probe.

**The owner can:**

- put `protect.exe` (`tools/compat/probes/build.sh`, built into
  `$PLAYPORT_BUILD/compat/probes/protect/`) in `Documents/Import/protect` with Files or Finder;
- or decide whether a `pp phone put` limited to `Documents/Import/` should exist.

After that, `pp ui --action import:Import/protect` and the `exec-rw` session (pool 0, then
4096) can run.

## Runs

All are under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/followups/`:

| Run | What |
| --- | --- |
| `hk-0` | pool off, the full route, 300 s |
| `hk-4096` | pool 4096. `hk-profiles`' A was missed, the gate failed and the app was killed at +48 s. Its figures are not used |
| `hk-4096b` | pool 4096, the retry with `hk-profiles-hold`, the full route, 300 s |
| `hk-check` | check only: the profile screen read, no slot pressed |

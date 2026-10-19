# Donor pool: Auto from the RAM headroom, a growth stop on low memory, MADV_ZERO for reused pages

**Date:** 2026-10-15 (01:00–02:20). **Branch:** `research/extended-memory`.
**Linear:** [PLA-351](https://linear.app/playportdev/issue/PLA-351) (Auto) and
[PLA-216](https://linear.app/playportdev/issue/PLA-216) (the pool's cost); the titles are PLA-42
(Hollow Knight) and PLA-49 (Kingdom Come).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes), the queue's follow-ups to items 1
and 2. The owner was asleep and the phone was in unattended mode. Where there was a choice, the
conservative option was taken (listed under "Choices").

**Setup:**

- iPhone18,4, iOS 27.0.1, 11,734 MiB of RAM, on the charger (100 % throughout).
- Dev IPA SHA256 `a3058addaff88dc7ae7354d1bcdd2bb2f09643c6327865497cb303b3d78f2ad8`
  (commit `28108ca`), installed with `pp install --no-build`.
- One locked session, `autozero-session.sh`, with its log and runs under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/autozero/`.

## 1. Where the Hollow Knight load gap went (host, from the logs)

The [follow-ups' pair](2026-10-15-donor-pool-followups.md) had the pool run's two scene loads
1.5–2.2 s longer (`followups/hk-0` against `followups/hk-4096b`). Its logs show why:

- **The pool run built 41 Metal pipelines and the off run none** (mesa 0016's
  `[kk-compile] render` lines: one Metal library plus pipeline build over 20 ms each). The
  failed pool run before it (`hk-4096`) built none either. Hollow Knight runs on Vulkan
  (KosmicKrisp) here.
- **The builds fall inside the two long frame groups:**

  | Load | Off | Pool | Difference | Metal builds in the pool run's group |
  | --- | ---: | ---: | ---: | --- |
  | Menu (t ≈ 12 s) | 1.86 s | 4.05 s | 2.19 s | 15 builds, 2.42 s |
  | King's Pass (t ≈ 92 s) | 1.68 s | 3.19 s | 1.51 s | 9 builds, 1.51 s |

- **The pool's own work there was small.** Between the stats lines around the menu load its
  backing hook took at most 4 ms. Around King's Pass (install + 90 to + 120 s, 3 GiB served)
  it took 241 ms, of which 230 ms was zeroing. There was no compression of pool pages then
  (76 MiB), and the hook makes no server round trip: it is an in-process call per commit of up
  to 64 MiB.
- **So the gap was iOS's Metal compiler cache, cold in that one run**, not page faults,
  backing, compression or zeroing. Why that cache was cold is not known: the off run 20 minutes
  earlier and the failed pool run built nothing.
- **This session confirms it** (section 4): with no Metal builds in either run, the loads
  match within 0.06 s.

The pool's own cost that does matter is Kingdom Come's: zeroing took 49.4 s for 387 GiB over
32 minutes, at most 11.8 ms per call, on a Wine thread under `virtual_mutex`
([measure](2026-10-14-donor-pool-measure.md)). Its rate was 120–145 ms per GiB in each 30 s window (131 over the run), six times the
probe's memset rate on an already mapped view (1.28 ms per 64 MiB,
[reuse](2026-10-14-donor-pool-reuse.md)). A reused range is a fresh `vm_map` at Wine's new
address, so memset takes a page fault on every 16 KiB page, and decompresses the stale pages
the system compressed (1.1 GiB of the pool by +600 s).

## 2. What changed

### Auto from the headroom (`DonorPoolSizing`, PLA-351)

The owner's direction: size Auto from the headroom, not from `P − L`, and stop growth on low
memory during play.

- **Game budget** = RAM − 2,048 MiB system reserve − the spare floor (`max(768, 12 % RAM)`).
  - The reserve is wired memory rounded up: 1,662–1,952 MiB at the pool's installs.
  - The budget is 8,278 MiB on 12 GB and 4,710 on 8 GB.
- **App part** = min(L, 4,096 MiB). Kingdom Come's own footprint beside a 5 GiB pool stayed
  at 3,750–3,900 MiB for 32 minutes (peak 4,007), rounded up. An unentitled app can use no
  more than its limit.
- **Target** = min(6,144, round down to 256 MiB of (budget − app part)). It is 0 under
  1,024 MiB.
- **Gates:**
  - It is not gated on `P − L` or on jetsam's level at Play: at Play, idle processes are
    jetsam's to end.
  - It still needs a readable level over 15 %, the 7 GiB tier (the setting is hidden under
    it), and a first donor with at least 1 GiB available.
- **Auto takes one donor** (its available memory less 512 MiB: 5,627 → 5,376 MiB on this
  phone). The fixed sizes keep their level cap and up to 8 donors.
- **The default stays Off.**

**Per tier** (host tests, `DonorPoolSizingTests`):

| Tier | RAM MiB | Budget | L entitled | Auto (entitled) | L not entitled | Auto (not) |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| 12 GB | 11,734 | 8,278 | 8,192 with Game Mode; 6,144 before | **4,096** (8,278 − 4,096 = 4,182) | 3,356 | **4,864** (4,922) |
| 8 GB | 7,679 | 4,710 | 6,046 | 0 (614, under 1,024) | 3,355 | **1,280** (1,355) |
| 6 GB | 5,734 | – | not public | 0, not offered | 3,064 | 0, not offered |
| 4 GB | 3,662 | – | not public | 0, not offered | 2,090 | 0, not offered |

**Why these numbers.** On 12 GB the game's whole set then stays near what Kingdom Come ran for
32 minutes without jetsam:

- that run had a 3.9 GB app and a 4.3 GiB live pool;
- Auto gives 4 GiB beside an app part of up to 4 GiB.

The task asked for about 4–6 GiB on the 12 GB phone; 4,096 is the low end:

- the 2 GiB reserve and the 12 % floor are what the phone measurably needs;
- the kernel's available memory fell to about 1.4 GiB in this session's Kingdom Come run
  (section 5), which is at the floor already.

**Growth during play** (`DonorPoolSizing.growthStop`, `DonorPool.watchGrowth`):

- Every 2 s, a utility queue reads the phone's spare memory (free + inactive + speculative +
  purgeable) and jetsam's level.
- **Stop:** spare under the floor, or the level under 15 %. The pool then backs new commits
  only with stale pages, which it has used since their object's last purge. So its resident
  set does not grow, and new memory is the app's own, which jetsam can see.
- **Resume:** spare ≥ floor + 512 MiB, and the level ≥ 20 %.
- Each change logs one `donor-pool: pressure: growth stopped|resumed …` line and a stats line.
  The stats line has `growing` and `growth_refused`.
- The check applies to the fixed sizes too.

**The memory plan** (`MemoryPlan`, PLA-352):

- A pool now raises guest RAM by at most (budget − L), rounded down to 256. This replaces
  `P − L`, so the guest is never told more than Auto's budget.
- On the reference phone that is 0 (86 MiB over L). It is 2,048 at a 6,144 limit and 4,864 on
  an unentitled 12 GB phone.
- The video budget is unchanged and independent of the pool.
- The `memory plan:` line prints `budget_mb` in place of `P_mb`.

### Zeroing (`GuestPool.m`, PLA-216)

- **Stale runs of 64 KiB or more are zeroed with `madvise(MADV_ZERO)` through Wine's new
  mapping;** smaller runs by memset. The kernel zeroes the object's resident pages without a
  fault per page and drops compressed ones without decompressing them.
- **Checks:** the first 64 such runs, and every 256th after, check that the run's first and
  last page read zero.
- **Fallback:** a failure, or a check that reads non-zero, logs one line and switches to memset
  for the rest of the process.
- The stats line adds `madv_zeroed_mb`, `madv_zero_ms_total` and `madv_failures`.
- The host test (`app/tests/guest_pool_test.c`) adds growth-stopped takes, which use only stale
  runs with best fit and count their refusals. Its 300 random seeds now toggle growth too, and
  a take while stopped must hand out only pages the model holds as stale.
  - Mutations run under `timeout 60`: ignoring the stop fails it (3,747 failures), and so does
    dropping the refusal count (4).
  - Removing the early skip of objects with too few stale pages passes. That skip is only a
    shortcut.

## 3. Considered and not done

- **Zeroing after `virtual_mutex`:** not done. It needs a new Wine hook after the unlock (a
  madeira-unix patch). It would also let another guest thread read a released range's old
  data before the zeroing, which breaks the zero-on-commit rule for racing code.
- **Fresh pages before stale ones:** not done. Stale pages are resident or compressed already,
  and only a purge returns them. Taking fresh pages first would grow the pool's resident set
  toward its full size, and physical RAM is the wall.
- **Batching backing requests:** there is nothing to batch. The hook is a direct in-process
  call, one per commit of up to 64 MiB, with no server request.

## 4. Hollow Knight A/B on the phone

- **The flow** is [the follow-ups'](2026-10-15-donor-pool-followups.md) (`followups-hk-retry.sh`'s
  gate): slot 3 must read New Game with the cursor before `hk-slot-new-game`.
  - `pp perf --no-hud --secs 300 --cool 15 --cool-max 25`.
  - Pool off (`set:donorPoolMB=0`), then `set:donorPoolMB=auto`.
- **The Auto line:**

```
donor-pool: auto L_mb=8191 budget_mb=8278 app_part_mb=4096 ram_mb=11734 level=48 footprint_mb=588 donor_limit_mb=6139 target_mb=4096 reason="budget 8278 MiB - app 4096 MiB = 4182"
donor-pool: installed granted_mb=4096 objects=16 donors=1 stop="target reached" in 0.69 s
```

  At level 48 % and L 8,191, the same reading for which the old Auto took nothing, Auto now
  takes 4 GiB.

| | Off (`hk-0`) | Auto 4096 (`hk-auto`) |
| --- | ---: | ---: |
| First frame | +9.56 s | +9.75 s |
| Thermal | nominal | nominal |
| Mean / median FPS, 0–300 s (`[frames]`) | 57.5 / 59.9 | 57.4 / 59.9 |
| 1 % low, 0–300 s | 21.8 | 21.8 |
| Menu load (t ≈ 12 s) | 1.85 s | 1.82 s |
| King's Pass load (t ≈ 93 s) | 1.67 s | 1.73 s |
| Metal pipeline builds (`[kk-compile] render`) | 0 | 0 |
| Peak `fpMB` | 3,442 | 2,966 |
| Server requests per frame | 24.7 | 24.8 |

By phase, as mean / median / 1 % low FPS:

| Phase (t, s) | Off | Auto |
| --- | --- | --- |
| Menu, 0–60 | 58.2 / 59.9 / 30.4 | 58.2 / 59.9 / 26.4 |
| Prologue and load, 60–106 | 45.7 / 59.9 / 9.6 | 45.6 / 59.9 / 9.2 |
| Walk, 106–137 | 59.9 / 59.9 / 55.9 | 59.7 / 59.9 / 44.9 |
| Roam, 137–300 | 60.0 / 59.9 / 59.6 | 59.9 / 59.9 / 54.4 |

- **The loads match.** With no Metal builds in either run, the scene loads differ by 0.03 and
  0.06 s. This settles section 1.
- **The pool's cost in HK:**
  - zeroing 135 ms for 5,436 MiB, all by `MADV_ZERO` (25 ms per GiB). The follow-ups' run
    took 358 ms for 5,391 MiB by memset (68 ms per GiB);
  - backing 163 ms against 384 ms;
  - the longest zeroing 0.62 ms (1.08 before), and the longest backing call 0.73 ms (1.15).
  - Refused, unmatched, detaches, map failures and MADV_ZERO failures were 0, and the zero
    checks passed.
- **Still open: the walk and roam 1 % lows were lower again** (44.9 and 54.4 against 55.9 and
  59.6), as in the follow-ups' pair.
  - The pool's hooks were idle then: 2 ms of backing between +120 s and +300 s.
  - The slowest groups (0.29–0.36 s for 16 frames, against 0.27–0.29 off) sit at the roam
    route's steps.
  - A cause in the pool's mappings, such as one VM map entry per backed commit for each fault
    and `mprotect` to search, is a guess and was not measured.
- **Slot 3:** the Auto run's gate read slot 3 as New Game after the off run, so the off run did
  not save. The Auto run was killed the same way: nothing pressed START, Save or Quit.

## 5. Kingdom Come with Auto

`set:donorPoolMB=auto`, then `pp perf --no-hud --syslog-all --secs 600` from the first frame,
using the Continue flow (`measure-s1-kcd.sh`'s):

- the menu was read;
- the `--highlight-above` check found Continue;
- `kcd-continue`, then `kcd-walk`.

The screenshot at +300 s shows Henry in Rattay, by the church. The `Rattay` text check at +45 s
read nothing, as in PLA-352's run.

```
donor-pool: auto L_mb=8191 budget_mb=8278 app_part_mb=4096 ram_mb=11734 level=51 footprint_mb=575 donor_limit_mb=6139 target_mb=4096 reason="budget 8278 MiB - app 4096 MiB = 4182"
donor-pool: installed granted_mb=4096 objects=16 donors=1 stop="target reached" in 0.66 s
donor-pool: pressure: growth stopped (level 14% < 15%) spare_mb=4154 level=14 pressure_level=-1 floor_mb=1408
```

- **First frame +29.06 s.** FPS: mean 25.3, median 19.8, p10 14.4 (`pp perf`). Thermal went
  nominal → fair → serious.
- **Peak `fpMB` 4,292**, against 7,682–7,914 with the pool off
  ([widen](2026-10-14-donor-pool-widen.md), [kcd](2026-10-14-donor-pool-kcd.md)) and 3,884
  with a 5,120 MiB pool. The app ended at 4,054 MiB footprint with 4,137 available.
- **No jetsam.** The app ran to `pp perf`'s end (ok, rc 0). The kernel's kills were all
  `long-idle-exit` of idle processes (194 in the syslog). `healthd` logged critical
  memory-pressure warnings around the load, as in the 32-minute run.
- **The growth stop:**
  - It fired at install + about 155 s: the level was 14 % while the spare sum read 4,154 MiB.
    The kernel's `memorystatus_available_pages` was 1,397–1,586 MiB from +3 minutes on, so
    the level, not the spare sum, saw the low memory.
  - The pool then held 3,952 of 4,096 MiB live, so the stop changed little: the pool was full
    from +180 s and refused the rest (42,149 refusals, 42,125 of them while stopped).
  - Growth did not resume. That was one `pressure` line, and there was no flapping.

**Zeroing and backing, before and after.** These are the same title, flow and stats lines,
compared at the same point while the pool was still serving (about 29 GiB served and 25 GiB
zeroed in both):

| Up to install + 180 s | Before (`kcd-long-6144`, memset, 5,120 MiB) | After (`kcd-auto`, MADV_ZERO, 4,096 MiB) |
| --- | ---: | ---: |
| Served / zeroed | 29,665 / 25,270 MiB | 28,418 / 24,198 MiB |
| Zeroing | 2,299 ms (93 ms/GiB) | **370 ms (16 ms/GiB)** |
| Backing hook total | 2,761 ms | **771 ms** |
| Longest zeroing / backing call | 4.47 / 4.50 ms | **1.80 / 3.52 ms** |
| Pool compressed | 753 MiB | 486 MiB |

- **Whole run:** zeroing 495 ms for 27,562 MiB (18.4 ms per GiB, all by `MADV_ZERO`, 0
  failures), and backing 1,019 ms over about 640 s.
  - The 32-minute memset run's whole-run rate was 131 ms per GiB, with a longest call of
    11.8 ms.
  - The two runs' pool sizes differ (5,120 against 4,096 MiB), and after +180 s this run's
    pool was full. So compare the first 180 s, not the totals.
- **What is left of the backing hook** after zeroing (about 400 ms per 29 GiB) is the
  `vm_map` and the bookkeeping. It was about 460 ms before.

## Choices (owner asleep)

- **Auto's numbers:**
  - The system reserve is 2,048 and the app part 4,096. This gives 4,096 on 12 GB, the low end
    of 4–6 GiB, because Kingdom Come's run already brought the kernel's available memory to
    the floor.
  - Auto takes one donor.
  - The level gate (over 15 %) stays at Play; the level cap applies only to the fixed sizes.
- **The growth stop:**
  - It uses the level and the spare sum, but not `memorystatus_vm_pressure_level`. That
    reading was −1 (unreadable) on the phone, and the 32-minute run lived through
    "critical" warnings.
  - It applies to the fixed sizes too.
- **`MADV_ZERO`:**
  - It is used only for runs of 64 KiB or more, with sampled read checks and a memset
    fallback for the rest of the process.
  - It stays on Wine's thread under `virtual_mutex`, now about 6× faster.
- **No Wine patch:** the madeira-unix series is unchanged. Only app code changed.
- **The default stays Off.**

## Not shown

- Auto on any phone but the 12 GB entitled one, or with Game Mode not yet raising the limit.
- **Growth resuming** after a stop. KCD never recovered to the resume thresholds, and no run
  exercised the resume.
- **The spare sum** (free + inactive + speculative + purgeable) read about 2.5 GiB above the
  kernel's available pages. As a growth signal it is weak; the level carried the stop.
- **Why the pool runs' walk and roam 1 % lows are lower**, in two pairs now.
- **Why iOS's Metal cache was cold** in the follow-ups' pool run.

## Games

- Hollow Knight (app-367520): Works. Two 300 s runs, slot 3's new game, no save.
- Kingdom Come: Deliverance (app-379430): Works, with the pool on Auto (4 GiB). It played
  600 s in Rattay.

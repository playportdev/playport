# Donor pool purges, and the Vulkan clamp on by default

**Date:** 2026-10-15 (15:20–16:04). **Branch:** `dev/pla-362-vulkan-8gb-purge` (`964e08c`,
`435955d`).
**Linear:** [PLA-363](https://linear.app/playportdev/issue/PLA-363) (purges),
[PLA-362](https://linear.app/playportdev/issue/PLA-362) (Vulkan),
[PLA-355](https://linear.app/playportdev/issue/PLA-355) (the 8 GB row),
[PLA-216](https://linear.app/playportdev/issue/PLA-216); the title is PLA-42 (Hollow Knight,
app-367520).
**Decision:** [0106](../decisions/0106-8gb-row-in-full-and-vulkan-plan-default.md).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes). The purge path is the one
[the copy-back probe](2026-10-15-donor-pool-copyback.md) never reached.

## Setup

- iPhone18,4, iOS 27.0.1, on the charger (80 % at the start and the end), unattended mode on.
- Dev IPA SHA256 `560d43cbdc211469d0a11450485c9eaefe6100ec227bf5f478cf3ed5560abe05`
  (commit `435955d`), installed in place in this session ("upgrade in place").
- **Session scripts:** in `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`:
  - `vk8gb-session.sh`: the install, the HK runs and the probe;
  - `vk8gb-perf-retry.sh`: the one retry of the HK perf run.

  Their `.log` files and run directories are under `runs/vk8gb/`.
- **The probe:** `tools/compat/probes/protect.c`'s new `purge` phase, built by
  `tools/compat/probes/build.sh` as `protect.exe` (1,136,640 bytes, sha256 prefix
  `5be5303663559553`).
  - It was put with `pp phone put … Documents/Import/protect/protect.exe` and imported with
    `pp ui --action import:Import/protect`.
  - It ran with `--settings '<id>:{"arguments":"purge"}' --play <id> --wait 600`, once with
    `set:donorPoolMB=0` and once with `=auto`.
  - The import added a second library entry, `dir-protect 2`, beside the 2026-10-12
    `dir-protect`. It was left in place.

## What the probe does

`protect.exe purge` runs five cycles. Each cycle:

1. Commits six 256 MiB `PAGE_READWRITE` regions (1.5 GiB).
2. Checks that every word of every page reads zero.
3. Writes a tagged pattern to every page (the cycle, the region and the page, then a fill
   byte) and reads the tags back.
4. Holds for 35 s.
5. `MEM_RELEASE`s all six regions, then commits 1 MiB. That commit is a hook call, so the
   pool runs the purge the last release deferred.
6. Holds for 35 s again.

The holds are longer than the pool's 30 s stats interval, so every leased state and every
released state has its own `donor-pool: stats` line.

After the cycles, the probe tests decommit:

1. It writes a 256 MiB region.
2. It `MEM_DECOMMIT`s a 64 MiB part and recommits it.
3. It decommits the whole region and recommits it.

Each recommitted page must read zero, and the part that was not decommitted must keep its
pattern.

The run in desktop Wine on the workstation, built with the hold at 0, gave `done ok`.

**Instrumentation added for this run.** The dev `donor-pool: stats` line now also carries the
phone's memory (`SharedMemoryProbe.system()`: `sys_free_mb`, `sys_inactive_mb`, …,
`sys_level`, which is jetsam's memorystatus level in %). Before this, the kernel's figures were
logged only at the pool's install. Nothing else changed in the pool.

## Results

Both runs: `protect: CHECK purge 5 cycles: stale pages 0, pattern lost 0, failed allocations 0,
frees 0, decommits 0 ok`, then `done ok`, exit 0 after 353 s.

| | Pool off | Pool Auto (4,096 granted, 16 objects, one donor) |
| --- | --- | --- |
| Stale pages in recommitted memory (5 cycles × 1.5 GiB, plus the decommit test) | 0 | 0 |
| Pages that lost the pattern | 0 | 0 |
| Probe: zero check of 1.5 GiB / pattern write / release of all six | 145–191 / 76–94 / 36.5–40.7 ms | 152–205 / 74–99 / 80.6–88.0 ms |
| Objects purged (`object N free again`, `resets`) | – | 6 a cycle (objects 1–6), 30 in all; retired 0 |
| `purge kr=` | – | 0 every time (`zeroed`) |
| Purge time | – | 65, 69, 70, 69 and 67 ms a cycle (`purge_ms_total` 340); 9.7–22.8 ms for a whole object, 0.3–0.5 ms for object 6 (9 MiB touched) |
| Pool live / resident / compressed, MiB, leased | – | 1,545 / 1,536 / 0 (every cycle) |
| The same, released and purged | – | 10 / 192 / 0 (every cycle) |
| Reuses | – | 4 a cycle (17 in all): the 1 MiB trigger, and 3 × 64 MiB of object 0's stale range, zeroed (`MADV_ZERO`) in 2.4–3.2 ms each, 193 MiB a cycle |
| Map failures, refused, unmatched, detaches | – | 0, 0, 0, 0 |
| App footprint (`[footprint]` phys), leased / released, MiB | 2,215–2,218 / 681 | 670 / 669 |
| App available (`os_proc_available_memory`), leased / released, MiB | not logged (L − footprint: about 5,974 / 7,511) | 7,521 / 7,522 |
| Phone free (`sys_free_mb`), leased / released, MiB | not logged | 1,138–1,161 / 2,482–2,507 |
| Phone inactive, leased / released, MiB | not logged | 3,464–3,605 / 3,115–3,139 |
| memorystatus level, leased / released | not logged | 33–34 % / 45 % |
| Decommit test region | ordinary memory (footprint 937 MiB before each decommit, 873 and 681 after) | pool memory (footprint 669 MiB before and after) |

- **Whole objects were freed and came back zeroed.**
  - Each release of the six regions emptied objects 1–6, and each was purged at the next hook
    call (`purge kr=0 … (zeroed)`).
  - The next cycle's 1.5 GiB read zero on every page. It was served from the purged objects
    and from object 0's stale range, which was zeroed on reuse.
  - The pool logs its first 16 purges one by one (`resets=1` to `16`); the stats lines count
    all 30.
- **No leak.** After every cycle the pool's live set returned to its baseline of 10 MiB: the
  runtime's own small commits, which lease object 0. Resident memory returned to 192 MiB.
  - Those 192 MiB are the part of the first region that lies in object 0. That object never
    empties, so it is not purged, and the range stays stale (`stale_mb=191`) until the next
    cycle's commit zeroes it.
  - The figures are the same after cycles 1 to 5. `released_mb` grows by 1,536 a cycle and
    `served_mb` by 1,536 (7,694 in all).
- **The purge gives the memory back to the phone.** With the pool, the leased 1.5 GiB is
  outside the app's footprint (670 MiB throughout). After the purge, the phone's free memory
  rose by about 1,340–1,360 MiB and jetsam's level by 11 points, every cycle. Without the pool, the
  footprint rose by about 1,535 MiB while leased and fell back to 681 MiB after the release.
- **Cost:** the release of six regions took 81–88 ms with the pool and 37–41 ms without it.
  About 65–70 ms of that is the five purges that each release defers to the next. The sixth
  purge falls on the trigger commit.
- **Decommit:**
  - Decommit and recommit of a pool-backed region read zero, both for the 64 MiB part and for
    the whole region.
  - Wine's decommit replaces the mapping with fresh memory (`[decommit-zero] … branch=mmap-over`).
  - Whether the recommit was backed by the pool again is not logged: there was no stats line
    after it, and the recommitted pages were only read.

## Hollow Knight gates (Vulkan clamp on by default, decision 0106)

| Run | Settings | First frame | `memory plan:` | Vulkan | DXMT |
| --- | --- | --- | --- | --- | --- |
| `hk-vulkan` | default (Vulkan), Auto | +11.91 s | tier 12GB, G 8,192, V 3,072, pool 4,096, `clamp=none`, `vulkan_clamp=1`; `DXVK_CONFIG dxgi.maxDeviceMemory = 3072; PLAYPORT_VK_BUDGET_MB=3072` | `[kk-memory] heap 0: size 8192 MiB, budget capped at 3072 MiB` (one line per instance, 2); DXVK `Heap 0: 8.0 GiB`, `Budget: 3.0 GiB` | – |
| `hk-dxmt` | `{"graphics":"dxmt"}`, Auto | +11.74 s | the same line | – | `ml1042 video memory budget = 3072 MB (… from Playport's memory plan)`; ml1075 3,072 |

- **Both runs reached first frame +10.** Each shot shows Hollow Knight's title menu.
- **The Vulkan figures are now the plan's without any key.**
  - Before (decision 0105, [vulkan clamp](2026-10-15-vulkan-clamp.md)), with the key off, HK
    on Vulkan read `Budget: 6.1 GiB`, and DXGI reported 8,160 MiB of dedicated memory.
  - DXGI's dedicated memory now is 3,072 MiB, by DXVK's code from the logged option. DXVK does
    not log it.
- **First frame** was at +12.84 s (Vulkan) and +12.16 s (DXMT) on the 0105 build. That is one
  run each: noise.

### HK play, Vulkan: the clamp alone against the earlier run

**How the run was driven:**

- `pp perf --no-hud --secs 240 --cool 15 --cool-max 25`, with the committed slot-3 New Game flow
  and its wait-text gates, as in [the follow-ups](2026-10-15-donor-pool-followups.md):
  1. Main menu read.
  2. `hk-profiles-hold`.
  3. "Select Profile", slot 3 "New Game" and slot 3's cursor fleur read.
  4. `hk-slot-new-game` at +60 s, `hk-walk` at +106 s, `hk-roam` at +137 s.
- `pp perf`'s kill at +240 s is the quit without saving.

**This run had the pool OFF, not Auto.** The script ran `pp phone unattended on` between
`set:donorPoolMB=auto` and `pp perf`. Its black-screen launch is outside the session, so it
undid the setting: no `donor-pool:` line, and the plan line has `pool_mb=0`. With the clamp on
(`vulkan_clamp=1`, `[kk-memory]` cap 3,072, `Budget: 3.0 GiB`), this makes it a clean A/B of
the Vulkan clamp alone against the earlier pool-off Vulkan run `hk-0`, which had the clamp off.

Figures are mean / median / 1 % low FPS from the `[frames]` lines, computed as in the
follow-ups:

| Phase (t, s) | Clamp on, pool off (this run) | Clamp off, pool off (`hk-0`, 2026-10-15 00:09) |
| --- | --- | --- |
| Menu, 0–60 | 58.3 / 59.9 / 30.1 | 58.3 / 59.9 / 30.3 |
| Prologue and load, 60–106 | 45.8 / 59.9 / 9.5 | 45.8 / 59.9 / 9.5 |
| Walk, 106–137 | 59.9 / 59.9 / 55.6 | 59.9 / 59.9 / 55.9 |
| Roam, 137–240 | 60.0 / 59.9 / 56.8 | 60.0 / 59.9 / 58.4 |
| Longest 16-frame group | 1.86 s (t 12.5) | 1.86 s (t 12.5) |
| Groups over 0.4 s, 0–240 | 33 | 33 |
| Peak `fpMB` | 3,477 | 3,561 |
| First frame | +10.95 s | +10.65 s |
| `c0000005` lines | 14 | 14 |

- **No regression.** Every phase matches within the run-to-run noise. Hollow Knight's GPU
  memory is far under 3 GiB, so a 3 GiB budget changes nothing for it.
- The shot at +230 s shows the Knight in King's Pass.
- **The retry with Auto** (`vk8gb-perf-retry.sh`) was the one retry, after the fix (the set
  right before `pp perf`, with nothing launched between). Its plan line had `pool_mb=4096` and
  `vulkan_clamp=1`.
  - It stopped at the cursor gate. HK's cursor was on slot 2, not slot 3, so the fleur crop read
    nothing.
  - Nothing was pressed on a slot. The app was killed and that run has menu-only data.
  - The retry's profile screen shows slot 3 still "New Game", with slots 1, 2 and 4 as before
    the session, so no save was made.
- **Not measured as one run:** the Vulkan clamp with the Auto pool under play. Pool-on HK play
  on Vulkan was measured on 2026-10-15 ([follow-ups](2026-10-15-donor-pool-followups.md)).

## Not covered, risks

- **One run each way.**
- **The pool-off run has no kernel figures.** The stats line exists only with a pool.
- **DXVK's eviction over budget** (decision 0106) is unmeasured on a heavy Vulkan title.
- **The 8 GB row** (decision 0106) has not run on an 8 GB phone (PLA-355).

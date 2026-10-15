# Donor pool reuse inside an object: the pool serves the whole Kingdom Come run

**Date:** 2026-10-14. Branch `research/extended-memory`, commit `9f4d5bf`
(on `aa56a57`). **Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216);
the title is PLA-49.
**Plan:** [donor memory, step 4](../plans/2026-10-12-donor-memory.md#4-does-it-help-a-game).
**IPA:** `Playport-26.5-2010a999.ipa` (dev, entitled build), SHA256
`2010a999cbfbdc596acf1f66e3a0a7c662fe01a821c9c9930ef520e516f29021`, installed
in place. iPhone18,4, iOS 27.0.1, 11734 MiB physical RAM, battery 79 → 72 %
on battery (not on power), 5.8–5.9 GB storage free. Every run below used
this IPA.

## What changed

The [previous pair](2026-10-14-donor-pool-kcd.md) found that the pool
stopped serving after about install+150 s: `refused` reached 13,211 with
only 631 MiB live. Its per-object bump allocator reused an object only once
all of it was free.

- **Allocator (`app/Sources/SharedMemory/guest_pool.c`).** Each object has
  two page bitmaps (16 KiB pages): *leased* and *stale* (free, and may hold
  old guest data).
  - A request takes the smallest free run that fits, over all objects (best
    fit, lowest object and offset on a tie). Freed neighbours coalesce,
    because they are adjacent free pages.
  - A release makes the pages free and stale.
  - When an object's last lease goes, it awaits a purge. It is not handed
    out until it is purged whole (EMPTY, then non-volatile, as before) and
    reset. A failed purge retires it.
- **Zeroing a reused range (`GuestPool.m`).** Right after the
  `vm_map(FIXED|OVERWRITE)` at Wine's address, and before the hook returns,
  the take's stale runs are zeroed with `memset` through that new mapping.
  Pages that never held data, or that were purged, are not touched.
- **When zeroing runs.** Wine calls the release hook before it replaces its
  own mapping of the range (`delete_view`, `decommit_pages`), all under
  `virtual_mutex`.
  - A partial range is zeroed only when it is taken again, at Wine's new
    address.
  - A whole-object purge is deferred to the start of the next hook call.
    Step 3 purged inside the release hook.

  So no zeroing runs while Wine still maps the old range. madeira-unix 0148
  is unchanged: it already reports releases page by page.
- **New stats fields:** `stale_mb`, `reuses` (takes that zeroed stale
  pages), `zeroed_mb`, `zero_ms_total`, `zero_us_max` and `purges_pending`.
  The stats line also has `resident_mb` and `compressed_mb` of the pool's
  objects, as before.
- **Host test (`app/tests/guest_pool_test.c`).** It runs against a page
  model and covers:
  - reuse with zero on reuse, and best fit;
  - coalescing;
  - fragmentation: one-page holes serve one-page takes, a larger take goes
    to a fresh object or is refused;
  - exhaustion;
  - an emptied object awaiting its deferred purge is never handed out;
  - a failed purge retires the object;
  - the split bound;
  - 300 random seeds with deferred and failing purges.

  Two mutations fail it: a pool that reports no stale pages, and a pool that
  hands out an object awaiting its purge.

## Zeroing a partial range: measurements and choice

`probe:memory-pool-zero` (run `pool-zero-reuse`) now also refills one
256 MiB pool object, from a donor that has ended, and treats a 64 MiB part
of it in four ways through the object's own view:

| Method | rc | Time (64 MiB) | Reads zero | Object resident before → after |
| --- | --- | ---: | --- | --- |
| `memset` | 0 | 1.28 ms | yes | 256 → 256 MiB |
| `madvise(MADV_ZERO)` | 0 | 1.48 ms | yes | 256 → 256 MiB |
| `madvise(MADV_FREE_REUSABLE)` + `memset` | 0 | 2.50 ms | yes | 256 → 256 MiB |
| `madvise(MADV_FREE_REUSABLE)` alone | 0 | 0.20 ms | **no** (old data) | 256 → 256 MiB (read before the check) |

The same run repeated step 3's whole-object numbers, and the probe's result
was PASS:

- memset of all 256 MiB: 14.15 ms;
- purge of a touched object: 8.69 ms, after which 0 MiB was resident;
- purge of an untouched object: 0.02 ms.

**Choice: `memset` of the stale runs only, at take time.** It is correct for
any object and is as fast as `MADV_ZERO` here.

- `MADV_FREE_REUSABLE` succeeds on the shared purgeable pool mapping but
  frees nothing: the object stayed at 256 MiB resident and kept its data.
  It cannot return freed pool pages to the system.
- **The other option was not used.** It was to deallocate the app's mapping
  and `vm_map` a fresh object. A fresh object would be the app's own and
  charged to it, so it defeats the donor.
- **Return to the system:** this happens only by the whole-object purge.
  `MADV_ZERO` succeeded and read zero. If compressed stale pages build up, it
  is a candidate for zeroing them, because it frees compressor slots without
  faulting them in. That was not measured: the probe cannot force
  compression.

## The session

The script was `reuse-session.sh` in
`$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`, a copy of
`step4-session.sh` with the new IPA. It also ran the probe after the
install. It ran as one `pp phone lock -- sh` from 15:26 to 15:42. Steps:

1. `pp phone status`, then `pp install --no-build`: 21 s, upgrade in place,
   container kept.
2. `probe:memory-pool-zero`, then 60 s rest.
3. KCD with the pool off.
4. 120 s rest.
5. KCD with `set:donorPoolMB=6144`.
6. 120 s rest.
7. Hollow Knight with 4096 MiB to first-frame+10.
8. `pp phone status`, then `pp phone kill`.

Each Kingdom Come run follows the [previous pair](2026-10-14-donor-pool-kcd.md):

- `pp pad wait-text` for the menu, then the `--crop --highlight-above`
  check of Continue;
- one A, 45 s, a `pp phone shot`;
- `pp pad push kcd-walk`;
- `pp ui` ends the run at first frame +205.

The EULA did not come back. No run was retried.

**Before the build: re-registration.** Signing the dev build first failed
with a 409, "There are no current IOS devices on this team matching the
provided device IDs", and `xtool ds devices` listed nothing. The owner
approved the documented fix ([DEVICE.md, "Free-team limits"](../DEVICE.md#free-team-limits)),
done once:

1. `./pp build --variant release --unsigned` (IPA `251bc458…`, not run).
2. Under `pp phone lock`, `xtool install --network` of that unsigned IPA. It
   upgraded the app in place.
3. `xtool ds devices` then listed the phone (ENABLED). `./pp build` signed
   the dev IPA.
4. `pp install --no-build` replaced the app with the dev build before any
   launch.

`pp phone status` still reported one app, `dev.playport.app`, and the free-team
count was 3/3. The release app was never launched.

| Measurement | KCD, pool off | KCD, pool 6144 asked |
| --- | ---: | ---: |
| Run directory (under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`) | `kcd-reuse-off` | `kcd-reuse-6144` |
| Pool | none | `asked_mb=6144 cap_mb=5120` (level 60 % less 15 % of 11734 MiB), 5120 MiB in 20 objects from one donor, 0.72 s |
| Game started / first frame | +5.20 s / +26.83 s (with a VC++ prerequisite step first, see below) | +3.99 s / +25.57 s |
| Menu read, A on Continue | 15:30:18, 15:30:22 | 15:36:49, 15:36:53 |
| Thermal | nominal → fair at +76 s | nominal → fair at +51 s → serious at +241 s |
| Peak `[xp] fpMB` | **7,783** (at +234.8 s) | **7,201** (at +235.9 s), **−582** |
| `fpMB` at +110 / +170 / +230 | 6,011 / 7,461 / 7,674 | 5,542 / 6,958 / 7,048 (−469 / −503 / −626) |
| End | `until first-frame+205` reached, `ok: true`, exit 0 | the same |
| `c0000005`, iOS crash reports, jetsam | none, none, none | none, none, none |

The times in the table are the `[xp]` line's seconds since the game started,
the same measure as the previous pair.

- **Prerequisite.** In the off run, the title first ran the VC++ 2015
  prerequisite step: x86 failed with "another build", as recorded before.
  This cost about 2 s before the game started. The pool run had no such
  step.
- **Screenshots** (they stay in the run directories):
  - **Off run:** loaded in Rattay's arcaded square, with compass and health
    bar. At the stop: a street of timber houses with NPCs, Henry's hand and
    staff in view.
  - **Pool run:** loaded at the same square, with a woman in blue at the
    right and the horse's head. At the stop: a pink-walled house behind a
    dry-stone wall.
  - No visual damage, no garbage textures, no stripes in either run.

### The pool over time (6144 run)

| Stats line | served | served_mb | live_mb | stale_mb | resident_mb | compressed_mb | reuses | zeroed_mb | zero_ms_total | refused | app_footprint_mb | app_available_mb |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| first frame | 449 | 1,321 | 621 | 56 | 516 | 0 | 393 | 643 | 25 | 0 | 2,567 | 5,624 |
| install+30 s | 503 | 1,568 | 665 | 128 | 631 | 0 | 440 | 774 | 31 | 0 | 2,851 | 5,340 |
| install+60 s | 677 | 3,028 | 834 | 57 | 744 | 0 | 612 | 2,137 | 101 | 0 | 3,169 | 5,022 |
| install+90 s | 2,395 | 7,158 | 600 | 290 | 748 | 0 | 2,330 | 6,267 | 458 | 0 | 4,448 | 3,743 |
| install+120 s | 2,717 | 7,823 | 621 | 269 | 657 | 98 | 2,652 | 6,931 | 507 | 0 | 5,674 | 2,517 |
| install+150 s | 7,385 | 17,402 | 652 | 239 | 488 | 266 | 7,320 | 16,510 | 1,417 | 0 | 6,811 | 1,380 |
| install+180 s | 10,130 | 23,058 | 765 | 126 | 501 | 256 | 10,065 | 22,166 | 2,021 | 0 | 7,085 | 1,106 |
| install+210 s | 12,930 | 28,813 | 698 | 193 | 518 | 241 | 12,865 | 27,922 | 2,636 | 0 | 7,104 | 1,087 |
| install+240 s | 16,688 | 36,552 | 699 | 191 | 519 | 240 | 16,623 | 35,660 | 3,454 | 0 | 7,133 | 1,058 |

In every line the following were 0: detaches, detached_mb, resets (whole-object
purges), retired, refused, unmatched_mb, map_failures and purges_pending.
The log has no "refused", "map … failed", "not leased" or "retired" line.

- **The pool kept serving.** `refused` stayed 0 through install+240 s,
  against 13,211 before. It served 16,688 requests, 36,552 MiB, through at
  most 834 MiB live. 16,623 of those takes reused freed ranges, and
  35,660 MiB of stale pages were zeroed.
- **Zeroing cost.** 3,454 ms in total, at most 4.35 ms for one take. That
  is about 0.1 ms per MiB, on Wine's thread under `virtual_mutex`. This is
  about 1.4 % of the 240 s, and it includes the page faults through the new
  mapping. The probe's 0.02 ms per MiB is for pages already mapped in the
  view.
- **No whole-object purge ran.** Best fit kept reusing holes in the
  partly used objects (the sampled log lines name only objects 0–2), so no object emptied.
  `resets` was 0, against 83 before. The release-then-deferred-purge path is
  host-tested only.
- **Fewer compressed pool pages.** `compressed_mb` peaked at 266 MiB,
  against 2,640 MiB before, and `resident_mb` stayed at 488–748 MiB. With
  reuse, the pool's touched set stays near its live set, plus 126–290 MiB
  stale.

### Why the peak did not fall by more than 697 MiB

The pass target was a gap larger than the previous pair's 697 MiB. This
pair's gap is 582 MiB, so the target was not met.

- **The pool saves at most its live, resident set.** That set stayed
  600–834 MiB in both runs (631 MiB live when the old pool stopped).
  Kingdom Come's large fresh RW commits churn: 36.5 GiB went through about
  700 MiB live. So the old pool, which stopped serving, already held about
  as much of the game's memory at any moment as the new one does.
- **More gap needs more backing.** To lower the footprint further, 0148
  must back more of the game's memory, not reuse it better. Today it backs
  only fresh anonymous RW commits of at least 1 MiB in
  `[0x7000000000, 0x7c00000000)`.
- **The spread between runs is large.** The two pool-off runs differ by
  131 MiB (7,914 and 7,783). This run also had the VC++ prerequisite step,
  and the pool run reached "serious". So −582 against −697 is within the
  run-to-run spread for one pair each.

## Hollow Knight (pool 4096)

Run `hk-reuse-4096`: `ok: true`, `until first-frame+10` reached.

- **Pool:** `asked_mb=4096 cap_mb=4608`, 4096 MiB granted in 0.72 s.
- **First frame:** +10.52 s. Earlier: +10.55 s with the pool on IPA
  `f1f024ae…`, +9.98 s with it and +10.24 s without it in step 3.
- **Stats at first frame+8s:**
  - 56 requests, 399 MiB served, 352 MiB live, 248 MiB resident;
  - 12 reuses, 44 MiB zeroed in 1 ms (at most 0.47 ms);
  - refused 0, unmatched 0, detaches 0, map failures 0.
- **Peak `[xp] fpMB`:** 2,453 (2,468 on `f1f024ae…`).
- **Exceptions:** the three handled `c0000005` first-chance exceptions the
  title always raises at start-up, the same in the pool-off and earlier
  pool runs.
- **Screenshot:** the title menu.

## Result

- **Refused stays near 0 through +230 s:** passed (0 through install+240 s).
- **Rattay loads, nothing crashes:** passed. Both runs loaded Rattay. There
  were no crash reports, no `c0000005` in Kingdom Come, no jetsam and no
  visual damage. Unmatched 0, map failures 0, detaches 0.
- **Peak more than 697 MiB below pool-off:** not met (−582). The gap is
  bounded by the pool's live set (above).

One pair, with a thermal difference (the pool run reached "serious").

## Not done

- **The deferred whole-object purge** did not run on the phone in this
  session. It is host-tested.
- **The detach path:** a PLA-203-family title.
- **A session over 30 minutes** with the pool on.
- **The HK `pp perf` A/B.**
- **Backing more of the game's memory,** which is what would raise the
  saving.

# Donor pool: what Kingdom Come's footprint is made of, and backing small commits

**Date:** 2026-10-14. Branch `research/extended-memory`. **Linear:**
[PLA-216](https://linear.app/playportdev/issue/PLA-216); the title is PLA-49.
**Plan:** [donor memory, step 4](../plans/finished.md#guest-ram-from-donor-processes).
iPhone18,4, iOS 27.0.1, 11734 MiB physical RAM, on external power, 5.4–5.5 GB
storage free.

| IPA | Commit | What it adds | Runs |
| --- | --- | --- | --- |
| `Playport-26.5-91861df5.ipa`, SHA256 `91861df5be2151ae0757dc90cca6bc3de28d5fbf732056491cc57a416ea0c812` | `cc2b80e` | madeira-unix 0149, the census (diagnostics) | `kcd-census-6144`, `hk-census-4096` |
| `Playport-26.5-b3cdca61.ipa`, SHA256 `b3cdca61de83582b96504df22c6d381592f3451e285fce11142e6a498f6025de` | `7413ff3` | madeira-unix 0150 and the pool's page table | `kcd-widen-off`, `kcd-widen-6144`, `hk-widen-4096` |

The run directories are under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`,
with the session scripts `census-session.sh` and `widen-session.sh` (copies of
`reuse-session.sh`: the same scripted Continue, `kcd-walk` and stop at first
frame +205). Each session ran as one `pp phone lock -- sh`, and each step ran
once. Plaion's EULA did not appear.

## 1. The census (madeira-unix 0149)

0149 changes nothing that Wine maps. While the host backs guest memory, it
logs every 30 s, under `virtual_mutex`:

- **`[guest-census]`:** each Wine view's committed runs (pages with one
  protection) by class, each with its committed size and its footprint. The
  footprint is the host pages that `mincore` reports in core or compressed,
  anonymous or copied, each counted once. Pool-backed pages go only to "pool".
  The classes are RW in the 0148 window by run size, and whether the view is
  only partly committed; exec; other protections; RW outside the window;
  image, section and system views.
- **Every commit since start, by what 0148 made of it:** backed, refused,
  under 1 MiB, not RW, outside the window, already partly committed, and the
  rest.
- **The warmer's `[phys-map]` address-space walk,** also every 30 s. It now
  also gives each band's dirty pages in shared objects. The `[footprint]` line
  adds the graphics and purgeable ledgers.

One census took 83–417 ms.

### Kingdom Come's footprint at install+240 s (about Play+230), pool asked 6144

Run `kcd-census-6144`. The pool was capped at 3584 MiB (jetsam level 45 %).
The app's footprint was 6,898 MB, peak `fpMB` 6,979.

| Part | Footprint (MiB) | Source |
| --- | ---: | --- |
| GPU (Metal, the graphics ledger) | 1,565 | `[footprint] graphics=` |
| Guest RW in the window, in views committed in full, runs of ≥ 1 MiB | 2,417 (3,333 committed) | `[guest-census] rw>=1M` |
| Guest RW in the window, in partly committed views, runs of ≥ 1 MiB | 938 (1,535 committed) | `rw>=1M-part` |
| Guest RW in the window, runs under 1 MiB | 40 | `rw<1M`, `rw<1M-part` |
| Guest RW outside the window (FEX's band at 0x7c00000000) | 473 (3,413 committed) | `out-rw`; `[phys-map] fex=498` |
| Guest images | 132 | `image` |
| Guest exec, write-watched, other protections, sections | 0 | |
| JIT pool (RX and RW are one object) | 512 | `[phys-map] poolRX/poolRW` |
| Host: Wine, FEX, Metal's and the app's heaps, page tables and the rest | about 820 | the remainder; `hostlow` and `pa` private dirty 280, malloc zones 166 used |
| **Pool-backed guest memory (not charged)** | 582 (704 committed) | `pool` |

The app's ledger at the same time was `internal` 4,772 MB and `compressed`
1,303 MB.

**Guest commits by load end** (MiB / calls):

| backed | under 1 MiB | outside the window | not RW | already committed | refused |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 35,840 / 16,320 | **8,705 / 112,232** | 10,223 / 8,393 | 0 / 5 | 0 / 0 | 0 / 0 |

**Reading.** About 3.4 GB of the footprint is ordinary guest RW memory in the
0148 window, in views whose runs are 1 MiB or more.

- 0148 does not back those views because Kingdom Come fills them with
  commits under 1 MiB. Those were 112,232 commits by the load's end, about
  80 KiB each, all fresh RW commits in plain VirtualAlloc views.
- The pool held only its ~700 MiB of large commits.
- Exec, write-watched, re-committed and non-RW memory are close to 0. These
  are 0148's other exclusions.
- The FEX band outside the window is committed in large pieces, but little of
  it is touched (473 MiB).
- The GPU's 1.6 GB is the next part. Step 5 is what would move it.

## 2. What changed (madeira-unix 0150, the pool)

**madeira-unix 0150 offers the host every fresh RW commit that holds a whole
host page.** The 1 MiB threshold is gone. The other rules are 0148's:

- only plain VirtualAlloc views in `[0x7000000000, 0x7c00000000)`;
- never write-watched, exec, guard or write-copy pages;
- never a commit with a page already committed;
- the host-page remainder at either end stays ordinary;
- detach to ordinary memory before any protection other than RW;
- every range Wine stops using is reported.

**0148's interval table was replaced by a page bitmap.** The table was
scanned linearly on every unmap, decommit and protection change, which is too
slow with tens of thousands of small ranges. The bitmap has one bit per
16 KiB page of the window: 384 KiB of zero-fill BSS. A release looks only at
its own range, and reports each run of backed pages, at most 64 MiB at a
time. A detach copies at most 64 MiB through its temporary buffer.

**The pool (`guest_pool.c`)** keeps a guest page table in place of its linear
lease list. The table has one `uint32_t` per page of the window (12 MiB,
`calloc`, zero-fill).

- A release costs the pages of its own range.
- A take refuses a guest page that is already leased or outside the table.
- Best fit ends at the first exact fit. The result is the same: the first
  exact fit is the lowest one.
- The stats line drops `leases=` and adds the time spent in the hooks:
  `back_ms_total`, `back_us_max`, `releases`, `release_ms_total` and
  `release_us_max`.

**Host tests:**

- `tools/tests/test_guest_memory.py` builds 0150's `pp_guest_pages.h` from
  the patch. It checks marking, clearing, runs and clipping at both ends of
  the window against a page model, over 200 seeds.
- `app/tests/guest_pool_test.c` adds:
  - refusals outside the table and of a page that is already leased;
  - lookup;
  - a release that reaches past the table;
  - the whole pool as one-page leases, freed in scattered order and taken
    again;
  - a double lease attempted in the random test.
- The checks were tried against broken code (mutation tests). A release that
  keeps the page entry fails the test, and so does a take that does not
  check for a lease. Wrong rounding and wrong run starts in the bitmap fail
  the Python test.

## 3. The pair on `b3cdca61`

Session 17:15–17:29: KCD with the pool off, 120 s rest, KCD with the pool
asked 6144, 120 s rest, Hollow Knight with 4096, then status and kill. The
pool run had `cap_mb=4864` (level 58 %), 4864 MiB in 19 objects from one
donor, installed in 0.71 s.

| Measurement | KCD, pool off (`kcd-widen-off`) | KCD, pool asked 6144 (`kcd-widen-6144`) |
| --- | ---: | ---: |
| Game started / first frame | +5.42 s / +27.37 s | +3.97 s / +26.05 s |
| Menu read, A on Continue | 17:17:29, 17:17:33 | 17:24:00, 17:24:04 |
| Thermal | nominal → fair at about +55 s | nominal → fair at about +30 s → serious at about +60 s |
| Peak `[xp] fpMB` | **7,682** (at +211.6 s) | **3,884** (at +215.2 s), **−3,798** |
| `fpMB` at +110 / +170 / +230 | 5,924 / 7,407 / 7,541 | 3,239 / 3,700 / 3,797 (−2,685 / −3,707 / −3,744) |
| End | `until first-frame+205`, `ok: true`, exit 0 | the same |
| `c0000005`, crash, jetsam | none | none |

**Screenshots** (they stay in the run directories):

- **Both runs** loaded at Rattay's arcaded square, with compass and health
  bar. The off run showed a woman in blue walking. The pool run showed her
  standing, with the horse's head.
- **At the stop,** the pool run showed the square from the other side:
  timber houses, market stalls, NPCs, and a man kneeling in the road.
- Neither run showed visual damage, garbage textures or stripes.

### The pool over time (6144 run)

| Stats line | served | served_mb | live_mb | stale_mb | resident_mb | compressed_mb | refused | back_ms_total | back_us_max | releases | release_ms_total | app_footprint_mb |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| first frame | 11,384 | 2,665 | 1,214 | 4 | 1,033 | 0 | 0 | 113 | 460 | 4,084 | 0 | 2,007 |
| first frame+8 s | 15,084 | 3,537 | 1,381 | 0 | 1,221 | 0 | 0 | 164 | 729 | 6,340 | 0 | 2,126 |
| install+60 s | 26,722 | 6,899 | 1,904 | 1 | 1,736 | 0 | 0 | 351 | 3,348 | 12,683 | 0 | 2,064 |
| install+90 s | 45,134 | 10,634 | 2,385 | 255 | 2,478 | 0 | 0 | 615 | 4,145 | 21,986 | 1 | 2,237 |
| install+120 s | 54,089 | 15,250 | 3,107 | 159 | 2,451 | 574 | 0 | 1,096 | 4,145 | 24,082 | 3 | 3,226 |
| install+150 s | 65,380 | 25,614 | 3,908 | 86 | 2,975 | 856 | 0 | 2,179 | 10,610 | 29,038 | 10 | 3,687 |
| install+180 s | 67,649 | 28,369 | 4,076 | 42 | 3,129 | 821 | 0 | 2,538 | 10,610 | 30,471 | 13 | 3,800 |
| install+210 s | 71,128 | 34,874 | 4,123 | 99 | 3,255 | 810 | 0 | 3,362 | 10,610 | 33,683 | 17 | 3,774 |
| install+240 s | 75,031 | 42,531 | 4,150 | 84 | 3,270 | 805 | 0 | 4,355 | 10,610 | 37,464 | 22 | 3,788 |

The following were 0 in every line: detaches, detached_mb, retired, refused,
`unmatched_mb`, map_failures and purges_pending. The log has no "not
leased", "map … failed" or "preserved … in ordinary backing" line.

- **Purges ran.** 22 whole-object purges (`resets`) in 2 ms in total. This
  is the deferred purge path's first use on the phone.
- **Zeroing:** 38,009 MiB of stale pages in 3,807 ms, at most 10.6 ms for
  one take.
- **Time in the backing hook:** 4.36 s over the 240 s (about 1.8 %), at most
  10.6 ms for one call. This includes the `vm_map` and the zeroing, and runs
  on Wine's thread under `virtual_mutex`.
- **Time in the release hook:** 22 ms for 37,464 releases, at most 1.1 ms.

**The census at install+240 s** shows that 0150 moved the class it aimed at.

| Class | Committed (MiB) | Footprint (MiB) |
| --- | ---: | ---: |
| pool (not charged) | 4,150 | 3,996 |
| RW in the window, runs of ≥ 1 MiB (full views) | 3,340 | **5** (2,417 on `91861df5`) |
| RW in the window, runs of ≥ 1 MiB (partly committed views) | 1,491 | **17** (938 before) |
| RW outside the window (FEX band) | 3,027 | 957 |
| images | 177 | 105 |

Commits since start: 75,017 backed (42,531 MiB) and 54,020 host-page
remainders (216 MiB). Outside the window: 7,464 MiB in 7,053 commits. Under
1 MiB not backed, re-committed and refused: 0. Not RW: 2.

The ledger at the end was `phys` 3,805 MB, `graphics` 1,552 MB,
`internal` 4,682 MB and `compressed` 1,728 MB. `internal` plus
`compressed` exceeds `phys` by far more than the graphics part. This
suggests, without proof, that the mapped pool pages count in those two
ledgers but not in `phys_footprint`. In the off run:
`phys` 7,582 MB, `graphics` 1,552 MB, `internal` 4,766 MB and `compressed`
1,429 MB.

## Hollow Knight (pool 4096), `hk-widen-4096`

The run reached `until first-frame+10`, `ok: true`.

- **First frame:** +11.87 s. Earlier runs: +11.29 s on `91861df5`, +10.52 s
  on `2010a999`, +9.98–10.55 s before that.
- **Stats at first frame+8 s:**
  - 981 requests served (56 before the change), 503 MiB served, 457 MiB live;
  - `back_ms_total` 9, at most 0.4 ms;
  - refused 0, unmatched 0, detaches 0.
- **Peak `[xp] fpMB`:** 2,357 (2,453 on `2010a999`).
- **Exceptions:** the same 14 `c0000005` log lines as in every earlier
  Hollow Knight run (the start-up first-chance exceptions).
- **Screenshot:** the title menu.

Its first frame is the slowest of these runs, by 0.6 s against `91861df5`.
One run cannot separate that from noise.

## Result

- **Peak clearly lower than −582 MiB against off: passed.** The peak was
  −3,798 MiB (7,682 off, 3,884 on). It was −3,707 and −3,744 at +170 and
  +230.
- **Rattay loaded, no crash: passed** in both runs. There were no `c0000005`
  in Kingdom Come and no crash reports or jetsam.
- **Unmatched 0, detaches handled: passed.** Unmatched 0 and map failures 0.
  No detach happened: Kingdom Come makes only 2 non-RW commits. The detach
  path is still unexercised on the phone.
- **Physical memory.** The phone carried a 4.1 GiB live pool plus a 3.8 GB
  app, with up to 805 MiB of pool pages compressed, and nothing was ended.

## Limits

- **One pair, with a thermal difference.** The pool run reached "serious" at
  about +60 s; the off run stayed "fair". Frame rate was not measured.
- **The off/on gap is near the pool's live set (4.15 GiB).** The game's
  memory moved out of the app's charge. It did not shrink. Physical RAM, and
  the jetsam level the pool is capped by, are the next wall.
- **Hook cost** is 1.8 % of the run on Wine's thread. A `pp perf` A/B
  (queue item 2) is needed before calling it free.
- **What is left in the app's footprint** (3.8 GB): GPU 1.55 GB, the JIT
  pool 512 MiB, the FEX band about 1 GB, and the host.

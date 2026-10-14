# A donor pool at Play behind madeira-unix 0148: Hollow Knight unchanged

**Date:** 2026-10-14. Branch `research/extended-memory`, commit `25f484d`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Plan:** [donor memory, step 3](../plans/2026-10-12-donor-memory.md#3-a-pool-at-play-that-feeds-0127).
**IPA:** `Playport-26.5-d8226b20.ipa` (dev, entitled build), SHA256
`d8226b2012621e7142426f06ddda3eb46ad699d24ea096abd90afaaa4a62dd57`, installed
in place. iPhone18,4, iOS 27.0.1, 11734 MiB physical RAM, on power. Every run
below is on that IPA in one locked session (each run's `result` event names
it).

## What step 3 built

- **Setting.** Settings › Developer › Memory › Donor pool (experiment): Off
  (the default), 2, 4 or 6 GiB, for the next Play. The driver sets it with
  `set:donorPoolMB=0|2048|4096|6144` (decision 0012). Release builds have
  no setting and keep the stubs that answer every hook "no".
- **When.** `WineHostRuntime.start`, after the JIT pool is blessed and checked
  and before `wine_host_init` (where the removed broker started). The JIT
  helper has already ended by then.
- **Size.** The pool asks for `min(setting, cap)`, where
  `cap = (kern.memorystatus_level − 15) % × physical RAM`, rounded down to
  256 MiB. That is the step-2 stop rule (15 %) applied to what jetsam says is
  free now. The pool's pages are not touched here, so the rounds themselves
  move no level. The log line `donor-pool: asked_mb=… cap_mb=… target_mb=…`
  records it.
- **Donors.** The step-2 rounds (`SharedMemoryProbe.donorRounds`), now with a
  `touch` switch. Each round starts a fresh helper and takes purgeable
  256 MiB objects up to its available memory less 512 MiB. The objects are
  not written. The donor is then ended, and the app waits until
  `kill(pid, 0)` gives `ESRCH`. If a donor does not end, no pool is installed.
  Any failure logs and leaves the Play on ordinary memory.
- **Option (a), chosen.** The app keeps only the memory entries' send rights
  and maps no pool-wide view. Each 0148 request (a fresh RW commit of 1 MiB to
  64 MiB, host-page aligned, in `[0x7000000000, 0x7c00000000)`) is served by
  `vm_map(VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE)` of an unused range of one
  object, at Wine's address (`SharedMemory/GuestPool.m`). Why (a):
  - step 2 showed physical RAM is the wall, so untouched pool pages must
    stay unresident, and (a) never touches them;
  - (b)'s pool-wide view would add a second mapping of every page for no
    gain;
  - the probe below shows a page first touched by the app after its donor
    died is charged to no one.
- **Zero on reuse: purge whole objects; no reuse inside a partly used
  object.** Each object is handed out from its start upwards, never twice.
  When the last lease in an object is released, the object is purged:
  `VM_PURGABLE_EMPTY`, then non-volatile again, through a temporary view. Its
  bump pointer then goes back to 0. If the purge fails, the object is
  retired. So every range served has either never been touched or has just
  been purged. The bookkeeping (`SharedMemory/guest_pool.c`) is plain C,
  tested on the host by `app/tests/guest_pool_test.c` (`pp test`'s
  "C test guest pool", with ASan and UBSan). The test runs random takes and
  releases against a page model and checks that:
  - a served page is never a dirty one;
  - no pool page backs two guest pages;
  - a guest page keeps its pool page through prefix, suffix and middle
    splits;
  - the lease bound holds.
- **Lifetime.** A release is bookkeeping under a lock, with no IPC. 0148 now
  reports `(address, size, detached)` for every tracked range Wine stops
  using: unmap, decommit, or a copy to ordinary memory before a protection
  other than RW. Detaches are counted and logged (`donor-pool: detach #N`).
  The pool's counters, its resident pages and the app's footprint are logged
  at the first frame and 8 s later (`donor-pool: stats at …`).
- **Limits.** 0148's interval table is now bounded by 8 GiB (32 objects of
  256 MiB, the pool's own maximum) on 16 KiB host pages, which is still
  524288 entries. Wine backs nothing on smaller host pages. The host test of
  the shipped header (`tools/tests/test_guest_memory.py`) checks the new
  bound.
- **FEX data band (0147): removed from the series.** Its hook had no release
  notification, so a pool could not tell when a served range was free, and
  serving it would leak pool memory. Earlier it moved only 30–90 MiB
  ([evidence](2026-10-03-fex-helper-memory.md)). 0148 keeps its number.
- **Out of scope, unchanged.** The JIT pool, executable memory, images and
  reservations stay ordinary.

## Zeroing measurement (`probe:memory-pool-zero`, run `pool-zero`)

One donor gave four untouched 256 MiB purgeable objects and ended. Values are
for one 256 MiB object.

| Step | Result |
| --- | --- |
| All four objects after the donor ended | resident 0 MiB each, app footprint 54 MiB |
| First touch by the app after the donor died (fill) | 70 ms; **app footprint +0 MiB**; object resident 256 MiB |
| `memset(0)` of the touched object | **12.1 ms**; reads zero; still **256 MiB resident** |
| Purge (EMPTY, then non-volatile) of a touched object | **8.4 ms**, kr 0; resident 0 MiB after; reads zero; state non-volatile |
| Touching the purged object again | **app footprint +0 MiB** (the purge does not move the charge to the app) |
| Purge of an untouched object | 0.02 ms, reads zero |
| `vm_map` FIXED\|OVERWRITE of 64 MiB at offset 64 MiB over an ordinary reservation | mapped; writes appear at that offset of the object; the rest of the object reads zero |

```
memory-broker: pool-zero RESULT PASS chunk_mb=256 touch_delta_mb=0 memset_ms=12.10 purge_ms=8.43 retouch_delta_mb=0 ...
```

The choice was purge, not memset. Both are fast enough to run on a release
under Wine's lock. Only the purge also gives the pages back to the phone,
and step 2 showed physical RAM is what runs out. A memset would leave freed
guest memory resident. Not reusing at all ("monotonic") would run a 4 GiB
pool dry within minutes in a game that allocates and frees repeatedly. A
partly used object is not reused, which is the price of purging whole
objects: its freed ranges stay resident until its last lease goes.

## Hollow Knight, pool off and on

`pp ui --action set:donorPoolMB=<0|4096> --play app-367520 --until first-frame+10 --shot`,
back to back in the same session. Times are from the Play.

| Run | Pool | JIT acquire | Runtime started | Game started | **First frame** | Footprint at end (peak) |
| --- | --- | --- | --- | --- | --- | --- |
| `hk-pool-off` | Off | 2.35 s | +3.58 s | +3.79 s | **+10.24 s** | 2708 MB (2788) |
| `hk-pool-4096` | 4096 MiB | 2.42 s | +4.35 s | +4.55 s | **+9.98 s** | 2365 MB (2438) |

Earlier smoke runs on step-1 and step-2 IPAs reached first frame at +10.71 s
and +10.56 s. **The first frame with the pool on is within that noise.** The
pool costs about 0.75 s before the runtime starts: one donor started, sixteen
objects, the donor ended, `installed … in 0.72 s`. The game itself reached
its first frame sooner after starting (5.4 s against 6.5 s); one run each,
so that is not a result.

Pool-on details (from `hk-pool-4096`'s `s1-host.log`):

```
donor-pool: asked_mb=4096 cap_mb=4352 (level 53% less 15% of 11734 MiB) target_mb=4096 ...
donor-pool: donors round=1 donor_pid=8083 granted_mb=4096 total_mb=4096 gone=true kill0_errno=3 after_ms=105 ...
donor-pool: installed granted_mb=4096 objects=16 donors=1 stop="target reached" in 0.72 s ...
donor-pool: stats at first frame: pool_mb=4096 served=52 served_mb=356 live_mb=309 resident_mb=242 compressed_mb=0 leases=48 released_mb=46 detaches=0 detached_mb=0 resets=0 retired=0 refused=0 unmatched_mb=0 map_failures=0 purge_ms_total=0 purge_ms_max=0 app_footprint_mb=2152 app_available_mb=6039
donor-pool: stats at first frame+8s: pool_mb=4096 served=56 served_mb=400 live_mb=353 resident_mb=286 compressed_mb=0 leases=52 released_mb=46 detaches=0 ... app_footprint_mb=2266 app_available_mb=5925
```

- **Pool:** 4096 MiB granted (cap 4352) from **one donor**, 16 objects.
- **Served from the pool:**
  - by the first frame, 52 requests (356 MiB), 242 MiB of it resident;
  - 8 s later, 56 requests (400 MiB), 286 MiB resident, 353 MiB live;
  - 46 MiB released;
  - no refusals, no map failures, no unmatched releases.
- **Detaches: 0. Resets (purges): 0** in this run. No object emptied, and no
  served range had its protection changed. Every served range was in the
  heap band (`0x7036e70000…0x7540000000`); `[helper-guest] fresh` lines
  match the `served` lines one for one.
- **Footprint:** 2152 MiB at the first frame. At the end of the run the app's
  footprint was 2365 MB with the pool (peak 2438), against 2708 MB (peak
  2788) without it: **343 MB lower**, about what the pool held resident
  (286 MiB) plus run-to-run noise. The app's available memory plus its
  footprint stayed at the 8 GiB limit. The pool's resident pages count
  against no process, as steps 1 and 2 found.
- The screenshot at the stop shows Hollow Knight's title menu (Start Game
  highlighted) under the on-screen controller in both runs.

## Caveats

- One run each, Hollow Knight to first frame + 10 s only. That exercises
  serving and partial releases. It does not exercise detaches, purges of a
  freed object, or reuse, which the host test covers but no phone run has
  yet. Kingdom Come (step 4) and a DRM/self-modifying title (the PLA-203
  family) are the real tests of the detach and release paths.
- A partly used object never gives back its freed ranges until it empties:
  a game that keeps one small long-lived allocation in each object could
  hold freed memory resident, up to the pool's size.
- The cap reads jetsam's level once, at Play. The game's own ordinary memory
  grows later out of the same physical RAM.
- `pp check --variant release` compiles the release app with the stubs; no
  release IPA was built or verified in this step.

Run directories are under `.work/agent-notes/donor-memory/runs/`
(`pool-zero`, `hk-pool-off`, `hk-pool-4096`). The session script and its log
are `step3-session.sh` and `step3-session.log`.

# Donor memory at scale: physical RAM, not the app's limit, is the wall

**Date:** 2026-10-14. Branch `research/extended-memory`, commit `9552b8b`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Plan:** [donor memory, step 2](../plans/finished.md#guest-ram-from-donor-processes)
(entitled builds only; the unentitled part is deferred by the owner).
**IPA:** `Playport-26.5-fc107a8d.ipa` (dev, entitled build), SHA256
`fc107a8d9d9b5b98600e0bd050e198f4058160bd22b3961916ef23b6350eb9a1`, installed
in place. iPhone18,4, iOS 27.0.1, 11.7 GiB physical RAM, one phone, on power.
Every run below is on that IPA in one locked session (each run's `result`
event names it).

## Probe

Settings › Developer › Probes has a row per total and one to verify the
held pool; the driver actions are `probe:memory-donors-6144|8192|10240`,
`probe:memory-pool-verify` and `background:S`
(`app/Sources/S1Probe/Dev/SharedMemoryProbe.swift`, `measureDonors`).

1. **Rounds.** Each round starts the JIT helper (an app extension; every
   round's pid was new), reads its `os_proc_available_memory()`, and asks
   for that less 512 MiB, rounded down to 256 MiB and capped at what the
   total still needs. The helper makes purgeable objects (set non-volatile)
   of 256 MiB; the app maps each one, fills it with SplitMix64 words and
   verifies it. Then the app ends the helper (`JitHelper.stop()`) and
   waits for `kill(pid, 0)` to fail with `ESRCH`.
2. **Stop rule (chosen to stay well short of jetsam).** Before each object,
   the phone must have `kern.memorystatus_level` (jetsam's percent of
   memory available) at least 15 %, free + inactive + speculative +
   purgeable at least 1536 MiB, and no pressure warning. The probe stops
   there, records why, and fails if the total was not reached.
   (`kern.memorystatus_vm_pressure_level` is not readable from the app: −1.)
3. **60 s after the last donor died,** every byte is read (point
   `donors_dead_60s`).
4. **The app's own limit with the pool held:** ordinary app memory
   (`vm_allocate`, every byte written with incompressible words), 256 MiB at
   a time, while the app's available memory stays above 768 MiB and the
   stop rule holds; then it is freed and the pool read again
   (`donors_after_app_limit`).
5. The pool stays mapped. `background:S` opens iOS Settings (Playport goes
   to the background); `pp ui` waits S seconds, checks the app's process is
   still the one that left, and brings it back with a launch that does not
   end it (`dvt launch --no-kill-existing`). `probe:memory-pool-verify`
   then reads the pool again.

Each line logs the app's `phys_footprint`, `os_proc_available_memory()`,
the objects' summed page counts (resident / swapped, the latter being pages
in the compressor), and the phone's `host_statistics64` counts. A point's
page counts are read before its full read, its system counts after it.

## Results

Values in MiB. "Level" is `kern.memorystatus_level` after the round.

### Donor rounds

| Run | Round | Donor pid (new) | Donor available | Asked | Granted | Total | Gone after | App footprint | App available | Sys free | Level |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| donors-6144 | start | | | | | 0 | | 78 | 8114 | 2237 | 47 |
| donors-6144 | 1 | 7813 (yes) | 6137 | 5376 | 5376 | 5376 | 105 ms | 63 | 8128 | 110 | 17 |
| donors-6144 | 2 | 7816 (yes) | 6137 | 768 | 768 | 6144 | 105 ms | 65 | 8126 | 204 | 17 |
| donors-8192 | start | | | | | 0 | | 76 | 8116 | 6425 | 67 |
| donors-8192 | 1 | 7844 (yes) | 6137 | 5376 | 5376 | 5376 | 105 ms | 56 | 8135 | 1554 | 21 |
| donors-8192 | 2 | 7845 (yes) | 6137 | 2816 | 1024 | 6400 | 105 ms | 55 | 8136 | 157 | 13 |
| pressure-6144 | start | | | | | 0 | | 77 | 8115 | 6506 | 67 |
| pressure-6144 | 1 | 7866 (yes) | 6137 | 5376 | 5376 | 5376 | 105 ms | 56 | 8135 | 1134 | 21 |
| pressure-6144 | 2 | 7867 (yes) | 6137 | 768 | 768 | 6144 | 101 ms | 55 | 8136 | 401 | 15 |

Every donor had the same budget (6137 MiB available, 6 MiB footprint),
started as a new process, and was gone about 100 ms after the stop
(`kill0_errno=3`). The donors-8192 run stopped in round 2 at 1024 MiB of
the 2816 asked, by the stop rule:

```
memory-broker: allocation stopped at 1024 MiB: memorystatus level 13% < 15%
memory-broker: donors RESULT FAIL target_mb=8192 total_mb=6400 donors=2 verify_60s=true verify_after_app_limit=true app_ordinary_mb=0 stop="donor 2: Allocated 1024 MiB; stopped: memorystatus level 13% < 15%" app_stop="memorystatus level 13% < 15%"
```

The 10240 MiB run was not made (the session stopped at the first failing
total).

### The pool after the donors, and the app's remaining room

| Run | Pool | Verify at 60 s | Resident / in compressor at 60 s | App footprint | App available | App could still take | Stopped by | Verify after |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| donors-6144 | 6144 | true | 4450 / 1694 | 55 | 8137 | 768 | level 13 % | true |
| donors-8192 | 6400 | true | 6400 / 0 | 52 | 8140 | 0 | level 13 % | true |
| pressure-6144 | 6144 | true | 6144 / 0 | 52 | 8140 | 256 | level 13 % | true |

```
memory-broker: donors RESULT PASS target_mb=6144 total_mb=6144 donors=2 verify_60s=true verify_after_app_limit=true app_ordinary_mb=768 stop="target reached" app_stop="memorystatus level 13% < 15%"
```

In the first run the phone started with less free memory (level 47 %), and
by the 60 s point iOS had put 1694 MiB of the pool's pages in the
compressor (`swapped`; the app's `task_vm_info.compressed` showed 1705 MiB
while its footprint stayed 55 MiB). The full read brought them back: after
the app-limit step 6143 MiB were resident again and 0.7 MiB compressed.
`swapouts` did not change in any run (no swap file).

### Background and return (run `pressure-6144`)

With the 6144 MiB pool mapped and the donors dead, `background:60`:

- The app opened iOS Settings at `t=…262.79`. 60 s later the app's process
  was still pid 7863; `pp ui` brought it back (`background-return`:
  `alive=true pid_after=7863 same_process=true`), and the app logged
  `background: in front again after 63 s`. iOS did not end it.
- `probe:memory-pool-verify` right after: **every byte verified**; 6143.9
  MiB resident, 0.1 MiB in the compressor; app footprint 52 MiB.
- Phone counters across the background minute: compressions +7429,
  decompressions +7615, swapins +320, swapouts unchanged; level 15 % after.
- **App available memory read 6092 MiB right after the return**, against
  8140 MiB before it left, with the same footprint. The app's limit
  appeared to be about 6 GiB, not 8, within a second of coming back. Not
  explained here (a limit restored late after the background, or a lower
  limit for a returning app); it matters to any design that relies on the
  8 GiB limit after a background trip.

```
memory-broker: donors pool_verify total_mb=6144 verified=true sys_kr=0 sys_free_mb=524 ... sys_swapins=206833 sys_swapouts=286877 sys_level=15 sys_pressure=-1
```

The screenshot at the stop shows Playport's own Settings › Developer in
front (Logs section), that is, the app is back.

## Verdict

- **Largest verified total: 6400 MiB** (two donors; all of it verified 60 s
  after the last donor died and again after the app-limit step). The
  largest total that reached its target was **6144 MiB** (twice).
- **Several donors work:** each round is a fresh helper process with its own
  ~6 GiB budget, and its memory stays with the app after it ends, as H1
  found for one donor.
- **Physical RAM is the wall, not the app's limit.** With the pool held,
  the app's own `os_proc_available_memory()` stayed about 8.1 GiB (the
  pool counts against no process), but the phone ran out first: on an idle
  phone (level 67 %) about 6.4 GiB of pool brought jetsam's level to 13 %,
  and the app could then take only 0–768 MiB of ordinary memory before
  the stop rule. One level point was about 118 MiB, so 100 % ≈ 11.6 GiB,
  the phone's RAM. Pool plus the app's extra memory came to 6400–6912 MiB,
  roughly what was available at the start less the stop rule's 1.5 GiB
  reserve.
- **System pressure:** a minute in the background with 6 GiB mapped did
  not end the app, and the pool's data survived intact.

What this means for the plan: on the entitled reference phone, donor
memory takes the guest's heap out of the 8 GiB per-process limit, but it
does not add memory the phone lacks. A game whose app footprint plus pool
stays under what is free (about 7–8 GiB on an idle phone, more if jetsam
ends background apps) gains; the sum cannot exceed physical RAM. Untouched
pool pages must stay unresident, so they cost nothing until used.

## Hollow Knight smoke (run dir `hk-smoke-step2`)

`pp ui --play app-367520 --until first-frame+10 --shot` on the same IPA, at
the end of the same locked session: built-in JIT `acquire(512 MiB) -> 0`
after 2.47 s, runtime started at +3.77 s, game at +3.97 s, **first frame
at +10.56 s**, `until_reached` true. The screenshot shows Hollow Knight's
title menu (Start Game highlighted) under the on-screen controller. The
probe code is dev-only and not on the play path.

## Caveats

- One phone, an entitled dev build, one run per total; the stop rule
  (level ≥ 15 %, ≥ 1.5 GiB spare) is a conservative choice, so the true
  ceiling before jetsam is somewhat higher than 6400 MiB. Background apps
  that jetsam would end to make room were not counted.
- Only the purgeable variant was run at scale (tagged objects were not).
- The pool was filled with incompressible data: every page resident. A
  real guest heap is partly untouched and partly compressible.
- The 6 GiB limit read after the return from the background is one
  reading, right after the return; nothing here shows whether it recovers.
- No unentitled build (deferred by the owner), no game using the pool.

Run directories are under `.work/agent-notes/donor-memory/runs/`
(`donors-6144`, `donors-8192`, `pressure-6144`, `hk-smoke-step2`; the
session script and log are `step2-session.sh` and `step2-session.log`).

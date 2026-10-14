# Donor memory: the pages stay mapped and count against no one after the helper ends (H1)

**Date:** 2026-10-14. Branch `research/extended-memory`, commit `0534342`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Plan:** [donor memory, step 1](../plans/2026-10-12-donor-memory.md#1-does-the-memory-stay-free-after-the-donor-dies-h1).
**IPA:** `Playport-26.5-19e10116.ipa` (dev, entitled build), SHA256
`19e101160b76d98838ccf85003ab71d2a85208b2d23a78a1bd4eed2d67defdb6`, installed
in place. iPhone18,4, iOS 27.0.1, one phone. Every run below is on that IPA
(each run's `result` event names it).

## Probe

Settings › Developer › Probes has a row per variant and size; the driver
actions are `probe:memory-donor-tagged-2048`, `probe:memory-donor-tagged-4096`,
`probe:memory-donor-purgeable-2048` and `probe:memory-donor-purgeable-4096`
(`app/Sources/S1Probe/Dev/SharedMemoryProbe.swift`, `runDonor`).

1. The app starts the JIT helper (an app extension) and records a point
   `before`.
2. The helper allocates N MiB in 64 MiB objects and sends each as a Mach
   memory entry over XPC:
   - **tagged:** `mach_make_memory_entry_64(MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED)`;
   - **purgeable:** `vm_allocate(VM_FLAGS_PURGABLE)`, set non-volatile, a
     memory entry naming that object (no copy), then the helper's own mapping
     is dropped.
3. The app maps every object, fills it with SplitMix64 words and verifies it
   (point `after_map`). The helper maps and verifies every byte too
   (`helper before_stop`).
4. The app ends the helper with `JitHelper.stop()` and polls `kill(pid, 0)`
   until it fails with `ESRCH`. The app keeps its mappings.
5. Points `dead_5s` and `dead_60s` are taken 5 s and 60 s after the stop.

Each point logs the app's `task_vm_info` (`phys_footprint`, resident,
compressed), `os_proc_available_memory()`, the summed
`mach_memory_entry_get_page_counts` of all objects, the purgeable state of the
first object (0 = non-volatile; −1004 = `KERN_INVALID_ARGUMENT`, the tagged
object is not purgeable), and a full read verifying every byte.

**Pass** (the plan's rule): the helper is gone, the data verifies at 60 s, and
the app's footprint at `dead_60s` minus at `after_map` is under 10 % of the
mapped size.

## Results

Values in MiB (2^20 bytes). Pages are resident / dirty / swapped.

### tagged 2048 MiB (run dir `tagged-2048`)

| Point | Footprint | Resident | Compressed | Available | Verify | Pages |
| --- | --- | --- | --- | --- | --- | --- |
| before | 94.8 | 160 | 0 | 8097 | true | 0 / 0 / 0 |
| after_map | 111.1 | 2274 | 0 | 8081 | true | 2048 / 2048 / 0 |
| dead_5s | 105.1 | 2281 | 0 | 8087 | true | 2048 / 2048 / 0 |
| dead_60s | 68.5 | 2285 | 0 | 8123 | true | 2048 / 2048 / 0 |

Helper: footprint 6.5 at its baseline, 2057.2 before the stop. Gone after
103 ms (`kill0_errno=3`). `H1 PASS`, `grown_60s=-44646400` (−43 MiB).

### purgeable 2048 MiB (run dir `purgeable-2048`)

| Point | Footprint | Resident | Compressed | Available | Verify | Pages |
| --- | --- | --- | --- | --- | --- | --- |
| before | 95.4 | 158 | 0 | 8097 | true | 0 / 0 / 0 |
| after_map | 93.1 | 2247 | 0 | 8099 | true | 2048 / 2048 / 0 |
| dead_5s | 89.2 | 2255 | 0 | 8103 | true | 2048 / 2048 / 0 |
| dead_60s | 66.3 | 2269 | 0 | 8126 | true | 2048 / 2048 / 0 |

Helper: footprint 6.4 → 2057.1. Gone after 104 ms (`kill0_errno=3`).
`H1 PASS`, `grown_60s=-28065792` (−27 MiB). Purgeable state 0
(non-volatile) throughout.

### tagged 4096 MiB (run dir `tagged-4096`)

| Point | Footprint | Resident | Compressed | Available | Verify | Pages |
| --- | --- | --- | --- | --- | --- | --- |
| before | 98.5 | 161 | 0 | 8093 | true | 0 / 0 / 0 |
| after_map | 104.3 | 3662 | 639 | 8088 | true | 3461 / 3461 / 634 |
| dead_5s | 89.3 | 4305 | 5 | 8103 | true | 4096 / 4096 / 0 |
| dead_60s | 77.9 | 4324 | 5 | 8114 | true | 4096 / 4096 / 0 |

Helper: footprint 6.5 → 4106.4 (its available fell from 6138 to 2038). Gone
after 101 ms (`kill0_errno=3`). `H1 PASS`, `grown_60s=-27607040` (−27 MiB).
At `after_map` 634 MiB of the objects were compressed; the helper's full read
before the stop brought them back, and they stayed resident after it died.

### purgeable 4096 MiB (run dir `purgeable-4096b`)

| Point | Footprint | Resident | Compressed | Available | Verify | Pages |
| --- | --- | --- | --- | --- | --- | --- |
| before | 75.7 | 138 | 0 | 8116 | true | 0 / 0 / 0 |
| after_map | 55.8 | 4242 | 0 | 8136 | true | 4096 / 4096 / 0 |
| dead_5s | 54.4 | 4243 | 0 | 8138 | true | 4096 / 4096 / 0 |
| dead_60s | 50.4 | 4244 | 0 | 8142 | true | 4096 / 4096 / 0 |

Helper: footprint 6.4 → 4106.3 (available 6138 → 2038). Gone after 105 ms
(`kill0_errno=3`). From the pulled `s1-host.log`:

```
memory-broker: donor helper_stopped pid=7669 gone=true kill0_errno=3 after_ms=105
memory-broker: donor H1 PASS variant=purgeable mapped_mb=4096 helper_gone=true footprint_after_map=58496056 footprint_5s=57087032 footprint_60s=52876344 grown_60s=-5619712 limit_10pct=429496729 verify_5s=true verify_60s=true
```

An earlier purgeable-4096 attempt was stopped mid-run and has no result; it
is not counted.

The screenshot at the end of each probe run shows Settings › Developer
scrolled to its Logs section (the probe's status line is in the log, not
on that screen).

## Verdict

**H1 holds on this phone for both variants at 2048 and 4096 MiB.** The
helper was confirmed dead every time. Every byte verified at 5 s and 60 s
after its death. The app's footprint did not grow (it fell by 5–43 MiB,
ordinary churn), while its resident size included the whole mapping, and
`os_proc_available_memory()` stayed about 8.1 GiB. The dead helper's pages
count against no process's limit, the app's included. The step-1 pass rule
is met, so the plan continues to step 2.

## Hollow Knight smoke (run dir `hk-smoke`)

`pp ui --play app-367520 --until first-frame+10 --shot` on the same IPA,
right after the purgeable-4096 run in the same locked session: built-in JIT
`acquire(512 MiB) -> 0` after 2.40 s, runtime started at +3.69 s, game at
+3.91 s, **first frame at +10.71 s**, `until_reached` true. The screenshot
shows Hollow Knight's title menu (Start Game highlighted) under the on-screen
controller. The probe code is dev-only and not on the play path; this is the
runtime smoke gate, not a test of donor memory in a game.

## Caveats

- One phone (iPhone18,4, iOS 27.0.1), an entitled dev build, one run per
  variant and size.
- `os_proc_available_memory()` is the app's own limit minus its footprint,
  not free system memory. The mapped pages are real resident RAM: no
  system-pressure test was done (another app in front, or a game using the
  same RAM), and no donor beyond the one helper.
- The purgeable objects stayed non-volatile; nothing here shows what iOS does
  with them under pressure, or with disowned tagged objects.
- Not tested: an unentitled build, more than 4096 MiB, several donors, or a
  pool used by a running game. Those are steps 2 and 3 of the plan.

Run directories are under `.work/agent-notes/donor-memory/runs/` (logs and
screenshots stay there).

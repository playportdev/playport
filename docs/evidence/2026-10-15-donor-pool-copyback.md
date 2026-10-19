# Donor pool: the copy-back (detach) path through the `protect` probe

**Date:** 2026-10-15 (06:56–06:58). **Branch:** `research/extended-memory`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes), the detach probe left open by
[the follow-ups](2026-10-15-donor-pool-followups.md).

**Setup:**

- iPhone18,4, iOS 27.0.1, on the charger (100 % at the start and the end), unattended mode on.
- Dev IPA SHA256 `82e1039e6230e83c606f087aa736dae69a831da4c40593be5eaf54062ae0648a`
  (commit `821c0dd`, installed 2026-10-15 02:42). No install in this session: what changed
  here is `pp phone put` (`98a0581`), a workstation command.
- The probe: `tools/compat/probes/protect.c`, built by `tools/compat/probes/build.sh` as
  `protect.exe` (1,130,496 bytes, sha256 prefix `2bc155b69840e963`).

## How it was put on the phone

`pp` had no command to copy a file into the app's container, so the 2026-10-12 procedure
(AFC from a script) had no supported form. `pp phone put LOCAL Documents/Import/NAME/FILE`
(`98a0581`) now does what a person does with Files: it writes one file into the app's import
inbox, under the device lock, and refuses every other path (`..`, another folder, a link, a
directory). The import itself still goes through the UI (decision 0012).

One locked session (`$PLAYPORT_BUILD/agent-notes/donor-memory/runs/copyback-session.sh`, its
`.log` and the run directories under `runs/copyback/`):

1. `pp phone put …/protect.exe Documents/Import/protect/protect.exe`: 1,130,496 bytes. The
   file was still there from 2026-10-12, the same size, and was replaced.
2. `pp ui --action import:Import/protect`: "in the library as `dir-protect` [Ready]
   source=imported … after 0.6 s".
3. `pp ui --action set:donorPoolMB=0|4096 --settings 'dir-protect:{"arguments":"exec-rw"}'
   --play dir-protect --wait 180`, pool off and then 4096. Only `exec-rw` was named, so
   `exec-rw-reuse` (its known alias defect crashes it) did not run.
4. `pp phone kill`.

## What the probe does to the pool

`exec-rw` commits 1 MiB `PAGE_READWRITE` (a fresh RW commit, which madeira-unix 0150 backs
from the pool), writes `mov eax, N; ret` into each 4 KiB page, protects it
`PAGE_EXECUTE_READ`, calls it and protects it back, 4,096 times. The first protect of each
16 KiB host page detaches it: Wine copies the page to ordinary memory before the protection
changes. The call then has to return what was written into pool memory. `data` and `rx` then
flip pages of a second fresh 1 MiB RW commit.

## Result

| | pool off | pool 4096 |
| --- | --- | --- |
| probe | `done ok`, exit 0 after 2 s | `done ok`, exit 0 after 2 s |
| `exec-rw` (µs a round; stale calls, failed protects) | 94.6; 0, 0 | 96.2; 0, 0 |
| `data` / `rx` / `image` (µs a protect) | 12.4 / 18.3 / 18.3 | 12.5 / 18.5 / 18.3 |
| `exec` (µs a round) | 100.3 | 103.9 |
| pool | not installed | 3,584 MiB granted (4096 capped by the level), 14 objects, 0.69 s |
| fresh ranges backed (`[helper-guest] fresh`) | 0 | 16 (8 with a `served` line) |
| detaches (`[helper-guest] preserved`) | 0 | 128 (16 KiB each, `detached_mb=2`) |
| reuses | 0 | 1 (`data`'s commit on `exec-rw`'s released range, zeroed 1,024 KiB in 0.015 ms) |
| map failures (`failed: kr=`), refused, `not leased` | 0, 0, 0 | 0, 0, 0 |
| `c0000005` (`[rtcs] pre` lines; FEX `Handled self-modifying code`) | 64; 40 | 64; 40 |

- **The detach path was exercised and kept the data.** The pool run detached 128 host pages:
  64 of `exec-rw`'s commit (`0x702b2d0000+0x100000`), then 64 of `data`'s commit, which got
  the same range back from the pool (`reuse #1`). The app logs detaches 1–16 and then each
  power of two (`detach #64`, `#128`). Every one of the 4,096 calls into code written to pool
  memory and then copied returned its value (0 stale), and every protect succeeded.
- **No `donor-pool: stats` line was written.** That line comes at the first frame and every
  30 s from the install; the probe draws nothing and ends 2 s after it starts. The counts
  above are the per-event lines (`[helper-guest] preserved`, `donor-pool: detach #N`).
- **The `c0000005` are not the pool's.** All of them, in each run, are in the `exec` phase, on its
  `PAGE_EXECUTE_READWRITE` allocation (`0x702a1d0000` pool off; `0x702b2d0000` pool on, the
  range the earlier phases released, which the pool does not back: no 17th `fresh` line, and
  0150 never backs an executable commit). They are FEX's self-modifying-code trap on a byte
  store into a page it has translated (`[smc-trap] … -> guest access violation`, `Handled
  self-modifying code`, 40 a run), each handled. The count and the faulting instruction are
  the same with the pool off.
- Costs: the per-call figures match with the pool off and on, within 4 %, on one pair.

## Not covered

- Purges (`object N free again`): the probe's two 1 MiB commits never empty a 256 MiB object.
- `exec-rw-reuse` (the known alias defect, 2026-10-12 noexec record) was not run.
- One run each way.

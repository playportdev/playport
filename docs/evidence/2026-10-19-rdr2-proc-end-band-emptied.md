# 2026-10-19: Emptying a parked process's FEX band in place takes ~1 GB off RDR2's footprint at the launcher's end; the game signs in and the launcher ends at sign-in

**Linear:** PLA-416, PLA-413, PLA-364. **Decisions:** 0132 (amends 0127), 0130.

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `c97f4cbc961279372168d24120b2c6a11684f75d14dce4483961bd5792fc3f6f` | 7fb568f | `20261019T215742` | Hollow Knight gate (`--play app-367520 --until first-frame+10 --shot`), right after `pp install --no-build` |
| same | same | `20261019T215954` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+900 --wait 1800`, a screenshot every 60 s from 60 to 900 s and at the stop, device log kept |

- **The build** adds madeira-unix 0172 (decision 0132) to the build of run `20261019T210854`
  ([evidence](2026-10-19-rdr2-khronos-vulkan-loader.md)).
  - A teardown with a parked thread empties the dead process's band views in place.
  - Views a parked thread's saved addresses lie in stay whole.
  - `[proc-end]` logs `emptied=`, the views a register kept, and the footprint before and after.
- **The phone:**
  - before the gate: 69 %, 5.0 GB free;
  - before RDR2: 67 % and not charging, 5.7 GB free;
  - after: 60 %, 5.1 GB free.
- **Nobody pressed anything from the workstation.** PlayRDR2's "Unable to launch game" box (0125)
  was up from +121.80 s to +123.87 s.
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T215742/` and `ui-runs/20261019T215954/`: host logs, events and screenshots;
  - `agent-notes/pla416/rdr2-0172/`: the device log, and the phone's crash list.

## Hollow Knight

First frame at +9.65 s. The JIT pool head is 47 MiB, with no exhaustion. The band peaked at
1,299 MB, `refused=0`.

## RDR2: what the teardowns freed and emptied

| Time | Process | freed (MB) | emptied (MB) | kept (MB) | views kept by a register | parked | footprint (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| launcher's own end | SocialClubHelper 0x334 | image 284, private 2,760, L1 34, pool 40 | 637 | 693 | 1 | 1 | 3,790 → 3,599 |
| same | SocialClubHelper 0x2d4 | image 284, private 3,094, spans 305, callret 64, L1 32, band_other 216, pool 88 | 0 | 45 | 0 | 0 | 3,599 → 3,322 |
| sign-in end, +115.7 s | Launcher.exe 0x70 | image 68, private 92, L1 90, pool 121 | 686 | 824 | 2 | 5 | 6,032 → 5,878 |
| same | RockstarErrorHandler 0x7c | image 17, private 6, L1 16, pool 31 | 180 | 192 | 2 | 1 | 5,878 → 5,863 |
| same | SocialClubHelper 0x1b4 | image 301, private 50, L1 92, pool 170 | 965 | 1,109 | 8 | 11 | 5,863 → 5,454 |
| same | SocialClubHelper 0x284 | image 284, private 3,072, L1 34, pool 152 | 493 | 571 | 1 | 1 | 5,454 → 5,180 |
| same | SocialClubHelper 0x578 | image 284, private 2,991, spans 210, callret 68, L1 32, band_other 293, pool 40 | 0 | 37 | 0 | 0 | 5,180 → 5,011 |

- **"Freed" counts view sizes,** reserved and committed, as in 0127. "Kept" includes the emptied
  views.
- **The footprint fell by 468 MB at the helpers' end, and by 1,021 MB at the launcher's end**
  (6,032 → 5,011 MB). A process with no parked thread lost its whole band, as 0127 already did.
- **The kept views no longer hold memory.** They count as the runtime's in `[proc-mem]`. Its FEX
  row, in MB committed/resident/compressed:
  - after the helpers' end: 675/5/1. In run `20261019T210854` it was 986/295/27;
  - after the launcher's end: 3,010/21/4, against 3,190/605/422 there.
- **14 views stayed whole** because a parked thread's saved address lies in them. That cost no
  measurable footprint.
- **No fault reached an emptied view.** After the launcher's end the host log has no SEGV, through
  +900 s.
  - The five SEGVs before it are the same pattern run `20261019T210854` had: three at
    `0x73dfd74004` in the guest window and two at `0x0`.
- **No jetsam.** The phone's crash list has only two JetsamEvent reports from earlier that day.

## RDR2: the session

- **Timeline:**
  - first window at +9.44 s;
  - first frame at +97.32 s;
  - the game's `socialclub.log` signed in online at +115.7 s;
  - the launcher ended at its sign-in, not at 0130's memory threshold. The footprint was then
    6,035 MB.
- **The launcher's end:** the session root ended Launcher.exe, RockstarErrorHandler and three
  SocialClubHelper processes. It kept RDR2.exe and its crashpad_handler.
- **Footprint peak 6,034 MB,** 2,158 MB under the 8,192 MB limit. At the stop it was 5,641 MB.
  - That is not like for like with run `20261019T210854` (peak 8,140 MB). There the memory safety
    ended the launcher before the sign-in, and its tree had grown further. Here the sign-in came
    first, at 6,035 MB, and the peak is that moment.
  - With 0127 alone, this run's ~1 GB of kept band would have stayed in the footprint after the
    end. Its footprint at the stop (5,641 MB) would then have been about 6.6 GB.
- **Band:** peak 7,319 MB of 16,384 MB, 311 threads, `refused=0`.
- **The screens:**
  - 60 s: the Rockstar launcher's splash, its logo on a dark window;
  - 120 s: the game's legal and copyright text;
  - 180 s to 900 s and at the stop: the blue band across the middle of a black screen, the same
    image in every shot. No menu was reached.

## What this shows

- 0172 empties a parked process's band in place on the phone, and no fault reached an emptied view
  through +900 s.
- A killed helper that keeps 478–564 MB has the same cause: the band of a process with a parked
  thread. Its band is now emptied too.
- RDR2 now signs in, and the launcher's end follows its sign-in. The blue band remains, and it is
  the parallel investigation's.

# Donor pool: Kingdom Come for 32 minutes with the pool on; the HK A/B and the detach probe not run

**Date:** 2026-10-14. **Branch:** `research/extended-memory`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216); the titles are PLA-49
(Kingdom Come) and PLA-42 (Hollow Knight).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes), queue item 1 (phone measurements).
The owner was away and the phone was in unattended mode. Where there was a choice, the
conservative option was taken; the supervisor approved each one.

**Setup:**

- iPhone18,4, iOS 27.0.1, 11,734 MiB physical RAM, on battery (78 % → 40 % over the session).
- IPA `Playport-26.5-b3cdca61.ipa`, SHA256
  `b3cdca61de83582b96504df22c6d381592f3451e285fce11142e6a498f6025de` (commit `7413ff3`,
  madeira-unix 0150), installed before the session. No new build: these commits change only
  workstation pad routes and a host test.
- New committed routes:
  - `tools/pad/hk-profiles.txt`: A on the main menu, which leaves the profile screen up.
  - `tools/pad/hk-menu-back-start.txt`: from the "Quit Game?" dialog to the profile screen.
  - `tools/pad/kcd-continue.txt`: A on the checked Continue.
- New host test: `PadScriptTests.testEveryCommittedRouteParses`
  (`app/HostIOKit/Tests/HostIOKitTests/HostIOKitTests.swift`) parses every `tools/pad/*.txt`
  with the app's own parser. A route with a bad control fails it.
- Session scripts and run directories are under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`: `measure-s0.sh`, `measure-s1-kcd.sh`,
  `measure-s2-probe.sh` and `measure-s3-hkcheck.sh`, with their runs in `measure/`. Each
  session ran as one `pp phone lock -- sh`.

## 1. Kingdom Come, 32 minutes, pool asked 6144

**Run:** `measure/kcd-long-6144`. The steps:

1. `pp ui --action set:donorPoolMB=6144`.
2. `pp perf --title app-379430 --secs 1920 --cool 10 --syslog-all --no-hud`.
3. The Continue flow of the earlier sessions: `wait-text` skips the intro and reads the menu,
   `wait-text --highlight-above "New Game"` checks that Continue is highlighted, then
   `kcd-continue` and `kcd-walk` (it loops).
4. The battery was polled every 300 s, with a stop under 25 %.

**The first attempt had the Metal HUD on** (`measure/failed-hud/`). The HUD box covered the
highlighted Continue bar, so the Continue check failed and the script pressed nothing. The
supervisor ended that run after about 14 minutes in the menu.

The check is the same `pad.highlight_above` code on the host:

| Screenshot | Result |
| --- | --- |
| That screenshot (HUD on) | False |
| `kcd-widen-6144`'s and `kcd-widen-off`'s (no HUD) | True |

The rerun used `--no-hud`. Without the HUD, `pp perf` counts frames from the `[frames]` lines,
and the frame-time, GPU and HUD memory columns stay empty.

**Pool:** `cap_mb=5120` (level 60 %), 5120 MiB in 20 objects from one donor, installed in 0.72 s.
At the install, the system's free memory was 4,493 MiB.

**Timeline:**

| Time | Event |
| --- | --- |
| 22:20:25 | First frame (+26.52 s) |
| 22:21:49 | Continue |
| 22:22:50 | Walking |
| 22:52:50 | Killed at first frame +1920 (`until`), `ok: true`, exit 0 |

The app survived the whole run: no jetsam, no crash, no `c0000005`.

### Over time

t is seconds from the first frame. Pool sizes are in MiB, from the `donor-pool: stats` line
nearest t. The `fpMB` column is the peak of `[xp] fpMB` in the 5 minutes before t.

| t | fpMB (peak) | Pool live | Pool resident | Pool compressed | Detaches | Refused | Unmatched | Resets (purges) | System available (MiB, min–max) | FPS (5 min mean) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 60 | 2,299 | 2,703 | 2,533 | 70 | 0 | 0 | 0 | 8 | – | 33.0 (0–300) |
| 300 | 3,957 | 4,248 | 3,398 | 754 | 0 | 0 | 0 | 34 | 1,743–2,412 | 17.0 |
| 600 | 3,945 | 4,265 | 3,023 | 1,175 | 0 | 0 | 0 | 70 | 1,952–2,320 | 17.8 |
| 900 | 3,932 | 4,318 | 3,052 | 1,147 | 0 | 0 | 0 | 243 | 1,930–2,370 | 19.6 |
| 1200 | **4,007** | 4,297 | 3,069 | 1,130 | 0 | 0 | 0 | 594 | 2,201–2,355 | 19.2 |
| 1500 | 4,005 | 4,325 | 3,181 | 1,121 | 0 | 0 | 0 | 702 | 2,214–2,397 | 18.0 |
| 1800 | 3,930 | 4,326 | 3,139 | 1,163 | 0 | 0 | 0 | 702 | 2,122–2,272 | 21.4 (1800–1920) |
| 1920 | 3,887 | 4,336 | 3,142 | 1,161 | 0 | 0 | 0 | 702 | 2,051–2,178 | |

Sources for the columns:

- **System available:** the kernel's `memorystatus_available_pages` (16 KiB pages) in the
  device syslog's `memorystatus:` lines, over the same 5 minutes.
- **`memorystatus_level`:** the app logs it only at the pool's install (60 %). The stats line
  has no system fields.

**Totals at install+1950 s:**

- **Traffic:** served 255,808 commits (409,645 MiB), 216,479 releases, 235,956 reuses,
  387,127 MiB of stale pages zeroed.
- **Errors:** retired 0, refused 0, unmatched 0, map failures 0, purges pending 0.
- **The app:** `app_footprint_mb` 3,777 and `app_available_mb` 4,414. Both stayed within
  3,750–3,900 and 4,290–4,440 from t ≈ 180 s on.
- **The census:** backed 409,940 MiB in 255,940 commits. Host-page edges 216 MiB, outside
  the window 10,130 MiB, refused 0, under a host page 0, not RW 2.

**Peak footprint:**

| Run | Peak `fpMB` | Length |
| --- | ---: | --- |
| This run | **4,007** (at about +1155 s) | 32 minutes |
| `kcd-widen-6144` | 3,884 | 240 s |
| `kcd-widen-off` | 7,682 | 240 s |

So in 32 minutes the footprint rose by 123 MiB over the 240 s figure, and it did not grow over
time.

The last `[footprint]` line read `phys` 3,797 MB, `internal` 4,222 MB, `compressed` 2,349 MB
and `graphics` 1,584 MB.

**Thermal:**

- `thermalmonitord` pressure level 10 at 22:21:10 and 20 at 22:25:15, with no change after that.
- The app's thermal state went nominal → fair (22:21:09) → serious (22:25:14) and stayed
  serious.
- The lowest CPMS budget was 404 mW, first reached at +52 s.

**The system under the pool:**

- The kernel killed 232 long-idle daemons, and one other process for its own per-process
  limit (`HomeAssistant-Extensions-PushPro`).
- `available_pages_below_critical`, `compressor_is_thrashing` and the other flags stayed 0.
- The reaper killed nothing.
- `healthd` and `duetexpertd` logged "critical" memory-pressure warnings at the load
  (22:21:30–22:23:35).

**Cost of the pool:**

- `back_ms_total` was 52.9 s over 1,950 s, or 2.7 % of the run, at most 11.8 ms for one
  call. This time is spent on Wine's thread under `virtual_mutex`.
- **Most of it is zeroing reused pages:** `zero_ms_total` 49.4 s for 387 GiB, at most 11.8 ms.
  That is about 200 MiB/s of memset for KCD's churn.
- Releases took 398 ms in total (at most 3.3 ms), and purges 198 ms.
- The maximum per call first rose above 4.5 ms at install+510 s (5.3 ms), then to 11.8 ms
  at install+540 s.

FPS is 20.6 mean (p10 15.2) for the whole run under the serious thermal state. No pool-off
run of this length was made, so FPS is not compared.

**Screenshots** (they stay in the run directory):

| When | Screen |
| --- | --- |
| +600 | Rattay's street with a wooden walkway |
| +1200 | Inside a tailor's house, with a woman in a red and gold dress |
| +1900 | A castle wall and grave plots |

All three showed the HUD (compass, health bar), with no visual damage, garbage textures or
stripes.

**Verdict:** the pool held for 32 minutes of play under thermal pressure:

- The app's footprint stayed flat at about 3.8–4.0 GB.
- The pool's live set stayed at 4.2–4.3 GiB, of it about 1.1 GiB compressed by the system.
- Nothing was refused, unmatched or failed, and there was no jetsam.
- The system kept 1.7–2.4 GiB available throughout.

The cost is the reuse memset, about 2.5 % of the run on a Wine thread.

## 2. The detach path (the `protect` probe)

**Not run: the probe is not on the phone.** The session (`measure-s2-probe.sh`) asked for
`dir-protect 2` with `{"arguments":"exec-rw"}`, pool 0 and then 4096. Both runs ended
`refused: dir-protect 2 is not a catalogued title`. The app's library line lists no protect
title. It does list `dir-childabort-325`, `dir-childabort-325-i386`, `dir-gl21-i386` and
`dir-wgl`. Nothing was installed.

**The probe needs no new phase.** Its `exec-rw` phase (`tools/compat/probes/protect.c`) does
what the detach needs:

- It commits 1 MiB `PAGE_READWRITE` in one fresh `VirtualAlloc`. That is a fresh RW commit
  of whole host pages, which 0150 backs.
- It writes `mov eax, N; ret` into each 4 KiB page, protects it `PAGE_EXECUTE_READ`, calls it
  and protects it back.
- The first non-RW protect of each 16 KiB host page must take 0150's detach: a copy to
  ordinary memory, with a `[helper-guest] preserved` line.

The `data` and `rx` phases do the same with `PAGE_READONLY` and `PAGE_EXECUTE_READ` on a
second fresh 1 MiB RW commit.

**What the owner would do to run it:**

1. Build `protect.exe` (`tools/compat/probes/build.sh`).
2. Put it in the app's `Documents/Import/protect`.
3. Import it through the UI (`pp ui --action import:Import/protect`).
4. Then `measure-s2-probe.sh` runs it with the pool off and on, with the title ID the import
   gives.

Do not name `exec-rw-reuse`: it crashes on the stale anonymous alias defect
([2026-10-12 evidence](2026-10-12-noexec-rw-rx.md)).

The detach path is therefore still not exercised on the phone. Its counter stayed 0 in KCD,
as in every run so far.

## 3. Hollow Knight scripted A/B

**Not run.** Two check-only sessions read the menus. Neither pressed A on a slot, and nothing
was saved.

| Session | Run | What happened |
| --- | --- | --- |
| `measure-s0.sh` (21:43) | `measure/hk-profile-check` | `hk-profiles` (one A at first frame +25) opened "Quit Game?" with the cursor on No: the main menu's cursor was on Quit Game. The stale `vpad.txt` was not played (the log says so). The cause is not known. |
| `measure-s3-hkcheck.sh` (22:58) | `measure/hk-check2` | Each step was gated by OCR. The main menu was read with Start Game highlighted, so the same A opened the profile screen. |

**The profile screen** (`hk-check2.slots.png`):

| Slot | Contents |
| --- | --- |
| 1 | Dirtmouth, 39 min |
| 2 | King's Pass, 1 min |
| 3 | Empty ("New Game") |
| 4 | King's Pass, 5 min |

The cursor opened on slot 3, the empty one.

The supervisor's rule for this unattended session was: never start a new game or create a
save, and stop if the cursor's slot is empty or unclear. So no A/B ran.

The usual measured route, `hk-new-slot` → `hk-walk` → `hk-roam` (2026-09-29 baseline), starts
an unsaved new game in that slot. It would give both runs an identical start, cinematic
included. Running it needs the owner's approval.

**Finding:** in the session-0 check, the main menu's first selection was not Start Game, but
in the next check it was. So a route that presses A at a fixed time can land on the wrong item.

`hk-menu-back-start` and the OCR crops are ready:

| Screen | Crop | Texts |
| --- | --- | --- |
| Main menu | `0.30,0.50,0.70,0.92` | Start Game, Options, Extras, Quit Game |
| "Quit Game?" dialog | `0.35,0.35,0.65,0.62` | Quit Game, Yes, No |
| Profile screen | `0.10,0.10,0.90,0.95` | Back |

`hk-menu-back-start` itself has not been played on the phone. The full screen does not OCR in
Hollow Knight's font; the crops do.

## What this shows and does not

- **Long play is stable with the pool:** 32 minutes of KCD, footprint flat at about 4.0 GB,
  no jetsam, and all error counters 0.
- **There is one long run and no pool-off run of the same length.** FPS is therefore not
  compared, and the thermal state was serious for most of the run.
- **Whether the pool costs FPS in steady play or in scene loads is still open** (the HK A/B).
  The KCD run gives the pool's own time: 2.7 % of the run, mostly zeroing.
- **The detach path is still not exercised on the phone.**

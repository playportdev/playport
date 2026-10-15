# Donor pool and Kingdom Come: about 700–800 MiB less app footprint in Rattay

**Date:** 2026-10-14. Branch `research/extended-memory`, commits `9cbc873`
and `5e088c6` (step 4's additions on top of step 3, `25f484d`), the PLA-350
merge `3db126b` and `8bb3093` (`pp pad wait-text --crop --highlight-above`).
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216); the title
is PLA-49; the crash fixed first is
[PLA-350](https://linear.app/playportdev/issue/PLA-350).
**Plan:** [donor memory, step 4](../plans/2026-10-12-donor-memory.md#4-does-it-help-a-game).
**IPA:** `Playport-26.5-f1f024ae.ipa` (dev, entitled build), SHA256
`f1f024aed7548b6eb01a8002de8e4f685dfa92f728d540cdce8d52c4cf56e26b`, installed
in place. iPhone18,4, iOS 27.0.1, 11734 MiB physical RAM, battery 80 % on
power, 3.3–3.5 GB storage free. Every run below used that IPA.

## What this step added before the session

- **A periodic stats line.** A pool that is installed logs
  `donor-pool: stats at install+Ns` every 30 s, from a utility-queue timer.
  The line has the same fields as the first-frame lines:
  - served and served_mb, live_mb, resident_mb, compressed_mb, released_mb;
  - detaches and detached_mb;
  - resets (the purges), purge_ms_total and purge_ms_max;
  - refused, unmatched_mb, map_failures;
  - app_footprint_mb and app_available_mb.

  The timer takes only the pool's own lock, never Wine's. It is
  `DonorPool.startPeriodicReport`.
- **`pp pad wait-text`** (`tools/pad.py`, tested in `tools/tests/test_pad.py`).
  It takes screenshots and reads them with tesseract, both the image and its
  inverse, until at least N of the given labels are read.
  - `--press STEP` plays those pad steps after each check that read none of
    the labels, and stops pressing for good once any label is seen.
  - `--crop L,T,R,B --highlight-above TEXT` (added for this session) also
    needs a light bar just above TEXT's line in that part of the screen.
    Tesseract drops or garbles Kingdom Come's highlighted Continue, which is
    dark text on a light banner. A check that read only the screen's text
    missed it in the session before this one, so no A was pressed.

## Before this session

- **The first session (IPA `195d5698…`)** crashed in the Steam API emulator
  about 11 s after the game started, with the pool off and on. That was
  PLA-350: Kingdom Come called the newest `SteamUser` interface's
  GetAuthSessionTicket with three arguments
  ([2026-10-14-kcd-steam-api-crash.md](2026-10-14-kcd-steam-api-crash.md)).
  The pool's first purges and reuse on the phone ran in that session's
  start-up: object 3 was purged 16 times, then served again from offset 0.
  It had no errors. Runs are in `donor-memory/runs/old-step4/`.
- **Plaion's EULA (sessions 2 and 3).** On the fixed IPA, Kingdom Come
  showed a page it had not shown before: "EULA", a QR code,
  `deepsilver.com/games/kingdom-come-deliverance/eula`, and the button
  "Accept (A)". The menu wait found no labels there, so no A was pressed
  (`runs/eula-step4/`). With the owner's approval, the next session accepted
  it by script. `pp pad wait-text` first read "EULA" and "Accept", then one
  `pp pad send "150 A"` was sent at 14:29:03. The main menu then showed
  Continue (highlighted), New Game, Load Game, Settings, Help, DLCs, Deep
  Silver Account, Credits and Quit; the game's version reads
  1.9.8-404-504czi4. That session's Continue check missed the highlighted
  item and stopped without an A (`runs/eula-step4b/`).
- **Open question:** did the PLA-350 change make the game show the EULA?
  `steam_interfaces.txt` now gives Kingdom Come its own SDK's interface
  versions. This may have stopped the game from seeing a stored acceptance.
  It is not known. The save was still seen (Continue is there and loads
  Rattay), and the EULA did not come back in the next two launches.

## The session

The session script was `step4-session.sh` in
`$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`, run under
`pp phone lock -- sh` from 14:43 to 14:57. Steps:

1. `pp install --no-build`: the IPA was already installed, so there was
   nothing to do.
2. Two Kingdom Come runs. Each was
   `pp ui --pad --action set:donorPoolMB=<0|6144> --play app-379430 --until first-frame+205 --shot`.
   After the first frame:
   - `pp pad wait-text --press "150 B" --press "300 -" --need 2 EULA Accept "New Game" "Load Game" Settings`.
     If the EULA came back, the script was to stop. It did not come back.
   - The menu wait from the session before.
   - `pp pad wait-text --crop 0.70,0.33,0.92,0.80 --highlight-above "New Game" --timeout 0 "New Game"`.
     It returned `highlight_above: true` in both runs.
   - One A on Continue, then 45 s and `pp phone shot`.
   - `pp pad push kcd-walk`.
3. A 2-minute rest before each launch.
4. Hollow Knight with a 4 GiB pool.
5. `pp phone status` and `pp phone kill`.

No run was retried. Both runs started at nominal thermal state. The pool
run reached "serious", the off run "fair", so this is not a controlled
performance comparison.

| Measurement | KCD, pool off | KCD, pool 6144 asked |
| --- | ---: | ---: |
| Run directory (under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`) | `kcd-pool-off` | `kcd-pool-6144` |
| Pool | none | `asked_mb=6144 cap_mb=5120` (level 60 % less 15 % of 11734 MiB), 5120 MiB granted by one donor |
| Game started / first frame | +3.20 s / **+24.33 s** | +3.87 s / **+25.53 s** |
| A on Continue (about) | Play+101 s | Play+104 s |
| Menu, loaded and stop screenshots | Menu with Continue highlighted. Loaded in Rattay: the arcaded houses across the square, compass and health bar. Stop: the square with a saddled horse, NPCs, the arcades. | The same menu. Loaded at the same spot. Stop: a street of half-timbered houses with two NPCs, Henry's hand and staff in view. |
| Peak `[xp] fpMB` | **7,914** (at +230.6 s) | **7,217** (at +232.7 s), −697 |
| `fpMB` at Play+110 / +170 / +230 | 6,010 / 7,751 / 7,875 | 5,619 / 6,970 / 7,066 (−391 / −781 / −809) |
| `os_proc_available_memory` at start | 7,591 MB (footprint 600 MB) | 7,602 MB (footprint 589 MB) |
| Lowest `app_available_mb` (pool stats) | n/a (no pool) | 1,016 MiB at install+210 s |
| End | `until first-frame+205` reached, `ok: true`, exit 0 | the same |
| `c0000005`, crash reports, jetsam | none, none, none | none, none, none |
| Visual damage | none seen | none seen |

The game's own Steam auth ticket was made and acked in both runs, as on the
PLA-350 IPA.

## What the pool did in the 6144 run

| Stats line | served | served_mb | live_mb | resident_mb | compressed_mb | resets | refused | unmatched_mb | app_footprint_mb | app_available_mb |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| first frame | 449 | 1,321 | 621 | 864 | 0 | 36 | 0 | 0 | 2,570 | 5,621 |
| install+30 s | 503 | 1,568 | 665 | 1,100 | 0 | 36 | 0 | 0 | 2,843 | 5,348 |
| install+60 s | 685 | 3,065 | 752 | 2,191 | 0 | 50 | 0 | 0 | 3,183 | 5,008 |
| install+90 s | 2,398 | 7,174 | 607 | 1,779 | 1,114 | 71 | 0 | 0 | 4,412 | 3,779 |
| install+120 s | 2,716 | 7,831 | 613 | 1,447 | 1,503 | 75 | 0 | 0 | 5,699 | 2,492 |
| install+150 s | 3,992 | 10,454 | 631 | 1,063 | 2,054 | 83 | 3,406 | 0 | 6,793 | 1,398 |
| install+180 s | 3,992 | 10,454 | 631 | 501 | 2,620 | 83 | 6,630 | 0 | 7,155 | 1,036 |
| install+210 s | 3,992 | 10,454 | 631 | 484 | 2,639 | 83 | 10,090 | 0 | 7,175 | 1,016 |
| install+240 s | 3,992 | 10,454 | 631 | 482 | 2,640 | 83 | 13,211 | 0 | 7,131 | 1,060 |

In every line: detaches 0, detached_mb 0, retired 0, map_failures 0,
unmatched_mb 0. The purges took 17 ms in total, 4 ms at most.

- **Purge and reuse under load worked.** The pool served 10,454 MiB in
  3,992 requests through 5,120 MiB, with 83 purges. No lease was unmatched.
- **The pool stopped serving from about install+150 s.** `served` stayed at
  3,992 from then on, and `refused` climbed to 13,211, while only 631 MiB
  was live. The pool is a bump allocator per object, and an object is
  reused only once it is released whole and purged. After the Rattay load,
  no object had room at its bump pointer, so later allocations went to
  ordinary memory. The footprint gap stopped growing there (+170 −781,
  +230 −809).
- **The system compressed pool pages.** `compressed_mb` reached 2,640, and
  `resident_mb` fell to about 480. This memory is outside the app's
  footprint, but it is not free for the phone.
- **Detach path not exercised:** there were no detaches.

## Result

**Step 4's pass criteria are met for this single pair:**

- **Lower peak footprint:** 697 MiB less with the pool (7,914 against
  7,217, −8.8 %), and 781–809 MiB less in the world at +170 and +230.
  The 2026-10-03 pair varied by 86 MiB between runs.
- **Rattay:** both runs loaded it.
- **Unmatched:** 0 throughout.
- **Crashes:** none, and no jetsam.

This is one pair, with a thermal difference. The pool stops serving after
the load, so a longer session would show how much of the gap is left.
Raising the RAM and VRAM the game is told it has was not done.

## Hollow Knight regression (pool 4096)

Run `hk-pool-4096-step4`: `ok: true`, `until first-frame+10` reached.

- **Pool:** `asked_mb=4096 cap_mb=4864`, 4096 MiB granted.
- **First frame:** +10.55 s. Step 3 measured +9.98 s with the pool and
  +10.24 s without it.
- **Stats at first frame+8s:** 56 requests, 399 MiB served, 286 MiB
  resident, 0 detaches, 0 resets, 0 refused, unmatched 0, 0 map failures,
  app footprint 2,280 MiB, available 5,911 MiB.
- **Peak `[xp] fpMB`:** 2,468.

## Not done

- the detach path (a PLA-203-family title);
- a session over 30 minutes with the pool on;
- raising the RAM and VRAM the game is told it has;
- a pool that can reuse released ranges before a whole object is free.

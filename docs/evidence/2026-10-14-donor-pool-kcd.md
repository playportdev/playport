# Donor pool and Kingdom Come: blocked by a crash before the first frame

**Date:** 2026-10-14. Branch `research/extended-memory`, commits `9cbc873` and
`5e088c6` (on top of step 3, `25f484d`).
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216); the title
is PLA-49.
**Plan:** [donor memory, step 4](../plans/2026-10-12-donor-memory.md#4-does-it-help-a-game).
**IPA:** `Playport-26.5-195d5698.ipa` (dev, entitled build), SHA256
`195d5698ba853c447bdbdb92477bc530fc8b63f747febbe152932c3f437db111`, installed
in place. iPhone18,4, iOS 27.0.1, 11734 MiB physical RAM, battery 80 % and
not on power. All three runs below used that IPA in one locked session.

## What this step added before the session

- **A periodic stats line.** A pool that is installed now logs
  `donor-pool: stats at install+Ns` every 30 s, from a utility-queue timer.
  The line has the same fields as the first-frame lines:
  - served and served_mb, live_mb, resident_mb, released_mb;
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
    the labels.
  - It stops pressing for good once any label is seen.
  - A failed screenshot presses nothing, and the check is repeated.

  This is the "menu recognized before A" step of the
  [2026-10-03 KCD orchestration](2026-10-03-kcd-helper-memory.md), whose
  local script is gone. It is now a named command.

## The session

The session script was `step4-session.sh` in
`$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`, run under
`pp phone lock -- sh`. Steps:

1. `pp install --no-build`.
2. Two Kingdom Come runs. Each was
   `pp ui --pad --action set:donorPoolMB=<0|6144> --play app-379430 --until first-frame+205 --shot`,
   with this pad sequence after the first frame:
   - `pp pad wait-text --press "150 B" --press "300 -" --need 2 "New Game" "Load Game" Settings`;
   - `pp pad send "150 A" "1000 -"`;
   - 45 s, then `pp phone shot`;
   - `pp pad push kcd-walk`.
3. A 2-minute rest before each launch.
4. Hollow Knight with a 4 GiB pool.
5. `pp phone status` and `pp phone kill`.

No run was retried.

| Measurement | KCD, pool off | KCD, pool 6144 asked |
| --- | ---: | ---: |
| Run directory (under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/`) | `kcd-pool-off` | `kcd-pool-6144` |
| Pool | none | `asked_mb=6144 cap_mb=4096` (level 50 % less 15 % of 11734 MiB), `granted_mb=4096 objects=16 donors=1` in 0.71 s |
| Prerequisites before the game | VC++ 2015 x86 and x64 ran for the first time in this prefix, both `exit 0x00000666` (already installed), and were recorded | both already ran |
| Game started | +5.27 s | +3.93 s |
| First frame | **none** | **none** |
| End | `exit=0xc0000005 after_s=12` | `exit=0xc0000005 after_s=11` |
| Peak `[xp] fpMB` before the end | 2,714 | 2,064 |
| FEX band in use at the end | 3,836 MiB | 3,145 MiB |
| Menu / loaded / walk | not reached (no A pressed) | not reached (no A pressed) |
| Crash reports (iOS) | none | none |

**Both runs end with the same fault.** The game's Steam API module faults
before any frame, with the pool off and on:

- The module is `steam_api64.dll` at base `0x73f3490000`. This is Playport's
  Steam API emulator: its unixlib is `playport_steam_unix_call_funcs`.
- The fault is at offset +0x1b4760, on `41 83 3f 00`, which is
  `cmp dword [r15], 0` with `r15 = 0x1f4`. That is a read of NULL+0x1f4
  (`[exc-disp] raise … code=c0000005 … p0=0 p1=1f4`).
- The process then calls `NtTerminateProcess(exit_code=0xc0000005)`.

The stop screenshots show only the game's splash window, Kingdom Come's crest
and title over a burning village. The pool-off run also still shows the
VC++ installer's empty console window. No game frame was drawn.

So the pool did not cause the crash. The run never reaches the memory the
step is meant to measure, and the footprint figures above are from the first
~11 s of start-up: **they are not an off/on comparison.** On 2026-10-03, at
main `2f2240e`, the same title loaded Rattay. Main has since gained:

- store sign-in and Steam tickets (`13c3522`);
- install-script prerequisites (`bb5a281`, `825c102`);
- SteamStub changes.

Which change is responsible has not been checked. It is filed as a
Kingdom Come issue, not fixed here.

## What the pool did in the 6144 run

This is the first time purge and reuse ran on the phone:

- **Served:** 256 requests by about +11 s (`served #256 … served_mb=786
  live_mb=529`).
- **Purges:** object 3 was released whole and purged 16 times
  (`purge kr=0 in 0.01 ms (zeroed)`, resets 1–16). Each time only a few of
  its pages had been touched.
- **Reuse:** `served #256` then came from object 3 at offset 0, so a purged
  object was served again.
- **Errors:** none. No `detach` line, no `bytes not leased` (unmatched)
  line, no map-failure line and no `refused` line.
- **Periodic stats:** no `stats at` line. The game ended before both the
  first frame and the first 30 s tick.

## Hollow Knight regression (pool 4096)

Run `hk-pool-4096-step4`: `ok: true`, `until first-frame+10` reached.

- **Pool:** `cap_mb=4096`, `granted_mb=4096` in 0.71 s.
- **First frame:** +9.94 s. Step 3 measured +9.98 s with the pool and
  +10.24 s without it.
- **Stats at first frame+8s:** 56 requests, 399 MiB served, 286 MiB
  resident, 0 detaches, 0 resets, 0 refused, unmatched 0, 0 map failures,
  app footprint 2,283 MiB, available 5,908 MiB.
- **Peak `[xp] fpMB`:** 2,461.
- **Screen:** the stop screenshot shows the title menu (Start Game, Options,
  Achievements, Extras, Quit Game) with no visual damage.

The run ends about 20 s after Play, so the periodic line has not yet been
seen on the phone.

## Not done

Nothing in this step was measured with KCD in Rattay:

- peak fpMB against the limit;
- footprint at Play+110/+170/+230;
- detaches under load;
- `pp pad wait-text` on the real menu;
- raising the RAM and VRAM the game is told it has.

All of these wait for the crash fix. Phone storage went from 3.6 to 3.3 GB
free during the session.

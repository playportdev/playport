# A Play continues in a relaunched process: switching games in about 10 s

**Date:** 2026-09-29. **Question:** after a game, can Play on another one
relaunch Playport and start that game in the new process, as the one Play the
person asked for, with JIT, to its first frame? And how long does the switch
take? This builds on
[Playport relaunches itself from the phone](2026-09-29-self-relaunch-from-the-phone.md).
**Result:** yes. From PoolStress's result screen, Play in a fresh process
reached Hollow Knight's first frame in the relaunched process about 9.9 s after
the tap. The Play started in the new process 778 ms after the tap. The new
process had its own JIT pool, with none of the old game's use, and Hollow Knight
ran at 60 FPS. The driver followed the one run across the relaunch.

## What was built (dev builds with `PLAYPORT_IDEVICE=1` only)

`app/Sources/S1Probe/Dev/PendingPlay.swift`, with the game page's dev button
**Play in a fresh process** and the UI driver's `relaunch-play:<title id>`:

1. The old process writes `Documents/pending-play.json`: the title, the time,
   its PID, and a driven run's nonce and session. It then sends the relaunch
   (`SelfRelaunch`).
2. The new process, when its UI appears, checks the record. It drops a record
   older than 60 s, or one its own PID wrote. It **deletes the file before
   acting**, so a failure cannot loop. It waits for the first library scan, then
   calls the same `LibraryModel.play` the Play button calls.
3. A driven Play takes over the run's nonce (`RunEvents.continueRun`), so
   `pp ui` follows the title's events across the relaunch. `DriverUndo` treats
   the record's session as this launch's own, so the session's settings are not
   undone before the Play. `tools/ui.py` treats `relaunch-play:` as a play:
   the run ends with that title's end, or with `--until`.

## Results

IPA `Playport-26.5-c03ba5a8.ipa` (dev, idevice built in), sha256
`c03ba5a8c53ba50648a5f6691cbf32a923de0d88fcd9e24faf1aa46b6289c5cb`; iPhone18,4,
iOS 27.0. Hollow Knight (`app-367520`). All three runs were ok.

| Run | Tap → new process | Tap → Play in the new process | Play → first frame (JIT) | Tap → first frame |
| --- | --- | --- | --- | --- |
| baseline: `--play app-367520` (a fresh driven launch, no relaunch) | – | – | 11.52 s (3.10 s) | – |
| `relaunch-play:app-367520` from the library | 552 ms | 848 ms | 9.11 s (3.09 s) | ≈ 9.96 s |
| `play:dir-poolstress` then `relaunch-play:app-367520` from its result screen | 473 ms | 778 ms | 9.09 s (3.63 s JIT acquire) | ≈ 9.87 s |

- The **tap** is the time the old process recorded the pending Play. The new
  process logs the gap once its library is ready: `relaunch: pending play
  app-367520: continuing in pid 14052, 778 ms after pid 14042 asked (library
  ready 159 ms into this process's UI)`.
- **Play → first frame** is the title's own marks. In the relaunched process,
  "surface ready" came at +0.52 to +0.55 s, against +1.63 s in the baseline.
  Its first library scan and the JIT readiness check had already run.
- **Pool:** PoolStress ended with `head_mb=216 … children=9` in the old process.
  The relaunched process's first `pool:` line for Hollow Knight shows
  `head_mb=187 … children=1`: a new pool.
- The screenshot at first frame +10 s shows Hollow Knight's title screen at
  59.98 FPS, with Game Mode on.

Run directories: `$PLAYPORT_BUILD/probe0/pending/{baseline,relaunch,after-game}`.

## What it means

The cold-relaunch design works on the phone, from a real result screen:

- a fresh Wine, FEX and JIT pool for each game;
- no session root and no pseudo-process reclamation for the second game;
- about 0.8 s of switching overhead before the new Play starts. In the new
  process, Play to first frame took 9.1 s, against 11.5 s for a fresh driven
  launch (one sample each). How it compares with a second game in the same
  process under the session root (decision 0027) was not measured here.

## Not yet shown

- **The release build.** idevice is linked only into a dev build here, behind
  `PLAYPORT_IDEVICE=1`. A release needs a pipeline stage and a real `idevice` pin.
- **The game still running.** Relaunching while a game runs, rather than from
  its result screen, has not been tried.
- **Failures.** The VPN off (the relaunch request fails before anything is lost,
  and the pending Play is deleted), a phone that is locked or in the
  background, and a pending Play that expires were not exercised.
- **Repetition.** Several switches in a row.

# Stopping a game that ran the JIT pool out

**Date:** 2026-09-28. **Phone:** iPhone18,4, iOS 27.0. Branch
`fm/pp-jitpool-teardown` on main `f010e5f`. Three dev IPAs, each installed with
`pp install --no-build` at the start of its device-lock session:

| IPA | sha256 | What it has |
| --- | --- | --- |
| `Playport-26.5-43dee3a1.ipa` | `43dee3a182f305bf0a1d933763287c47947f2f6e322f8affb25da166cddc6803` | the stop (the guest's end of the socket only), the result screen's text, `play:`/`back:library` |
| `Playport-26.5-2a11daae.ipa` | `2a11daaecc1bb7e64115c4051be9dbb656c42acaa9f1fbca2738a03936885435` | the same, and `wine_host.c`'s lines reach the log |
| `Playport-26.5-2494f480.ipa` | `2494f48034381e0fd4848d9387aac3f0a79c21919b42e01fbda98e551df5ff91` | **the branch's**: the same, the wineserver's end a second later if the game has not ended, and the thread census |

The runs' `title:` and `[wine_host]` stop lines are in
[timelines.txt](2026-09-28-jit-pool-stop/timelines.txt). The decision is
[0022](../decisions/0022-stop-a-game-that-ran-the-pool-out.md). The threads,
CPU and footprint in the stop lines below come from these IPAs' diagnostics;
the branch has since removed them, and its `title: stop:` line says only
whether the game ended and how long it took. It has also left out the
`host_log` change that put `wine_host.c`'s lines in the log (below).

## The branch's IPA (2494f480), one session

| Run | Result |
| --- | --- |
| `pp ui --play app-367520 --until first-frame+10 --shot` | ok: 896 MiB pool, runtime at +3.57 s, first frame at +8.63 s, ran 10 s on (shot (screenshot not published)) |
| `pp ui --action set:jitPoolSimulatedMB=184 --action play:app-367520 --action back:library --action open:settings --shot-each-action`, twice | `pool=exhausted:head stopped after_s=14` both times; Back to library and Settings drawn after it |
| the same with `set:jitPoolSimulatedMB=128 … back:library` | `pool=exhausted:head exit=0xc0000135 after_s=0`: the game ends on its own, nothing to stop |

The two 184 MiB runs, from their `title: stop:` lines:

| | Run 1 | Run 2 |
| --- | --- | --- |
| before the stop (the last 2 s) | 67 threads, 74 % CPU, footprint 1679 MB; 60 threads started by the launch | 68 threads, 74 % CPU, 1674 MB; 59 |
| the game ended | < 5 ms after the stop | < 5 ms |
| 1 s after | 50 threads, 2 % CPU, 1679 MB | 51 threads, 2 % CPU, 1674 MB |
| 5 s after (the driver on Settings meanwhile) | 49 threads, 5 % CPU, 1647 MB; 43 of the launch's threads left | 50 threads, 5 % CPU, 1642 MB; 42 left |

- In each, the wineserver logged `kill_process pid=0020 violent=0` with every
  thread of the game within a millisecond of the shutdown of the guest's end
  of its socket; the guest's main thread left through `pthread_exit`
  (`guest main thread ended through pthread_exit (stopped)`), and the
  wineserver was joined 2 ms later. The second step (the wineserver's end)
  was never needed.
- The result screen: "Hollow Knight ran out of JIT memory. Playport set aside
  184 MB of JIT memory for the game, and the game's program files filled it,
  so Playport stopped the game. A higher memory limit gives it more."
  (shot (screenshot not published)), with the per-session
  footer and Close Playport as after any game. Back to library showed the
  Installed tab (shot (screenshot not published)),
  and Settings its Memory section (shot (screenshot not published)).
- At 128 MiB the screen has no stop in it: "… and the game's program files
  filled it. A higher memory limit gives it more."
  (shot (screenshot not published)).
- **What is left.** The threads the game started that are left 5 s after:
  Unity's `Job.Worker 0`–`4` and `Background Job.Worker 0`–`15`,
  `Loading.AsyncRead`, `Loading.PreloadManager`, `BatchDeleteObjects`, DXMT's
  `dxmt-encode-thr` and two `dxmt-finish-thr`, the runtime's `wine-stale-heal`
  and `wine-x18-exc`, `AURemoteIO::IOThread` (the audio unit, which plays
  silence once its ring is empty), and 12 or 13 unnamed ones. None runs: the
  whole app took 2 % CPU a second after the stop, and 5 % while the driver
  drew two pages. Unity's workers wait inside the process, not on the
  wineserver, so the kill does not wake them; they stay parked. The game's
  main thread and its render thread are gone, and no frame is presented.
- The footprint stays at the game's (about 1.65 GB): its memory is not given
  back, as after a normal exit.
- The crash reports `pp ui` collected (`S1Probe-2026-09-28-072149.ips`,
  `-080216.ips`) are from before these runs (other agents' sessions); none
  was written during them.

## The gate head (89afbe09), after the rebase onto main #28

The branch rebased onto main `ab9cf2e` (#28), IPA `Playport-26.5-89afbe09.ipa`,
sha256 `89afbe09cc365b03b9010e1ac7a6f5eb0b7a6564e72ca2cebdf8d0de7511d7fa`, one
device-lock session:

| Run | Result |
| --- | --- |
| `pp ui --expect-ipa 89afbe09… --play app-367520 --until first-frame+10 --shot` | ok: 896 MiB pool, first frame at +9.91 s, ran 10 s on |
| `pp ui --action set:jitPoolSimulatedMB=184 --action play:app-367520 --action back:library --action open:settings --action open:app-367520 --shot-each-action` | `pool=exhausted:head stopped after_s=14`, ui `ok actions=5` |
| the same with `set:jitPoolSimulatedMB=128 … back:library` | `pool=exhausted:head exit=0xc0000135 after_s=0`, ui `ok actions=3`: the game ends on its own |

- At 184 MiB, `[wine_host] stop: shut down the guest end (fd 28, inode 18)`,
  then `stop: the guest has ended` 1 ms later; `title: stop: the game ended
  0.00 s after it was stopped; before: 67 threads, 77 % CPU, footprint 1678 MB
  (58 started by the launch); after: 50 threads, 2 % CPU, footprint 1678 MB`.
  5 s after: 49 threads, 5 % CPU, 41 of the launch's threads left (Unity's job
  workers, DXMT's finish and encode threads, parked).
- The result screen said "… filled it, so Playport stopped the game. A higher
  memory limit gives it more." with Close Playport and Back to library. Back
  to library drew the Installed tab, Settings drew, and the Hollow Knight page
  drew with Play disabled, "Playport has already run a game in this
  session…" and Close Playport.
- `title: limits: wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0`: main's
  #28 lines are there.
- At 128 MiB the screen said "… the game's program files filled it. A higher
  memory limit gives it more.", with no stop in it; Back to library drew.
- `pp ui` exits 1 after both exhaustion runs, by design: a run whose pool ran
  out is not ok.

## Earlier IPAs

- **43dee3a1** (session 1): the first 184 MiB run ended `still-running
  after_s=14`: the game went on presenting (about 110 frames a second) for
  the 10 s after the stop, and the wineserver logged no `kill_process`. This
  IPA's `wine_host.c` lines did not reach the log (below), so whether the
  shutdown was made cannot be told. The result screen said so and offered
  Close Playport (shot (screenshot not published)).
  The next play in that session, also at 184 MiB (the `set:` lasted for the
  session), was stopped: 68 threads and 77 % CPU before, 51 and 2 % after.
  The 128 MiB run ended on its own, as above.
- **2a11daae** (session 2): a normal play at 896 MiB reached `first-frame+10`;
  three 184 MiB runs were each stopped (`kill_process` within 1 ms, the game
  ended in under 5 ms, 2 % CPU after), and the driver reached the library and
  Settings after each.
- Because that one run was not stopped, the branch's IPA shuts down the
  wineserver's end of the socket too when the game has not ended a second
  after the guest's end; either EOF is read as the process's death.

In all, 8 of 9 stops on the phone ended the game (7 of 7 once the log showed
the stop's own lines); the one that did not left the app usable and said so.

## The host log

`wine_host.c`'s `host_log` wrote through its own `FILE` on the log, and with
the guest running none of those lines reached the file (not the stop's, nor
`guest exit code` or `shutdown:` at a normal exit, in any run in the build
area's history). HostIO's `host_log.c` had found the same and writes through
stderr once `wine_host_init` has pointed it at the log. IPAs 2a11daae and
2494f480 made `wine_host.c` do the same, and its lines appeared. That change is
not part of this branch: `host_log` writes as it does on main, so these lines
may again not reach the log, and why they go missing is a separate follow-up.

## Not run

- A title that starts child processes (none installed; 0019): the stop does
  not end them.
- The release build on the phone (`pp check --variant release` compiles it).

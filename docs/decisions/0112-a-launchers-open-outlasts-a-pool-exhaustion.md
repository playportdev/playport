# 0112: The Rockstar launcher's Open goes on 240 s after the JIT pool ran out

**Status:** accepted, 2026-10-17, chosen by the owner (PLA-381: a launcher Open is not stopped
10 s after a head exhaustion). **Amends [0022](0022-stop-a-game-that-ran-the-pool-out.md)**: its
10 s, for this one Open only. [PLA-381](https://linear.app/playportdev/issue/PLA-381),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](../plans/2026-10-16-cef-low-va-build.md).

## Context

0022 ends a launch whose title is still running 10 s after the pool ran out; since 0030 the
restart that follows ends the title. It was written for single-process games, where a pool that
ran out means the game's own code cannot be translated.

In the Rockstar Games Launcher's last phone Open (IPA `887442a3…`, run `20261016T203152`,
[evidence](../evidence/2026-10-16-cef-fewer-processes-phone.md)), it was that rule that ended the
session, not Chromium. The owner-requested review of the work since `9192531` found it in the run's
timeline and host log:

- `[jit-pool] EXHAUSTED (image 0x739f170000+0x48d000): want=0x498000 bump=0x20a00000/0x38000000
  tail_resv=0x17420000`: Social Club's audio utility could not copy its 4.6 MiB `xtajit64.dll`.
  This was the first and only head exhaustion.
- `pool: ran out of JIT memory (head)`, then 10 s later `pool: the game is still running 10 s after
  it ran out of JIT memory; the restart ends it`, and the result
  `pool=exhausted:head still-running after_s=61`.
- When it stopped, the CEF browser, the storage service and both renderers were still running; the
  second renderer still reported its FEX code tail.
- Social Club's UI had about 17 s, on interpreter-only V8 under FEX, from "Social Club UI has
  started" to the stop. Whether the sign-in page paints given more time has never been measured.

An optional Chromium child that cannot start is restarted by the browser; the launcher goes on
without it.

## Decision

- **Scope.** Only the Rockstar Games Launcher's Open from Settings › Launchers (PlayportKit
  `PublisherLauncher.rockstar`, the driver's `open-launcher:rockstar`). Games, Steam, Epic and GOG
  titles, and any other launcher, keep 0022's 10 s (`JitPool.exhaustionGrace`).
- **Value.** The Open's launch ends 240 s after a reading first showed the pool run out, if the
  launcher is still running, instead of 10 s. The value is a field of the launcher's entry
  (`PublisherLauncher.exhaustionGrace`), carried to the launch in its request
  (`LaunchCoordinator.Request.exhaustionGrace`). There is no setting, environment switch or
  driver option for it (decision 0012).
- **Logging.** Every launch logs the grace it uses once at its start (`pool: a title still running
  N s after it runs out of JIT memory ends this launch`). The exhaustion and the moment the grace
  is exceeded are logged as before (`pool: ran out of JIT memory (<part>)`, `pool: the game is
  still running N s after it ran out of JIT memory; the restart ends it`).

## What stays

- The outcome is unchanged: a launch whose pool ran out ends as *ran out of JIT memory*, with
  `pool=exhausted:<part> still-running after_s=N` (or `exit=…` if the launcher ends on its own), and
  `pp ui` judges it as before (`pool=exhausted:` is not ok). The `pool:` lines report the
  exhaustion as soon as it happens.
- The restart after the launch (0029, 0030) ends the launcher, as it ends a game; it only comes up
  to 230 s later. A run the driver ends first (`--until "mark:first window+240"`) ends the app as any
  driven run does.
- The pool, the band, the in-process stop 0030 removed and every other title's launch are
  unchanged.

## Consequences

- A launcher whose pool ran out keeps running on the phone for up to 4 minutes, using CPU and
  memory, before Playport restarts. The player can Quit game sooner.
- While the launcher goes on, its processes may keep failing to start (the audio service was
  restarted about 50 times in that run), and the band may fill. The Open shows whether the sign-in
  page appears in that time; the grace frees nothing.
- If the sign-in page appears only because of this, a later record says how a launcher Open ends
  once it no longer runs the pool out.

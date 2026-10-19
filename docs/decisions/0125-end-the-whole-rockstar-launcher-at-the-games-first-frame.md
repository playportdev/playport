# 0125: RDR2's Play ends the whole Rockstar launcher tree at the game's first frame, in one step

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-409, PLA-413). Amends
[0124](0124-end-the-rockstar-launcher-after-the-games-sign-in.md): the launcher ends at the
game's first frame, not at its sign-in, and the field is renamed. Nothing under RDR2.exe is ever
ended. Not yet shown on the phone.

## Context

0124 ended the launcher once the game had signed in to Social Club. On the phone that line
comes after the end ([evidence](../evidence/2026-10-19-rdr2-loading-memory.md)):
- RDR2 is killed at the 8,192 MB memory limit 7–12 s after RDR2.exe loads `socialclub.dll`
  and libcef.
- At the game's first frame the `[proc-mem]` lines (madeira-unix 0166) put about 2.8 GB of a
  5.0 GB footprint on the launcher side, about 2.5 GB of it in the launcher's own
  `SocialClubHelper.exe` processes.
- The first frame comes 19–240 s before the `socialclub.dll` load.

Two plays tried an earlier end:
- **Run `20261019T153520`** ended `Launcher.exe` and its error handler at the first frame. The
  Steam stub `PlayRDR2.exe`, which waits on the launcher, then showed "Unable to launch game,
  please try reinstalling the game." RDR2.exe went on: it loaded its own `socialclub.dll` and
  started its own Social Club helper.
- **Run `20261019T161557`** ended only the launcher's helpers and kept `Launcher.exe`. The ending
  freed nothing (PLA-416, [0127](0127-end-a-terminated-pseudo-process.md)). `Launcher.exe`
  showed "The CEF browser … crashed and could not restart" and started its helpers 8 more
  times. Each died at once with `0xC0000017`. The 10 s and 60 s checks, which only looked at
  the processes alive then, saw none of them.

## Decision

- **At the game's first frame, the whole tree in one step.** At the first 2 s wait slice after
  the first frame, `LaunchCoordinator` sends `PP_CONTROL_END_LAUNCHER`, once. The session root
  ends, one process at a time, first `Launcher.exe` and `RockstarErrorHandler.exe`, then every
  `SocialClubHelper.exe` whose parent chain reaches a `Launcher.exe` (`pp_launcher_end`,
  `launcher_end.h`).
- **PlayRDR2's dialog is accepted.** PlayRDR2.exe's "Unable to launch game" box is left as it
  is.
- **Restarts are counted from every start.** The title's job now has a completion port. After the
  end, the root takes each `JOB_OBJECT_MSG_NEW_PROCESS` and names the new process: its image,
  its parent, and whether it still runs. A start of one of the launcher's images is a restart
  (`pp_launcher_restart`):
  - the launcher or its error handler again;
  - a Social Club helper whose chain reaches a `Launcher.exe`, or a launcher process the root
    ended or saw restart.

  Each restart gets a `[launcher] restart N:` line. Starts that die before the root looks are
  counted too. When the title ends, a summary line gives the restarts, the starts of other
  images, and the starts that could not be opened.
- **Restarts are ended at most once more.** The first restart the root finds still running
  triggers one more end of the launcher's tree, including the restarts it knows. There is no
  loop: later restarts are only reported (`pp_launcher_restart_action`).
- **The sign-in is only logged.** The game's sign-in watch (`GameSignIn`, 0124) stays as a log
  line: `launcher: the game signed in at +N s`, and a dev build's `launcher` event.
- **The field is renamed `endLauncherAtFirstFrame`.** It stays compatibility-only: `over()`
  never takes it from a person. A value saved under 0124's name is not read.
- **Unchanged from 0124:**
  - never RDR2.exe or a process whose parent chain reaches it, so the game's own
    `SocialClubHelper.exe` is never ended;
  - RockstarService ends by itself;
  - dev and release builds alike.

## What it changes

- **The game runs without the launcher** from its first frame. Whether it still signs in to
  Social Club, and whether anything starts the launcher again, is what the next play records.
- **The job's completion port** is set for every title. It only queues messages, which the root
  reads and drops until a launcher end.
- **0012:** no UI, environment switch or driver entry point.

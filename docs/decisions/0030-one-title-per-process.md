# 0030: One title per app process; the session root's multi-title paths are removed

**Status:** accepted, 2026-09-29. Completes
[0029](0029-restart-after-each-game.md): it removes what
[0027](0027-titles-as-children-of-a-session-root.md) added so that one process
could play several games, and changes how
[0022](0022-stop-a-game-that-ran-the-pool-out.md) ends a game that ran the
JIT pool out. The session root itself, its job and the child-process fixes
(`patches/madeira-unix` 0039 to 0044) stay.

## Decision

- **A process plays one title.** Once its JIT pool is blessed, a Play in it
  is refused (`launch=refused session=spent`), whatever became of the launch.
  `wine_host_session_launch` takes one request per process. The session
  root (`playport-session.exe`) starts that one title in a job, waits for the
  job to empty, flushes the registry, reports the exit and then idles.
- **Removed:** the Play after the first in a running session and its pool
  check (`launch=refused pool=room`, PlayportKit
  `JitPool.hasRoomForNextTitle`, `roomForNextTitle`, `nextTitleHeadMB`,
  `nextTitleRoomMB`); judging a title by the pool refusals of its own launch
  (`JitPool.Use.since`); the per-case "spent" state (`Outcome.spent`,
  `WineHostRuntime.canStartTitle`, `wine_host_session_usable`); the undoing of
  an earlier title's variables; the root's loop over titles. `TitleLaunch.spent`
  is now simply "the pool was blessed". `WINE_HOST_ABI_VERSION` is 3.
- **No in-app stop.** A game still running 10 s after it ran the pool out no
  longer has its job ended (`wine_host_session_stop`, the root's `stop` file
  and `Outcome.Stop` are gone). The launch ends as *ran out of JIT memory*
  with `pool=exhausted:<part> still-running after_s=N`, and the restart that
  follows ends the game with the process.
- **If the restart fails**, the process plays nothing more: the alert says
  why, and the game's page offers Close Playport.

## Why

0029 restarts the app after every game because resetting a process's Wine
session, JIT pool and left-over threads is a long list of state to prove
clean. The paths above only ran when that restart failed, and then ran a
second title in exactly the state 0029 did not trust. A restart that fails
means LocalDevVPN is down, and reopening Playport from the Home Screen needs
the VPN for its JIT anyway, so the fallback bought little. The stop was
0022's way to end a game without ending the app. Now the app always restarts
after a game, and the restart ends it too.

**What stays, and why.** The root and its job are not multi-game code. A
launcher that starts the game and exits has not ended the title: the job
keeps the launch waiting until the game ends too, and the restart does not
cut it short. The root also puts the registry on disk before the restart, and
it owns the desktop window and the GDI handle table before any title runs, so
the title and every process it starts find them. madeira-unix 0039 to 0044
make child pseudo-processes start, draw, raise exceptions and be waited for;
launchers need them.

## What it costs

- With the VPN down after a game, the player must close and reopen Playport
  before the next game, which then waits for the VPN for its JIT.
- A game that ran the pool out and goes on running is ended only by the
  restart. If that fails, it goes on behind the alert until Playport is
  closed.
- A restart that fails, and the `session=spent` refusal after it, have not
  been run on the phone. The rest is in the
  [evidence record](../evidence/2026-09-29-one-title-per-process.md).

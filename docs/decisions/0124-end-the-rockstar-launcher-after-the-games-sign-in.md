# 0124: RDR2's Play ends the Rockstar launcher once the game has signed in

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-409): built directly, with no desktop
measurement first, in dev and release builds. The phone has not yet shown the trigger: in no
phone run has the game written its Social Club log
([evidence](../evidence/2026-10-19-rockstar-launcher-after-sign-in.md)). Amends
[0107](0107-windows-services-for-a-flagged-play.md),
[0112](0112-a-launchers-open-outlasts-a-pool-exhaustion.md) and
[0114](0114-trim-social-clubs-chromium-and-the-launchers-threads.md) as below.
[PLA-409](https://linear.app/playportdev/issue/PLA-409).
Amended by [0125](0125-end-the-whole-rockstar-launcher-at-the-games-first-frame.md): the whole
launcher tree ends at the game's first frame, in one step, and the game's sign-in is only logged;
the field is `endLauncherAtFirstFrame`.

## Context

Red Dead Redemption 2's Steam copy starts the Rockstar Games Launcher, which signs the game in.
After that the launcher's tree stays alive for the whole Play: `Launcher.exe`, its error
handler, its Social Club CEF browser and renderers. In every RDR2 play on the phone, that tree
held most of the JIT pool and of FEX's host band.

On desktop, the game logs `Signed in online to profile …` to its own Social Club log
(`Documents\Rockstar Games\Social Club\socialclub.log`, UTF-16LE) at each sign-in. When the
launcher is gone, the game signs in again through its own CEF. On desktop, RDR2.exe is the
launcher's child, so ending the launcher's process tree would end the game too.

## Decision

- **The compatibility table carries it.** `endLauncherAfterSignIn: true` is set for `app-1174180`.
  - It is the table's alone: `LaunchSettings.over()` always takes the default's value and drops a
    person's, with or without a default. No saved setting, `set:` or `--settings` reaches it, and
    no page shows it.
  - It is not an ordinary LaunchSettings override, because a person-settable field with no UI row
    would be a driver-only entry point (0012). Ending a publisher's launcher in the middle of a
    Play is per-title compatibility behaviour, not a player's choice.
  - It applies in dev and release builds.
- **Watching for the sign-in** (`LaunchCoordinator`, PlayportKit `GameSignIn`):
  - When the title starts, the app reads the game's log as a baseline; the Rockstar launcher's
    `signIn` names the log and the line.
  - Every 2 s wait slice reads the log again. The first line of this Play that starts with
    `Signed in online to profile` counts.
  - A file the game wrote anew counts whole. A file that starts with the baseline counts only
    from where the baseline ends.
  - Only the fixed text is matched. Nothing of the log is logged or kept.
- **Ending the launcher** (`PP_CONTROL_END_LAUNCHER`, `app/SessionRoot/launcher_end.h`). The
  control carries no names. The session root ends processes in the title's job one at a time,
  never with a tree-kill:
  - first `Launcher.exe` and `RockstarErrorHandler.exe`;
  - 10 s later, each `SocialClubHelper.exe` still alive whose parent chain ends at a process it
    ended;
  - never `RDR2.exe` or any process whose parent chain reaches it.

  Every step is a `session: … [launcher]` line, and the app logs `title: launcher: …`.
- **RockstarService** is left to end by itself, as it does on desktop. 0107's services still
  stop at the title's end.

## What it changes

- **0107:** none of its services is ended early.
- **0112:** the launcher's Open (no game) never sees a game sign in and is unchanged.
- **0114:** the CEF trims stay.
- **0108:** RDR2 keeps its 896 MiB pool.
- **0012:** no UI, environment switch or driver entry point. The driver only sees the lines.

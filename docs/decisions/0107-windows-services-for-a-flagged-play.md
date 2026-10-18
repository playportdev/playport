# 0107: Windows services for a play that needs them

**Status:** accepted, 2026-10-16, by the supervisor of the publisher-launchers run (design A of
chunk 2, step 2), implementing the owner's D5 in the
[launchers plan](../plans/2026-10-12-launchers.md#owner-decisions) ("only for a play whose
launcher or title needs them"). [PLA-275](https://linear.app/playportdev/issue/PLA-275),
[PLA-254](https://linear.app/playportdev/issue/PLA-254). Amends
[0080](0080-prefix-wineboot-parity.md) for one service entry.

## Context

An app process runs one session whose only Wine main process is the session root (decisions
0027, 0030). No services.exe runs, so no SCM answers: `\pipe\svcctl` does not exist,
`OpenSCManager` fails, and COM's `start_rpcss` cannot start rpcss. The prefix seed holds no
service entry (0080).

The Rockstar Games Launcher needs the SCM:

- its installer runs `RockstarService.exe install`, which fails with exit 1 without one, and the
  installer then ends in an error box (run `20261015T234109`,
  [evidence](../evidence/2026-10-15-rockstar-stage0-phone.md));
- the launcher starts that service through the SCM before its sign-in page, and shows code 135
  without it ([Stage R](../evidence/2026-10-15-rockstar-launcher-recon.md)).

## Decision

- **A per-game launch setting, `windowsServices`**, is off unless set.
  - The compatibility table (0074) turns it on for Red Dead Redemption 2 (`app-1174180`), whose
    Steam copy starts the Rockstar Games Launcher. A launcher's own play (Settings › Launchers,
    PLA-271) is to turn it on as well.
  - A dev build shows it as Game options › Developer › Windows services. A release build follows
    the table.
- **The session root starts services.exe** for such a play, before its prerequisites and title
  (session request `PP_REQUEST_SERVICES`, wine_host ABI 8).
  - It starts outside the title's job.
  - The root waits up to 10 s for Wine's `__wine_SvcctlStarted` event.
  - It logs `[service]` lines: the start; each service the SCM lists for the first time; each
    change of state, with the process id; each stop, with its exit codes.
- **Services end with the play.** Before the root reports the title's end, it does this, in
  order:
  1. asks every running service to stop, waiting 3 s at most;
  2. ends any service process still running;
  3. ends services.exe.

  The app restarts after every title anyway (0029), which also covers a fault.
- **RpcSs's service entry** (wine.inf's `[RpcSsService]`: `rpcss.exe`, type 32, demand start) is
  written into the prefix for such a play, as a top-up: only where the prefix lacks it. It is
  never removed. It is harmless where no SCM runs, since nothing else starts it. This is the one
  service entry outside 0080's seed.
- **Every other play is unchanged:** no services.exe, no `[service]` line, no registry write.

## Costs and limits

- services.exe and each service are pseudo-processes. They take pool head, threads and start time
  that a plain game does not pay, which is why this is per game.
- Services get only what Wine's services.exe does: own-process services, demand and auto start.
  Auto-start services start with the SCM.
- An installer that registers a service leaves its entry in the prefix. It runs only in a play
  with services on.

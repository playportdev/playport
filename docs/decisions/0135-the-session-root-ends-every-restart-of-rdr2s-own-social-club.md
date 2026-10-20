# 0135: After the game's Social Club end, the session root ends every restart of it

**Status:** accepted, 2026-10-20, as part of the dev experiment of
[0133](0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md), which it amends
(PLA-413, PLA-364). Still dev only, off by default, no compatibility default.

## Context

- **0133 missed restarts.** It ended the game's restarts as the title's job reported them
  (`JOB_OBJECT_MSG_NEW_PROCESS`). The message can come before the process list names the new
  process, so the root could not tell it was the game's helper and left it running: runs
  `20261020T043106-rdr2-sc4` and `20261020T081946-rdr2-r3`. In r3 that restarted pair (pids 0748,
  0818) ran through the whole gameplay stretch, about 550 MB resident plus compressed
  (`[proc-mem]`), until the memory kill.
- **The game restarts its helper about every 5 s for as long as it is gone.** With a sweep and
  0133's cap of 8, run `20261020T092459-rdr2-e2b` ended 8 restarts in 39 s and the 9th ran on.
  The game's `socialclub.log` shows the loop: `Main browser connection lost!`, `Signed out.`,
  `Entering State: 'WAIT_BROWSER'`, `[ERROR] Browser subprocess no longer running, entering error
  state`, again every ~5 s.

## Decision

- **A sweep, not the job's messages.** After the end, the session root looks at the process list
  every 250 ms (`game_sc_sweep`, `GAME_SC_SWEEP_MS`) and ends each `SocialClubHelper.exe` whose
  parent chain reaches RDR2.exe and that it has not ended already
  (`pp_game_social_club_restart`, `launcher_end.h`, tested in `app/tests/launcher_end_test.c`).
- **Every restart is ended, with no cap.** The first 8 ends are logged one by one, then every
  10th; the title's end logs the count and how many could not be ended.
- Ending each start within a quarter of a second is how the root refuses it: Wine gives the root
  no hook at process creation, and a started helper has not yet loaded CEF by then.

## Costs and risks

As 0133: the game's Social Club overlay and cloud-save sync are gone for the rest of the play, and
the game stays signed out of Social Club (`Signed out.` in its log) while it retries. It goes on
retrying, a process start every ~5 s, which costs a little CPU.

## What the runs showed

[Evidence](../evidence/2026-10-20-rdr2-gameplay-memory.md): in `20261020T095216-rdr2-e3b`, 30
restarts were ended in 153 s and no `SocialClubHelper.exe` was alive at the end; RDR2 went on into
gameplay with no Social Club box. Every RDR2 Story run still ended at the memory limit or by the
phone (section 2 of the evidence).

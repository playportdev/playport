# 0138: A dev build may refuse RDR2's later Social Club helper starts at process creation

**Status:** accepted, 2026-10-20, as a dev experiment, approved by the supervisor for the owner
(PLA-413, PLA-364). Amends [0109](0109-chromium-switches-for-a-cef-browser.md) ("no child is
refused") and [0135](0135-the-session-root-ends-every-restart-of-rdr2s-own-social-club.md) (the
root has no hook at process creation). Off by default, no compatibility default.

## Context

- **The game restarts its helper for the rest of the play.** After 0133's end, RDR2 starts
  `SocialClubHelper.exe` again about every 5 s, and 0135's sweep ends each start about a quarter of
  a second later: 30 starts in 153 s in run `20261020T095216-rdr2-e3b`. Each is a new
  pseudo-process: image copies, FEX start-up, threads, a master socket to the wineserver.
- **The churn broke the session.** The 56th start in runs `20261020T105836-rdr2-s1` and
  `20261020T112521-rdr2-s2` found the 64-entry master socket table full, and the game stopped
  drawing ([evidence](../evidence/2026-10-20-rdr2-proc-socket-table.md)). madeira-unix 0176 reuses
  the entries; the starts are still pure cost.
- **The game plays on without its helper.** Its `socialclub.log` after the end shows `Signed out.`
  and the retry loop, and RDR2 went on into gameplay in e3b and e4.

## Decision

- **Refuse at creation (madeira-unix 0177).** With `PLAYPORT_REFUSE_GAME_SC_RESTART=1` in the
  environment, `NtCreateUserProcess` lets the game's first `SocialClubHelper.exe` start go ahead and
  fails every later one with `STATUS_ACCESS_DENIED` (`pp_game_sc_refuse.h`, tested in
  `tools/tests/test_game_sc_refuse.py`). Only a start whose creator's image is `RDR2.exe` counts,
  per game process; the launcher's own helper and Chromium's `--type=` children are never refused.
  The first 9 refusals are logged (`[game-sc] refused`), then every 10th.
- **Dev only.** Settings › Developer › Refuse the game's Social Club restarts (experiment)
  (`refuseGameSocialClubRestart`). The app sets the variable for a Play only when that switch and
  0133's end are both on and the title's launcher ends at the game's sign-in (RDR2); otherwise it
  removes it. The release app never sets it.
- 0135's sweep stays: it ends the game's first helper pair (0133) and any start this misses.

## Costs and risks

As 0133: no Social Club overlay or cloud-save sync for the rest of the play. A first helper start
that fails by itself before the sign-in leaves the game signed out from the start. The game may log
or retry the refused start; a phone run has to show that it plays on.

# 0155: Allow RDR2's Social Club restart after a re-sign-in that follows its end

**Status:** accepted, 2026-10-21, by the owner (option 1 of the PLA-413 black-loading-screen
analysis), with the supervisor's details (two detectors, the root's ALLOW control, two allows).
Amends [0138](0138-refuse-rdr2s-social-club-restarts-at-process-creation.md),
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md) and
[0153](0153-rdr2s-settings-are-every-games-defaults.md).
[PLA-413](https://linear.app/playportdev/issue/PLA-413).

## Context

- **The end is the same in the runs that play on and in the runs that do not.** Nine RDR2 runs
  ended the game's own Social Club under 0141's rule. In five the game played on. In four (x8, qp1, qe2c, xs1)
  the screen stayed on the game's own loading spinner at 60 fps for minutes. The kill, the
  refusals (0138) and the timing were the same in both groups.
- **The game reads the end two ways.** In the stuck runs it treated the helper's end as a sign-out:
  - at once, it opened a sign-in connection; 1.1 to 1.8 s later it got the 2,390 B reply that
    otherwise follows only its first sign-in;
  - 21 to 32 s after the end, it called ISteamApps GetCurrentGameLanguage in a burst of four;
  - at 36 s, it started a load (a new DirectSound device, Bink).

  That load needs the helper, which 0138 refused every 5 s. No run that played on did any of
  this within 60 s of the end.
- **ntdll is not the only block.** After the end, the session root ends every new game helper
  every 250 ms (decision 0135's sweep). A second END control did nothing.

## Decision

- **After each end the app watches for a re-sign-in** (`GameSocialClubReSignIn`, PlayportKit).
  Two detectors, the first to fire wins:
  - **socialclub.log**: a `Signed in online` line beyond those the log held at the end
    (`GameSignIn.Watch.signIns`);
  - **steam-language**: four or more GetCurrentGameLanguage calls in the steamclient trace's
    summaries within 60 s of the end (dev builds only: a release build has no trace).
- **At a re-sign-in it allows the restart.**
  1. The app sends the root the new control `PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB` (11). The root
     stops its sweep and re-arms END (`pp_game_sc_control`, `launcher_end.h`).
  2. Only after the root has answered that it stopped (`*count` 1), the app calls
     `wine_host_game_sc_allow_restarts(1)` (wine_host ABI 11). ntdll lets the game's later helper
     starts go ahead (madeira-unix 0213).

  The ALLOW goes first so that a helper started in between is not swept. A root that does not
  stop (an older binary, or no end to undo) leaves restarts refused, and the app says so.
- **The allow ends at the next sign-in line after it, or 90 s after it.** Then ntdll refuses
  again. The helper that started keeps running.
- **The end may run again.** Under 0141's rule, a re-end counts its 120 s from the new sign-in
  (the line, or the allow's time when no line came). A re-end goes through END, which ends the
  running helpers and starts the sweep again.
- **At most two allows a Play**, counted by both the app and the root, so at most two re-ends. A
  third re-sign-in is only logged.
- **The lines,** in fixed text:
  - `[game-sc] re-sign-in after end (socialclub.log|steam-language)`, which names the detector;
  - `[game-sc] re-sign-in after end: allowing restart`;
  - ntdll's `[game-sc] restart allowed start N`;
  - `[game-sc] signed in again (socialclub.log): restarts refused again`, or the 90 s variant;
  - `[game-sc] re-ended after re-sign-in`;
  - the root's `[game-sc] restarts allowed: the sweep stops (allow N, decision 0155)`.

  A run with no re-sign-in logs none of them and behaves as before.

## Costs and risks

- **socialclub.log is unproven as a detector.** No pulled log shows whether the game writes a new
  `Signed in online` line after the end: run f2's log (0141) went to `FAILED` and `Signed out.`
  instead. The steam-language fallback is a correlation from 4 runs against 5. Run x8 called
  GetCurrentGameLanguage every frame for a while before its end, so a run in that state would
  fire it at once.
- **An allowed helper holds its memory again** (about 550 MB) until a re-end. That re-end can come
  only 120 s after the re-sign-in.
- **Not checked on the phone:** whether the reload then finishes. Until a phone run shows that,
  this is a hypothesis.

# 0155: Allow RDR2's Social Club restart after a re-sign-in that follows its end

**Status:** accepted, 2026-10-21, by the owner (option 1 of the PLA-413 black-loading-screen
analysis), with the supervisor's details (two detectors, the root's ALLOW control, two allows).
Amends [0138](0138-refuse-rdr2s-social-club-restarts-at-process-creation.md),
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md) and
[0153](0153-rdr2s-settings-are-every-games-defaults.md).
[PLA-413](https://linear.app/playportdev/issue/PLA-413).

**Amended 2026-10-30 (owner, PLA-476, run `20261030T141431-rdr2-p476d1`):** the reload ends
on the title menu, and an allow needs headroom ([below](#amendment-2026-10-30-an-allow-needs-headroom)).

**Amended again 2026-10-30 (owner, PLA-476, run `20261030T184300-rdr2-p476l13`):** an allow lets
one helper start through ([below](#amendment-2-2026-10-30-one-start-per-allow)).

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

## Amendment 2026-10-30: an allow needs headroom

By the owner, 2026-10-30 (PLA-476), from run d1
([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#d1-same-ipa-default-baseline)).

### What d1 showed

- The game left the cabin by itself after 0141's end: GetCurrentGameLanguage ×4 at end+29–31 s,
  a new DirectSound device on its main thread at end+34 s, and 60 fps empty frames from
  end+36 s. 0155's steam-language allow came after these (end+36.5 s).
- With the restart allowed, the helper signed in at allow+25.8 s, and the load finished **on
  the title menu** (Story/Online), not in Story. The allow does not return a player to Story;
  it turns the black spinner into the title. This answers "whether the reload then finishes"
  above.
- The socialclub.log detector cannot fire first: its new `Signed in online` line is written by
  the allowed helper. A release build, which has no steamclient trace, never allows.
- Two allows at 7.6–7.8 GB (+400–530 MB each) ended the Play at the 8,192 MB limit (jetsam at
  +446 s).

### Amended decision

- **An allow needs headroom.** The app allows a restart only when the phys footprint plus
  600 MB (the measured helper with its sign-in, `GameSocialClubReSignIn.restartNeedMB`) is
  under the limit less 400 MB (0140's margin, `restartMarginMB`). Otherwise it logs
  `[game-sc] re-sign-in after end: no headroom (N MB), restart stays refused` and keeps the
  refusal; the game then stays on its loading spinner, as before 0155, instead of being ended
  by iOS. No limit read counts as no headroom.
- **A refusal for headroom stands for the rest of the Play**, as when the root does not stop
  its sweep: it spends no allow, the watch stops, and no re-end follows (nothing restarted).
  It is checked after the allow count, so a re-sign-in with no allow left still logs
  `no allow left`.
- The cap of two allows and the re-end rule are unchanged.

### Costs

- A play refused for headroom stays on the spinner and needs a person to quit it.
- A release build still has no working detector (follow-up: count GetCurrentGameLanguage in
  the steamclient provider without the trace).

## Amendment 2, 2026-10-30: one start per allow

By the owner, 2026-10-30 (PLA-476), from run l13 (`.work/ui-runs/20261030T184300-rdr2-p476l13`,
stock CEF with the Social Club layout, [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md)).

### What l13 showed

- The game's Social Club was ended at +280.6 s, in Story's cabin. The steam-language detector fired at
  +314.1 s (end+33.5), at a footprint of 6793 MB, so the headroom check passed, and the app allowed.
- **The game left Story before the restarts, as in d1.** Cabin frames ran to +318.6 s, empty 60 fps frames
  started at +319.5 s, and a new DirectSound mixer thread followed at +320.0 s. The black spinner showed
  from then on.
  - The sequence matches d1: language burst, then the DirectSound device, then empty frames, all 31–39 s
    after the end.
  - d1's leave came before its allow, so the allow is not what sends the game out of Story (inferred).
- **That one allow let five helper starts through** (starts 9–13, +318.6 to +362.2 s):
  - each helper got its layout slots;
  - each died 10–15 s later in Chromium's out-of-memory exit (`0xE0000008`, request 0 bytes) before it
    signed in. V8's 5 GiB reservation found no gap: at Story, the layout's window had a 515 MB largest
    hole;
  - the game started the next one 0.3 s after each exit.
- The allow lasts until a sign-in line or 90 s. No sign-in line came, so every start went ahead.
- The footprint rose from 6.9 to 7.6 GB, with compressed memory from 2.4 to 3.9 GB. The app was ended at
  +374.7 s at 7461 MB, with no crash file.

### Amended decision

- **An allow lets one helper start through.** ntdll refuses the game's later starts again as soon as one
  allowed start has gone ahead (`ppgsc_take_allow`, madeira-unix 0239). The line reads
  `[game-sc] restart allowed start N; the allow is used, later starts are refused`.
- A further restart needs a new re-sign-in, its own allow and its own headroom check.
- The cap of two allows a Play, the headroom rule, the allow's end at the next sign-in line or 90 s, and
  the re-end rule are unchanged. The app's own steps are unchanged.

### Costs

- If an allowed helper fails before it signs in, the game stays on its loading spinner, as it does without
  0155.
- In a stock-CEF layout play the allowed helper itself may not fit at Story (l13). The allow then costs one
  failed start, not a cascade.

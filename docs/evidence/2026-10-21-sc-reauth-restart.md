# RDR2: allow the Social Club restart after a re-sign-in that follows its end (PLA-413)

**Linear:** PLA-413. **Decision:** [0155](../decisions/0155-allow-rdr2s-social-club-restart-after-a-re-sign-in.md).
**IPA:** dev, built in the side worktree `.work/worktrees/screauth` (decision 0117) on branch
`screauth` rebased onto main `1030a6d`: `Playport-26.5-b09df78f.ipa`, sha256
`b09df78f2566ca7600a3355c3b25233c6a25b30af20854b42835586711d89dcc`. After the fast-forward into main
(`64e4d9e`), main's build gave `Playport-26.5-b24c29a3.ipa`, sha256
`b24c29a39780d53c757073b6b97769a470aa49f0bfb1c015906033cb67899fc1`; every phone run below used that.

**Phone result (section 7): the race did not fire in 3 RDR2 Story runs.** No re-sign-in after the
end, so no allow, and none of the new lines (no false positive). Whether the reload finishes once the
helper may restart, and which detector sees the re-sign-in, is still not shown.

## 1. The cause (from the read-only analysis)

Nine RDR2 runs ended the game's own Social Club under 0141's rule.
- In four of them (x8, qp1, qe2c, xs1), the game then:
  - signed in again at once (a TLS sign-in with the 2,390 B reply that otherwise follows only its
    first sign-in, 1.1 to 1.8 s after the end);
  - 21 to 32 s later, called GetCurrentGameLanguage four times;
  - at 36 s, started a load.

  That load waited for a helper that 0138 refused every 5 s, so it sat on its own spinner at 60 fps.
- The five runs that played on (qd1b, qe4, qe2d, g1, n2) did none of this within 60 s of the end.

Checked here in the pulled `s1-host.log` files, counting from the `[game-sc] done` line: each of qp1, qe2c and xs1 has one trace
summary with `ISteamApps008.GetCurrentGameLanguagex4` about 30 s after the end. The five fine runs
have none within 60 s; n2's first is at +284 s.

x8 called it every frame (5 to 7 per 250 ms summary, with RunFrame and SteamController). That started
before its end, so in x8 the fallback would fire at once.

## 2. What changed

| Where | What |
| --- | --- |
| madeira-unix 0213 | `pp_game_sc_refuse.h`: `ppgsc_set_allow` / `ppgsc_allowed`, an atomic in `struct ppgsc_state`. `process_ios.c`: the state is at file scope, and the new `ios_game_sc_allow_restarts(int)` sets it. While it is set, a start 0138 would refuse goes ahead, logged `[game-sc] restart allowed start N`. |
| `wine_host.h/.c` | ABI 11: `wine_host_game_sc_allow_restarts(int on)` |
| `session_protocol.h` | `PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB = 11`, valid with no arg |
| `launcher_end.h`, `playport-session.c` | `pp_game_sc_control`: END ends the helpers and starts the sweep, once until an ALLOW. ALLOW after an END stops the sweep and re-arms END, at most `PP_GAME_SC_MAX_ALLOWS` (2) a title, replying 1 when it stopped. Root lines: `[game-sc] restarts allowed: the sweep stops (allow N, decision 0155)` and `... nothing to stop` |
| PlayportKit `GameSignIn.Watch.signIns` | counts this Play's sign-in lines (`signedIn` is `signIns > 0`) |
| PlayportKit `GameSocialClubReSignIn` | the state machine: detectors, a 60 s window, a 90 s cap, two allows, the re-end's sign-in time |
| `GameSocialClubEnd`, `SteamClientHost` | the steamclient trace's summary lines feed a GetCurrentGameLanguage count |
| `LaunchCoordinator.LauncherEnd` | after each end: reads socialclub.log each slice and runs the machine. On `.allow` it sends ALLOW, and only with rc 0 and count 1 calls ntdll's allow; on `.refuseAgain` it clears that allow. A re-end runs 120 s after the new sign-in, near the limit |

App lines, only in a run where the game signs in again:
- `title: [game-sc] re-sign-in after end (socialclub.log)` or `(steam-language)`;
- `title: [game-sc] re-sign-in after end: allowing restart`;
- `title: [game-sc] signed in again (socialclub.log): restarts refused again`, or `... no new sign-in
  line 90 s after the allow: ...`;
- `title: [game-sc] re-ended after re-sign-in`;
- on failure, `... the session root did not stop its sweep (rc, n); restarts stay refused` or
  `... no allow left (2 used) ...`.

A dev build also emits a `launcher` run event with `state: game-social-club-allowed`, and the
detector and the allow's number.

## 3. Host checks

- `pp build` (side worktree): dev IPA above; verify-ipa 88 checks passed.
- `pp test`: all passed (section 5). `pp names`, `pp secrets`: clean.
- New or changed tests:
  - `tools/tests/test_game_sc_allow.py` applies 0177, 0212 and 0213's header, then checks
    refuse, allow, refuse again, start numbering and the NtCreateUserProcess wiring;
  - `app/tests/launcher_end_test.c`: the ALLOW/END state machine and the cap of 2;
  - `app/tests/session_protocol_test.c`: ALLOW valid only without an arg, and no kind past it;
  - `GameSocialClubReSignInTests`: a fine run gets no step; both detectors; the window, the cap and
    the re-end time; two allows; a refused ALLOW; trace-line parsing from the qe2c and x8 formats;
    sign-in line counting.

## 4. The phone test (for the main checkout)

1. `pp install --no-build` of this IPA, after the branch is rebased into main.
2. The Hollow Knight gate: `pp ui --play app-367520 --until first-frame+10 --shot`.
3. RDR2 Story, played to 6 minutes after the `[game-sc] done` line, repeated up to three times
   until the race fires (it fired in 4 of 9 runs).

What proves it, in the pulled `s1-host.log`:
- the race fired: `[game-sc] re-sign-in after end (…)`. The detector named says whether
  socialclub.log carries the re-sign-in (the analysis's open question);
- the restart: the root's `restarts allowed: the sweep stops (allow 1, …)`, then
  `[game-sc] re-sign-in after end: allowing restart`, then ntdll's
  `[game-sc] restart allowed start N`, with no `refused … start N+1` in between;
- the fix: the loading screen ends (screenshots after +40 s show the world, not the spinner, and
  `[kk-gpu]` drops from the 60 fps empty-frame rate to gameplay rates);
- a re-end, if the footprint gets near the limit: `[game-sc] re-ended after re-sign-in` at least
  120 s after the new sign-in;
- a run where the race does not fire has none of these lines.

## 5. Results

- `pp test` (full, with the Swift packages): all passed. PlayportKit ran 364 tests, 0 failures.
- Main's `.work` was not written by the copy. `find <main>/.work -path '*/worktrees' -prune -o -newer
  <marker> -print` (marker `.work/worktrees/screauth.marker`) listed 454 entries. All came from the
  main session's own work in that time: its phone runs, `ui-runs`, agent notes and `tmp/phone`.
  None is under `run`, `cache`, `inputs` or `cef-src`, and no file among them names the copy's
  path.
- The copy took reflinks of main's `cache`, `inputs`, `run`, `cef-src/notices` and
  `cef-src/out-stage-c`. It deleted `run/mesa/{ios,ios-gl}` and 8 meson build directories, and
  rewrote main's paths: 6,642 text files, 18 symlinks, 86 RUNPATHs.

## 6. Merge notes

- Branched from main `9bf627f` and rebased onto `1030a6d`. madeira-unix 0213 comes after 0212; the
  decision is 0155; wine_host ABI 10 → 11; session control 11.
- `app/artifacts.tsv`: only the `playport-session.exe` and `lib/libntdll_unix.a` rows. Neither
  file names a build path. `libdxmt_combined.a` and `libidevice_ffi.a` keep main's values, as
  0117 says. The main checkout's build confirms them: `./pp build` in main after the fast-forward
  left `app/artifacts.tsv` and `build/generated/` unchanged (verify-ipa 89 checks passed), and
  `./pp test` passed.

## 7. Phone results (main, IPA `b24c29a3`)

Phone: 80 %, on external power, 4.1–4.8 GB free before each run; unattended mode on. Hollow Knight
gate: `pp ui --play app-367520 --until first-frame+10 --shot`, first frame at +11.9 s; the screenshot
shows the title menu (Start Game, Options, …) under a notification banner. Run directory
`.work/ui-runs/20261021T205101`.

RDR2 Story with the defaults (`qarm.sh NAME ''`, `RUN_IPA=b24c29a3`, aspect 16:9, no stick input;
the scripted pad pressed only A on the PlayRDR2 launch box and A on the Story tab), each until first frame + `UNTIL`:

| Run | First frame | `[game-sc] done` | Played after done | Re-sign-in / allow lines | `[kk-gpu]` after done | Last screenshot | Peak footprint | Jetsam |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ra1 (`20261021T205254-rdr2-ra1`, UNTIL 540) | +91.6 s | ff +155 s | 385 s | none | 391 one-second lines, none at 55+ fps; 16–19 fps at the end | the cabin, Arthur on the bed | 7078 MB | none |
| ra2 (`20261021T210528-rdr2-ra2`, UNTIL 540) | +105.0 s | ff +184 s | 356 s | none | 364, none at 55+ fps; 17–19 fps | the cabin | 7516 MB | none |
| ra3 (`20261021T211752-rdr2-ra3`, UNTIL 600) | +114.4 s | ff +187 s | 413 s | none | 431, none at 55+ fps; 16–18 fps | the cabin | 7262 MB | none |

Every run ended the game's helpers once (`done: 2 ended of 4 processes in the job`), and ntdll then
refused its restarts every ~5 s to the end (start 80, 70 and 90). The dev steamclient trace shows no
GetCurrentGameLanguage call after the end in any run (all 45 trace lines naming it come before), so
the steam-language fallback had nothing to count, and the app wrote none of the section 2 lines.
Jetsam: no `JetsamEvent` report pulled for the day, and the app ran to the end of every run.

So these were three fine runs (the race fired in 4 of 9 before; 0 of 3 here, 4 of 12 in all):
- **no false positive**: neither detector fired without a re-sign-in;
- **socialclub.log**: not shown either way, since the game never signed in again;
- **steam-language**: not exercised; it exists only in a dev build (the steamclient trace is
  dev-only), so a release build relies on the socialclub.log detector alone. If a racing run shows
  only steam-language firing, a release-capable detector is needed (for example counting
  GetCurrentGameLanguage in the Swift steamclient provider itself, without the trace).

The fix itself (allow, restart, world drawn after about +40 s, re-end near the limit) stays unproven
on the phone until a run races.

## 8. Two more runs (main, IPA `41431327`, decision 0156)

The two RDR2 Story runs of [the launcher's exit code 0](2026-10-21-launcher-end-exit-0.md) (same
defaults, `UNTIL=600`, no press on a box since 0156 removed it) also played on past the end of the
game's own Social Club:

| Run | `[game-sc] done` | Played after done | Re-sign-in / allow lines | `[kk-gpu]` after done | Last screenshot | Peak footprint | Jetsam |
| --- | --- | --- | --- | --- | --- | --- | --- |
| lb1 (`20261021T220845-rdr2-lb1`) | ff +143 s | 482 s | none | 469 one-second lines, none at 55+ fps; 16–20 fps at the end | the cabin, Arthur on the bed | 7652 MB | none |
| lb2 (`20261021T222231-rdr2-lb2`) | ff +162 s | 463 s | none | 448, none at 55+ fps; 18–19 fps at the end | the cabin, Arthur on the bed | 7253 MB | none |

As in ra1–ra3: the helpers ended once (`done: 2 ended of 4 processes in the job`), ntdll refused
their restarts to the end (start 90), all 45 steamclient trace lines naming GetCurrentGameLanguage
come before the end, and none of the section 2 lines appeared. The race fired in 0 of 5 runs on
main (4 of 14 in all); the fix and both detectors stay unproven on the phone.

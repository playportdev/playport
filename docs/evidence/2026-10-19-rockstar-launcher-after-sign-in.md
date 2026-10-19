# Ending the Rockstar launcher after RDR2's sign-in

[PLA-409](https://linear.app/playportdev/issue/PLA-409),
[decision 0124](../decisions/0124-end-the-rockstar-launcher-after-the-games-sign-in.md).

## Host

- **PlayportKit `GameSignInTests`:**
  - The shipped table asks for the launcher's end for `app-1174180` only.
  - `over()` drops a person's saved value, with a default or without one.
  - The log watch reads a new file whole, counts an unchanged or rewritten earlier start's file
    as stale, counts only the text after the baseline in an appended file, and matches only the
    fixed text at a line's start. It reads a character still half written whole only once it
    is complete.
- **`app/tests/launcher_end_test.c`:** over RDR2's process tree, the first wave ends
  `Launcher.exe` and `RockstarErrorHandler.exe`. The second ends the launcher's Social Club
  browser and renderer. Neither ends RDR2.exe, its crash handler, its own Social Club helpers,
  or a `Launcher.exe` namesake under it. A parent cycle ends the walk.
- **`app/tests/session_protocol_test.c`:** `PP_CONTROL_END_LAUNCHER` is a control with no arg.
- `./pp test --quick` and the PlayportKit Swift tests pass. The session root builds with
  llvm-mingw.

## Phone

IPA `4c074ecdd4669aa8ca0ae193b0037f6104ea9d8b63b9de3e2050d1cf978a6637` (dev). The session ran
`.work/agent-notes/pla409/phone-session.sh`, with `phone-3.log` beside it. Nothing was pressed.

- **Hollow Knight** (run `20261019T135245`): first frame at +7.97 s.
- **Red Dead Redemption 2** (run `20261019T135313`):
  - first frame at +81.74 s; the run reached its bound of first frame +120 s;
  - pool head 336 MiB, tail 497 MiB, room 64 MiB, no refusal; band peak 4,880 MB;
  - the app logged `launcher: ends once the game signs in (decision 0124); its log is not there
    yet`, and no sign-in followed;
  - RDR2.exe started its crash handler but no Social Club helper of its own.

The phone's `C:\users\playport\Documents\Rockstar Games\Social Club\` holds only the launcher's
`socialclub_launcher.log`. No RDR2 run on the phone has reached the game's own Social Club
sign-in, so the trigger is not yet shown.

### A longer play

Run `20261019T140029` used the same IPA, played RDR2 only, pressed nothing, and was bounded at
first frame +600 s (`.work/agent-notes/pla409/phone-long.sh`):
- **First frame at +81.43 s.** The screenshot at 240 s shows RDR2's loading bar about
  five-sixths across, under the touch controls.
- **The app ended at +348 s**, before the bound, with no crash report.
- **Footprint:**
  - the last `[footprint]` lines read 7,063 MB by the full sampler, then 7,154, 7,262, 7,282 and
    7,311 MB by the fast one, against the 8,192 MB limit;
  - graphics rose from 696 to 1,168 MB in the last cycles;
  - an end at the memory limit (jetsam) is the likely cause, but no report shows it.
- **Pool and band at the last reading:** head 337 MiB, tail 513 MiB, room 47 MiB, no refusal;
  band 5,325 MB, peak 5,325, 262 threads, no refusal.
- **No sign-in.** The game wrote no `socialclub.log`, and RDR2.exe started no Social Club helper
  of its own. The app logged only `launcher: ends once the game signs in …; its log is not there
  yet`. The only `rgsc` lines are the launcher's: its `RGSCSystemTray` window and a pipe
  `chrome.rgsc_launcher_0` it could not open.
- **The last lines:**
  - RDR2's thread `0450` taking FEX-generated illegal-instruction exceptions that the game handles
    (`Passing through exception`);
  - Playport's steamclient trace of `ISteamUtils010.RunFrame`;
  - an rpmalloc span freed.

  The log has no network lines to read; this build does not log sockets.

The game had not reached its sign-in after about 5 min of loading, and the app ended near the
memory limit first. The launcher's end therefore remains unshown on the phone.

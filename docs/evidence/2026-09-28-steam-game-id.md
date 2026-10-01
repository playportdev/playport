# Steam's game id in a Steam game's launch, and Valve's per-game fixes back

**Date:** 2026-09-28. **Decision:** [0020](../decisions/0020-steam-game-id.md).
**Pins read:** `wine` 7b3fff7 (wine-11.18), `wine-port` 723d1bf, `wine-valve`
dc26e61 (ValveSoftware/wine `proton_11.0`), `madeira` 8c050d0. **Status:** done.
A Steam game now launches with `SteamAppId`, `SteamGameId` and
`STEAM_COMPAT_APP_ID` set to its app ID; `patches/wine-valve` has the twelve
`SteamGameId`-keyed picks back (127 patches). Hollow Knight reaches its menu
on the phone, the id reaches the game's Windows environment, and a reinstated
fix fires when its game's id is set. Dev IPA
`9f76f198d6e34c2e60bb84985a15f31e67a83314553e45514e5be35bcc2c1447`.

## 1. What Steam and Proton set, and what Valve's Wine reads

The Steam client starts a game with its app ID in `SteamAppId`, `SteamGameId`
and, for a compatibility tool, `STEAM_COMPAT_APP_ID`. Proton's script
(`proton` on ValveSoftware/Proton `proton_11.0`) copies its own environment
into Wine's (`class Session: self.env = dict(os.environ)`) and reads all three
itself: `SteamAppId` for `default_compat_config()`'s per-game options,
`STEAM_COMPAT_APP_ID` for others (`noxalia`), and `SteamGameId` for the rest
(DLL overrides, CPU topology, the log file's name, FEX's per-app profile).
It sets none of them; they come from Steam.

Valve's Wine reads two of them in the code `patches/wine-valve` carries:

| Variable | Read by (patch) | For |
| --- | --- | --- |
| `SteamGameId` | gdiplus (0014), advapi32 (0044), kernelbase (0059, 0078a, 0090a), msvcrt (0060, 0061), rsaenh (0063), user32 (0088), d2d1 (0096), ddraw (0108), d3d8 (0123) | the twelve picks below |
| `STEAM_COMPAT_APP_ID` | msi (0103 to 0107) | reporting an older Windows version to five games' redistributable installers; in the series since [wine-proton-rebase](2026-09-28-wine-proton-rebase.md), inert until now |

So the launch sets all three, each to the app ID in decimal, as Steam does
(PlayportKit `SteamGameID`). `SteamOverlayGameId` and Steam's other variables
(`SteamClientLaunch`, `SteamEnv`, `SteamPath`) are the client's and overlay's,
which the app does not run, and nothing in the series reads them.

## 2. The app

- `SteamGameID.environment(appID:)` gives the three for a title with a Steam
  app ID (a cohort title or a Steam install: `InstalledTitle.appID`, the `367520`
  of `app-367520`), none for a folder adoption found.
  `SteamGameID.launchEnvironment` layers them under the backend's variables
  and the player's for the game, each winning over the ones before it
  (unit test `testASteamGameRunsWithItsAppIDAsSteamsGameID`).
- `LibraryModel.play` passes the title's app ID through `TitleLaunch` to
  `LaunchCoordinator.Request.steamAppID`; `applyEnvironment` sets the merged
  variables before the runtime starts, and a later launch in the same process
  puts the old values back first, as before. It logs Steam's with their values
  (`title: environment: Steam's SteamAppId=…`), leaving out a name the player's
  or the backend's variables replace; the player's are logged by name only.
- No new control (decision 0012): the id is set for every Steam game, and the
  game's page already has Environment variables, which win. For a Steam game
  its footer now says that Playport sets the three to the app ID and that one
  set there replaces it.

## 3. The series

The ten clean picks review dropped as inert (wine-proton-rebase, section 5)
are back unchanged, with their files and places in the series:
`3b4421a7703` (0014, gdiplus, SpriteFontX in TouHou Makuka Sai, 882710 and
1031480), `70409daaac8` (0044, advapi32, DeathLoop 1252330), `1994def5d44`
(0059, kernelbase `WINE_SHRINK_ENV`, on by default for 431590),
`2b1f2b43060` and `16b8cdb5a96` (0060, 0061, msvcrt SSE2 off, Indiana Jones
and the Emperor's Tomb 560430, DarkStar One 12330), `a677f27c228` (0063,
rsaenh, SF6 1364780), `318c31b48ae` (0088, user32, Skyrim SE 489830),
`a814afa8315` (0096, d2d1, Spell Force 3 1416260), `19c6f062639` (0108, ddraw,
e-Racer 3600700), `c6a17f3d62a` (0123, d3d8, STAR WARS Starfighter 32350).

Two more were left out at the pick for the same reason (`valve-commits.tsv`:
"keyed on SteamGameId, which the app does not set"), and are picked now onto
the series in Valve's order:

- `a20b0e65ebe` (0078a, `Picked: resolved`): adds a `steamgameid` column to
  kernelbase's Chromium command-line table and a row for
  `UnrealCEFSubProcess.exe` in 2316580. It conflicted on the row above it,
  Red Tie Runner's (`0f02fcc46b8`, left out as Proton's GL work); the
  resolution adds only the new row.
- `c7e869c1f61` (0090a, `Picked: clean`): another `UnrealCEFSubProcess.exe`
  row, Alpha League 2684500. It applies once 0078a is in; only its context
  differs from Valve's (no Red Tie Runner row).

They are numbered 0078a and 0090a so the other files keep their names. The
series applied in order onto wine-11.18 plus `patches/wine-port` gives the
same tree as the cherry-picks, and `patches/wine-unix` and `patches/wine-pe`
apply on top. `ee597bb9541` (ntdll, mfc42 for one game) stays out: it is in
Proton's Steam-client class, not an inert pick, and its reworked form in
0047 was taken without it.

0059 reads `WINE_SHRINK_ENV` and `SteamGameId` into a 40-WCHAR buffer but
passes `sizeof(str)`, 80, as its size in characters, so a value of 41 to 79
characters (the player can set either on a game's page) overruns it on the
stack in every process of a Steam game. The bug is Valve's, and Proton ships
it too. Valve's patch stays unchanged; `patches/wine-pe` 0009, applied after
it, passes `ARRAY_SIZE(str)` to both calls.

## 4. Build

In this worktree's own build area, every tree from its pin (a first build):
`inputs sources unix pe fex dxmt vulkan steamapi stage app verify`, `verify`
passing. The committed build records are not in this change (Wine PE and
DXMT hash their build directory; AGENTS.md, "Committed build records"); this
build's are beside its IPA (`out/20260928-075220-9f76f198/records/`).

## 5. Phone

**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, charging,
shared with other agents' sessions. **IPA:** dev
`9f76f198d6e34c2e60bb84985a15f31e67a83314553e45514e5be35bcc2c1447` (branch
head `3045888`), installed in place. The installed titles are En Garde!
(1654660), Hollow Knight (367520) and The Witcher 3 (292030); no reinstated
fix names any of them, so none changes what they run. Run directories are in
this worktree's `$PLAYPORT_BUILD/ui-runs/`.

| Run | What | Timeline | Result |
| --- | --- | --- | --- |
| `20260928T075807` | `--settings 'app-367520:{}' --play app-367520 --until first-frame+10 --shot` | JIT 3.25 s, game start +3.94 s, first frame +10.66 s | the main menu, HUD 117.99 FPS, GPU 6.47 ms, `DXMT D3D11 FL_11_1` |
| `20260928T075859` | the same with the player's `SteamGameId=431590` | JIT 3.32 s, game start +4.05 s, first frame +11.12 s | the main menu |
| `20260928T075945` | `--action open:app-367520#graphics --shot-each-action` | | the page's footer (below) |

**The id reaches the game.** The default play's `pull/s1-host.log`:

```
title: environment: Steam's SteamAppId=367520, SteamGameId=367520, STEAM_COMPAT_APP_ID=367520
[iOS env] processing: SteamAppId=367520
[iOS env] INCLUDED: SteamAppId=367520
[iOS env] processing: SteamGameId=367520
[iOS env] INCLUDED: SteamGameId=367520
```

The `[iOS env]` lines are Madeira's `env_ios.c` building the Windows
environment from the process's: it logs the `Steam*` names it includes, so
`STEAM_COMPAT_APP_ID`, which it includes the same way, has no line. No
`HACK` line appears in this run: no fix names 367520.

**A reinstated fix applies when its game's id is set.** No installed title
is named by one, so the second play sets the player's `SteamGameId` to
431590, the game 0059 (`1994def5d44`, `WINE_SHRINK_ENV`) names, on Hollow
Knight's page. Its log:

```
title: environment: Steam's SteamAppId=367520, STEAM_COMPAT_APP_ID=367520
title: environment: the player's SteamGameId
[iOS env] INCLUDED: SteamGameId=431590
0024:err:process:hack_shrink_environment HACK: shrinking environment size.
```

kernelbase read `SteamGameId` from the game's environment and turned the fix
on at the first `GetEnvironmentStringsW` call in the game's process, and
the player's value replaced Steam's, as the launch order says. The game
reached its menu with it on. The page (`action-01-open_app-367520_graphics.png`)
shows that session's variable and the footer: "Playport sets SteamAppId,
SteamGameId, STEAM_COMPAT_APP_ID to 367520, the game's Steam app ID, as Steam
does; one set here replaces it." The session's `--settings` are undone at the
app's next launch outside it.

**First frame.** 10.66 s and 11.12 s (the second with the fix above on). The
[wine-proton-rebase](2026-09-28-wine-proton-rebase.md) record measured
Hollow Knight's start as two modes, 9.32 ± 0.35 s and 10.36 ± 0.30 s, on the
series IPA; section 5.1 has further plays of this IPA. For every other game
the picks cost an environment read or none: each tests its game's id once,
at the call it changes.

### 5.1 More plays

Three more plays of the same IPA, `--settings 'app-367520:{}' --play
app-367520 --until first-frame+3`, each logging Steam's three at 367520, in
the next session after another agent's `pp perf` (the phone `serious` at each
launch):

| Run | JIT | Game start | First frame |
| --- | --- | --- | --- |
| `20260928T081506` | 3.10 s | +3.80 s | +9.53 s |
| `20260928T081541` | 3.15 s | +3.84 s | +10.30 s |
| `20260928T081617` | 3.23 s | +3.87 s | +10.29 s |

With the two plays above (the first `nominal` at launch, the second `fair`),
the five are one in the short mode and four in or about the long one, as the
series IPA's were (8 of 13 long). Nothing in this change runs for Hollow
Knight beyond the environment reads.

### 5.2 With patch 0009

The branch head with `patches/wine-pe` 0009 (`77d0d38`), built in another
checkout into a dev IPA
`bc6324682df034f55d6b934d582aa43cb8d30edc79c93c03c6e039a4759155bd`
(`provenance.txt`: superproject `77d0d38`; `pe` to `verify` passing, so 0009
applies and builds), installed and played in one session. Run directories are
in that checkout's `$PLAYPORT_BUILD/ui-runs/`.

| Run | What | Timeline | Result |
| --- | --- | --- | --- |
| `20260928T102050` | `--settings 'app-367520:{}' --play app-367520 --until first-frame+10 --shot` | JIT 3.43 s, game start +3.99 s, first frame +8.96 s | the main menu; the log has Steam's three at 367520 and `INCLUDED: SteamGameId=367520` |
| `20260928T102134` | the player's `SteamGameId=431590` | first frame +9.22 s | the log has `the player's SteamGameId`, `INCLUDED: SteamGameId=431590` and `hack_shrink_environment HACK: shrinking environment size.` |
| `20260928T102216` | the player's `SteamGameId` set to 60 nines, the length 0009 guards | first frame +9.56 s, ran on 10 s | no crash; the log has `INCLUDED: SteamGameId=` with the 60 digits |

The page footer was not shown again on this IPA; `GameDetailView.swift` is
unchanged since `3045888` (section 5). The backend's variables over Steam's
are covered by the PlayportKit test
`testASteamGameRunsWithItsAppIDAsSteamsGameID`, not by a play.

## 6. Judgement calls

- **Three variables, not one.** Valve's fixes in the series need
  `SteamGameId` and `STEAM_COMPAT_APP_ID`; `SteamAppId` is set too because
  Steam sets it beside them and Proton, and a game's own code, read it. A
  launch that set only some would be one no game has run under.
- **Automatic, overridable on the game's page.** The captain's answer was to
  set the id per title; the existing Environment variables on the game's page
  are the override, with no new control.
- **The two left out at the pick come back too.** They were left out for the
  same reason as the ten; one needed its conflict resolved.
- **No title of the cohort is a target.** The proof that a fix applies uses
  the player's override on Hollow Knight with the id of the one fix that
  touches every game's start-up and is harmless to it (it only drops Linux
  and Steam-runtime variables from the environment copy).

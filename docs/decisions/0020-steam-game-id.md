# 0020: A Steam game runs with Steam's game id, so Valve's per-game fixes apply

**Status:** accepted, 2026-09-28. Builds on
[0018](0018-valve-wine-as-a-series.md), whose review left out Valve's
per-game fixes that only take effect through Steam's game id. The
measurements are in the [evidence record](../evidence/2026-09-28-steam-game-id.md).

## Decision

- A title with a Steam app ID (a cohort title or a Steam install) launches with `SteamAppId`, `SteamGameId` and
  `STEAM_COMPAT_APP_ID` set to that ID in decimal: the variables the Steam
  client sets for a game it starts, which Proton's script copies into Wine's
  environment unchanged (`Session.env = dict(os.environ)`) and reads itself.
  A title with no app ID (a folder adoption found) gets none of them.
- They are set by the launch (PlayportKit `SteamGameID`, `LaunchCoordinator`),
  automatically, with no switch. The backend's variables go over them and the
  player's variables for the game (the game's page, Environment variables) over
  both, so a player can replace or clear the id there; the page's footer names
  the three variables and the ID for a Steam game. No other entry point
  ([0012](0012-the-ui-is-the-only-entry-point.md)).
- `patches/wine-valve` carries Valve's picks keyed on the id again: the ten
  that 0018's review dropped as inert, and the two that were left out at the
  pick for the same reason (a column of `SteamGameId`s in kernelbase's
  Chromium command-line table, and one game on it).

## Why

Valve's Wine keys a class of per-game fixes on `SteamGameId` (and msi's
Windows-version hacks on `STEAM_COMPAT_APP_ID`). Without the variables the
fixes compile and do nothing, so 0018 left them out. Setting the id the way
Steam does turns them on for exactly the games they name and for no other, so
they cost nothing elsewhere. Proton itself reads all three (`SteamAppId` for its
default compat options, `STEAM_COMPAT_APP_ID` for others, `SteamGameId`
everywhere else), and a game's own code may read `SteamAppId` or
`SteamGameId` as a sign that Steam started it; setting only one would be a
Proton no game has run under. `SteamOverlayGameId` and Steam's other
variables are the Steam client's and overlay's, which the app does not run.

An app ID is public (it is in the store URL), so logging it and passing it to
the guest does not cross [0004](0004-steam-session-boundary.md)'s boundary.

## What it costs

- A per-game fix now runs for its game on this runtime, where Valve never
  tested it. Each names a game by ID, and the evidence record lists them; a fix
  that misbehaves here is dropped from the series with the reason recorded,
  and meanwhile a player can clear `SteamGameId` for the game on its page.
- A title's launch environment differs from Proton's in what Steam sets
  besides these three (`SteamClientLaunch`, `SteamEnv`, `SteamPath` and the
  like); nothing in the series reads those.
- When `patches/wine-valve` is re-picked (0018), `SteamGameId`- and
  `STEAM_COMPAT_APP_ID`-keyed commits are taken on their merits like any
  other, no longer left out as inert.

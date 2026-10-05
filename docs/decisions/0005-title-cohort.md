# 0005: Title cohort

**Status:** accepted, 2026-09-24; extended by [0047](0047-i386-titles-on-vulkan.md)
(i386 Direct3D 9 titles, on Vulkan)

## Decision

Titles used to test Playport are chosen by a scorecard and pinned exactly.
The cohort is **x86-64, Direct3D 11** titles only, legally owned on the test
account. The first pinned title is Hollow Knight.

## Scorecard (every item is a hard requirement)

- Owned or purchasable on the test account; no third-party launcher,
  anti-cheat or mandatory online play.
- The guest architecture passes the probe ladder (x86-64; 32-bit titles cannot
  run, [0003](0003-runtime-backend.md)).
- The graphics API passes the G2 graphics probe (Direct3D 10/11).
- The Steamworks behaviour it needs is supplied without bypassing ownership.
- A known local save path and a deterministic save-and-reload scenario.
- A benchmark scenario reachable without a long tutorial or a network
  dependency.
- Installed size and memory fit the measured headroom (the ladder's
  `available_memory_min_mb` floor is 2560 MiB).

A title that fails an item is replaced, never waived.

## Pinning

Each title is pinned by Steam app ID, depot IDs, manifest ID, build ID,
branch, language, executable and arguments, required Steamworks interfaces,
save path and installed size. The installed files are checked against Steam's
own depot manifest (`harness/titles/steam-manifest-check.py`) and staged with
a committed checksum list.

## Hollow Knight

| Field | Value |
| --- | --- |
| App / depot / manifest | 367520 / 367521 (Windows) / 257781644874438846 |
| Build / branch / language | 22529139 / public / one all-language depot |
| Executable, arguments | `hollow_knight.exe`; `-logFile <path>` to get a player log |
| Architecture, graphics | x86-64 (Unity, Mono); Direct3D 11 |
| Steamworks | `SteamAPI` init, callbacks and shutdown, `SteamUserStats`, `SteamFriends.GetPersonaName`, `SteamUtils`; no Steam Cloud |
| Save path | `%USERPROFILE%\AppData\LocalLow\Team Cherry\Hollow Knight\user*.dat` |
| Installed size | 5,231,995,691 bytes |
| Checksum list | `app/PlayportKit/Titles/hollow-knight-367520-22529139.sha256` |

The benchmark scenario is still to be written. Further titles join by the
same scorecard.

## The Witcher 3 (pinned 2026-09-25, scorecard open)

Pinned so the library adopts and launches a staged copy; it has not yet
passed the scorecard on this runtime. It plays from the library with the
entry's own `jumbo-mb` and `screen`, and staging hides the game's own
`msvcr110.dll` and `xinput1_3.dll`; how it got there is in
[the setup record](../evidence/2026-09-25-witcher3-setup.md). The benchmark
and save scenarios are still to be written.

| Field | Value |
| --- | --- |
| App / build / branch | 292030 / 3280809 / `classic` (patch 1.32) |
| Depots / manifests | 23, as in `app/PlayportKit/Titles/titles.json`; English voice |
| Executable, arguments | `bin\x64\witcher3.exe`, none |
| madeira.cfg keys | `jumbo-mb = 32768` (per launch, over the shared file) |
| Screen | `720`: the panel's aspect at 720 rows (1.32 has no render scale) |
| Architecture, graphics | x86-64; Direct3D 11 |
| Steamworks | `bin\ddi\Steam.dll` loads `steam_api64` by path |
| Save path | `%USERPROFILE%\Documents\The Witcher 3\gamesaves` |
| Installed size | 41,585,389,035 bytes, 2,459 files |
| Checksum list | `app/PlayportKit/Titles/witcher3-292030-3280809.sha256` |

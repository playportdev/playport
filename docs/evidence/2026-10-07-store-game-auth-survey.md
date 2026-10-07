# Store game auth: what the owner's games need at launch (survey)

**Date:** 2026-10-07. **Plan:** [games sign in to their store](../plans/finished.md#games-sign-in-to-their-store), step 0.
**Decisions:** [0004](../decisions/0004-steam-session-boundary.md), [0017](../decisions/0017-encrypted-app-ticket.md),
[0058](../decisions/0058-store-sessions.md). Workstation only; no phone, no IPA.

Marked **measured** (read from a manifest, a binary or the live service on 2026-10-07) or
**inferred** (from public documentation or the game's known design, not checked here).
Epic was read with the workstation's Epic session from plan 3.1 (still valid, so not refreshed);
GOG from GOG's public content service with the owned list saved in plan 2.1; Steam has no
workstation session (below). No ticket, token or account ID is in this record.

## Epic (34 games)

Measured: each game's live Windows manifest (catalogue attributes as in
[the Epic evidence](2026-10-06-epic-games.md)). "EOS SDK" means `EOSSDK-Win64-Shipping.dll`
or `EOSSDK-Win32-Shipping.dll` is in the manifest; "Anti-cheat" means EasyAntiCheat or BattlEye
files (only EasyAntiCheat was found). Installed size is the manifest's file total.

| Game | Ownership token | Runs offline | EOS SDK | Anti-cheat | Other launcher | Steam / Galaxy DLL | Installed |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Borderlands 3 | yes | yes | – | – | – | – | 102.7 GB |
| Cities Skylines | – | yes | Win64 | – | – | – | 20.5 GB |
| Death's Door | – | yes | – | – | – | steam_api, Galaxy64 | 3.9 GB |
| Elite Dangerous | – | yes | Win64 | – | Frontier's (`EDLaunch.exe`, a Frontier account) | – | 58.1 GB |
| Farming Simulator 19 | – | yes | Win64 | – | – | – | 15.5 GB |
| Football Manager 2022 (JSON manifest) | yes | yes | Win64 | – | – | steam_api | 6.4 GB |
| Football Manager 2022 Editor (JSON manifest) | yes | yes | Win64 | – | – | steam_api | 65 MB |
| Football Manager 2022 Resource Archiver (JSON manifest) | yes | yes | Win64 | – | – | steam_api | 38 MB |
| Fortnite | – | – | Win64 | EasyAntiCheat | Epic's access control; a bootstrapper | – | 159.4 GB |
| House of Golf 2 | – | – | Win64 | – | – | steam_api, Galaxy64 | 21.9 GB |
| Jurassic World Evolution | yes | **no** | Win64 | – | – | – | 8.0 GB |
| Killing Floor 2 | – | yes | Win64 | – | – | steam_api | 102.0 GB |
| KillingFloor2Beta | – | yes | – | – | a `.bat` stub, not a game | – | 1 MB |
| Limbo | – | yes | – | – | – | – | 103 MB |
| Marvel Rivals | – | – | Win64 | inferred: NetEase's, not in file names | its own (`MarvelRivals_Launcher.exe`) | – | 94.5 GB |
| Marvel's Guardians of the Galaxy | yes | yes | Win64 | – | – | – | 82.6 GB |
| Morbid: The Seven Acolytes | – | – | Win32 | – | – | – | 596 MB |
| Necromunda: Hired Gun | – | yes | Win64 | – | – | steam_api, Galaxy64 | 42.3 GB |
| No Straight Roads: Encore Edition | – | yes | – | – | – | – | 18.4 GB |
| Priest Simulator: Vampire Show | – | – | – | – | – | steam_api | 13.8 GB |
| Rise of the Tomb Raider: 20 Year Celebration | – | yes | Win64 | – | – | – | 38.6 GB |
| Rocket League | – | yes | Win64 | EasyAntiCheat | its own (`Launcher.exe`) | – | 43.7 GB |
| Rogue Company | – | yes | Win64 | EasyAntiCheat | – | steam_api | 27.7 GB |
| Roller Champions | – | – | – | – | Ubisoft Connect | steam_api | 623 MB |
| Scarf (JSON manifest) | – | – | – | – | – | steam_api, Galaxy64 | 13.6 GB |
| Sid Meier's Civilization VI | – | yes | Win64 | – | 2K's stub (`Civ6_Launcher.exe`) | steam_api | 19.7 GB |
| Snakebird Complete | – | – | Win64 | – | – | steam_api | 319 MB |
| Star Trek Online | – | **no** | Win32 | – | inferred: Cryptic's (`Star Trek Online.exe`) | steam_api | 450 MB |
| STASIS: BONE TOTEM | – | – | Win64 | – | – | steam_api, Galaxy64 | 35.0 GB |
| Super Meat Boy | – | yes | – | – | – | – | 519 MB |
| Tales from the Borderlands | – | yes | Win64 | – | – | – | 8.2 GB |
| The Eternal Cylinder | – | yes | – | – | – | – | 8.0 GB |
| Ticket To Ride: Classic Edition | – | yes | Win32 | – | – | – | 760 MB |
| Trackmania Starter Access | – | yes | – | – | Ubisoft Connect | – | 3.8 GB |

- **EOS SDK in 23 of 34** (20 Win64, 3 Win32). Today they all start with no exchange code, so
  every one runs signed out of EOS. Six set `OwnershipToken` (Borderlands 3, Guardians of the
  Galaxy, Football Manager 2022 and its two tools, Jurassic World Evolution); two set
  `CanRunOffline=false` (Jurassic World Evolution, Star Trek Online). Borderlands 3 has an
  ownership token but no EOS SDK file.
- **Anti-cheat:** EasyAntiCheat (EOS form) in Fortnite, Rocket League and Rogue Company. Marvel
  Rivals ships no anti-cheat by name (only `VMProtectSDK64.dll`); its anti-cheat is inferred.
- **Another company's launcher:** Roller Champions and Trackmania (Ubisoft Connect, by the
  catalogue); by file, Elite Dangerous (Frontier) and Marvel Rivals; Star Trek Online inferred.
- **New finding: four manifests are Epic's older JSON form** (Football Manager 2022, its Editor
  and Resource Archiver, Scarf); the other 30 are binary. `EpicManifest` refuses the JSON form
  (`unsupported("Epic's older JSON manifest")`), so **Football Manager 2022 cannot be installed
  by Playport today**, sign-in or not. The 2026-10-06 record saw binary manifests only (3 games).

## Steam

**Not measured: the owned list.** The workstation has no Steam session: the paired session is
only in the phone's Keychain, and `SteamClientKit` has no CM transport on Linux (its README).
The 2026-09-24 pairing counted 81 owned games and did not commit the list. What is on the
workstation: the phone catalogue pulled on 2026-10-01 (7 titles) and a few binaries pulled for
earlier debugging. No depot was fetched (that needs the owner's session and depot keys).

| Title | steam_api and auth use | Online part |
| --- | --- | --- |
| Hollow Knight (367520) | files not on the workstation | none (inferred) |
| Portal 2 (620) | measured, `engine.dll`: 20 `steam_api.dll` imports, none an auth function; interfaces by version string `SteamUser021`, `SteamGameServer014`, `SteamMatchMaking009`, `SteamNetworking006` (calls through the interface, so `GetAuthSessionTicket`/`BeginAuthSession` cannot be seen statically) | co-op through Steam lobbies and Steam P2P, with a listen server (inferred) |
| The Witcher 3 (292030) | measured, `witcher3.exe`: no `steam_api` import; imports `REDGalaxy64.dll` (GOG Galaxy: `Init`, `User`, `Friends`, `CloudStorage`, `Telemetry`) | none needed; optional GOG account link (inferred) |
| Among Us (945360) | files not on the workstation | the game is online play on Innersloth's servers with an Innersloth account (inferred) |
| MultiVersus (1818750) | files not on the workstation | online-only at release; servers closed in 2025 (inferred) |
| En Garde! (1654660) | not on the workstation; its GOG build ships `steam_api64.dll` and `Galaxy64.dll` (measured, GOG manifest) | none (inferred) |
| #DRIVE Rally (2494780) | files not on the workstation | unknown |

- **Static scans can only prove use for a flat import.** A C++ game on a newer SDK imports
  `SteamAPI_ISteamUser_GetAuthSessionTicket` and the like by name, and that shows use. Calls
  through an interface (Portal 2) show only the interface version. Unity games carry
  Steamworks.NET, which names every flat function, so the names appear whether the game uses
  them or not (measured on Shogun Showdown's GOG build: all eight auth names in
  `com.rlabrecque.steamworks.net.dll`). IL2CPP games resolve these at run time, with no import.
  A game's use is therefore best shown by a play that fails online with gbe_fork's made-up
  ticket, not by a scan.
- **Tickets are not the whole online part.** gbe_fork replaces Steam lobbies, matchmaking and P2P
  with its own LAN network (inferred from its design). A game whose online play uses Steam's
  lobbies (Portal 2's co-op) needs more than a ticket. A ticket fixes games that sign in to
  their publisher's own servers.

## GOG (46 games)

Measured: newest Windows build (generation 2 for 45, generation 1 for Quake II (Original)),
English and language-neutral depots. **31 of 46 ship `Galaxy64.dll` or `Galaxy.dll`:**
A Plague Tale: Innocence, BioShock Remastered, Blade of Darkness, Call of Juarez: Gunslinger,
Chasm: The Rift, Close To The Sun, Control Ultimate Edition, Coromon, Dishonored Definitive
Edition, DREDGE, Duck Paradox, En Garde!, Ghost Song, Ghostrunner, GWENT, Mafia: Definitive
Edition, Shadow of Mordor GOTY, Monster Train, Moonscars, Neverwinter Nights: Enhanced Edition,
Overcooked! 2, Quake II, RIOT - Civil Unrest, Scorn, Showgunners, Sir Whoopass, Star Wars:
Bounty Hunter, The Falconeer, The Gunk, The Outer Worlds, The Outer Worlds: Spacer's Choice.
None of the 15 others has one. Shipping the DLL does not make the client necessary: without
GOG Galaxy the game runs and its Galaxy features (achievements, GOG friends, multiplayer) are
silent (inferred; not yet seen on the phone: the GOG test title, Shogun Showdown, has no Galaxy
DLL). GWENT is online-only and
signs in through Galaxy (inferred), so it is the one that does not play without it.

## Step 3: can a ticket made before launch be used during play?

**The host cannot make an auth session ticket at `f7c93af`.** `SteamClientKit` has no handler
for `ClientGameConnectTokens` (EMsg 779; the CM sends it after logon and `CMConnection` drops it
as unhandled), none for the app ownership ticket (`ClientGetAppOwnershipTicket`, 857/858) and none
for `ClientAuthList` (5432) and its ack (5575). The encrypted app ticket (5526/5527) is being added
for step 2. The method, as Steam's client protocol does it: take a GC token,
append a 24-byte session header (type 2, or 5 for a web API ticket), register its CRC with
`ClientAuthList`, wait for the ack, then append the ownership ticket. The GC tokens are the
session's and go at log-off.

**What gbe_fork does at the gbe pin `7103add`** (`dll/auth.cpp`): `GetAuthSessionTicket` and
`GetAuthTicketForWebApi` build a ticket in Steam's layout from made-up parts (a random GC token,
loopback IPs, an unsigned ownership ticket) and keep it only to announce it to other gbe peers
on the LAN; nothing reaches Steam. `BeginAuthSession` accepts any ticket of a known layout whose
SteamID matches and answers `k_EAuthSessionResponseOK`. `GetEncryptedAppTicket` returns the
`configs.user.ini` ticket if one is set (0017's channel), else a made-up one.

**Valve's rule (documented, `steam_api` › `EAuthSessionResponse`):** `OK` means "Steam has verified
the user is online, the ticket is valid and ticket has not been reused";
`UserNotConnectedToSteam` (1) and `AuthTicketInvalid` (8, "not from a user instance currently
connected to steam") are the answers otherwise, and `BeginAuthSession` keeps sending callbacks
"if the entity goes offline or cancels the ticket". So a `GetAuthSessionTicket` ticket made before
launch is expected to fail as soon as `suspendForLaunch` closes the CM socket. The web API ticket
(`AuthenticateUserTicket`) is not documented either way, and it must be created with the
identity string the game's service checks, which the host would have to know for each game.

**Not measured from the workstation** (needs the owner): no Steam session here, no Linux CM
transport, and `AuthenticateUserTicket` needs a key: a publisher key on `partner.steam-api.com`,
or a Web API user key on `api.steampowered.com` ("also available for games servers…, rate
limited"). The procedure, if the owner wants the number:

1. The owner creates a Web API user key (steamcommunity.com/dev/apikey); it goes in a 0600 file
   in the build area, never committed.
2. A throwaway Steam client console in the build area logs on by QR; the owner
   approves it in the Steam mobile app. This is a second session beside the phone's.
3. `GetAuthTicketForWebApi(367520, "playport-survey")`; `AuthenticateUserTicket` with that app,
   ticket and identity while logged on (expected: the SteamID).
4. Close the socket without log-off (as `suspendForLaunch` does); call again at +5 s, +60 s,
   +5 min, +30 min. Repeat with a fresh ticket and a `ClientLogOff`.
5. Record only the results; log the tool's session off and revoke it.

A `BeginAuthSession` (type 2) ticket cannot be checked this way; it needs a game server logon, and
Valve's rule above already answers it.

## Recommendations

- **Epic test title: Jurassic World Evolution** (8.0 GB, EOS SDK, ownership token and no offline
  play, so it needs both the exchange code and `-epicovt`), if it fits `MemoryNeed`. Football
  Manager 2022 cannot be the test title until JSON manifests are supported. A light check of the
  exchange code alone: Snakebird Complete (319 MB, Unity, EOS SDK). Death's Door (no EOS SDK)
  stays the regression play.
- **Steam test title: Among Us** (1.15 GB, installed on the phone, online is the game,
  publisher servers rather than Steam lobbies) (inferred: whether it checks an encrypted app
  ticket or a web API session ticket is to be seen in a play). First pull its `steam_api64.dll.orig`
  and `GameAssembly.dll` and play it once as it is now. The owner may know a better one among the
  81 games; listing them needs `steam-games.json` pulled from the phone.
- **Step 3's short form is not expected to work**, by Valve's rule above: a session ticket is
  valid only while the issuing client is connected. Do not build it on a guess. If a Steam online
  title is in the 0.4.0 gate and it uses session tickets, step 4 (a live Steam session during
  play, 0062) is needed. If the title uses only the encrypted app ticket, step 2 suffices. The
  procedure above measures the web API case if the owner wants it first.
- **GOG Galaxy (owner's scope question): 31 of 46 games ship the Galaxy SDK**; only GWENT is
  known to need it to play at all.

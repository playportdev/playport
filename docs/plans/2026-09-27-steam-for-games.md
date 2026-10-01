# Plan: Steam for games

**Date:** 2026-09-27. **Kind:** plan. Phase 1 is built and played on the phone
([evidence](../evidence/2026-09-27-gbe-steam-api-build.md)); phase 2 removes
SteamStub 3.1 x64, and En Garde! has [its own plan](2026-09-27-en-garde.md);
phase 3 reads and syncs on the phone, but no unlock has been sent yet; phase 4
syncs on the phone, and an upload was seen from a PC; phase 5 waits on
[decision 0017](../decisions/0017-encrypted-app-ticket.md), proposed.

## Goal

Games that call Steamworks should start and behave as if Steam were running,
and the player's progress should reach their Steam account. Today a game gets
no Steam at all. The app's Steam client (`app/SteamClient`) closes its session
before a launch (`SteamAccountModel.suspendForLaunch`), and nothing in the
prefix answers `SteamAPI_Init`. DRM-free games that tolerate a missing Steam
run. Games that need Steam, and games wrapped in SteamStub, do not.

The target feature set is the one the Android Steam front ends converged on
(see Background):

1. A Steam API emulator in place of the game's `steam_api(64).dll`.
2. SteamStub DRM removed at install.
3. Achievements and stats sent to the player's account.
4. Steam Cloud saves synced before and after a play.
5. A real encrypted app ticket for games that check ownership online.

## Background

Proton's own route, `lsteamclient`, forwards `steamclient` calls to the native
Linux Steam client. It is not available here: there is no native Steam client
for iOS, and the app cannot load a foreign binary. The Android front ends run
games against an emulator, most often gbe_fork (the maintained Goldberg
emulator), which is fed from their own Steam client. They also strip SteamStub
at install, and sync Cloud and achievements from the host client. We already
have the host client, `SteamClientKit`: it covers login, PICS, depot keys,
download and verify. We lack the game-facing half.

**Provenance.** Only willfaust/Madeira may be named as provenance (AGENTS.md).
The code is written here, from the protocol and file formats. Other front ends
are prior art we studied, not sources we copy. gbe_fork is a pinned build
input under its own licence, like DXMT.

## Rules that constrain the design

- **Decision 0004: no host secret enters the guest.** Phases 1 to 4 need none.
  - The emulator's configuration holds only the persona name, the SteamID64,
    the language and the DLC list. None of these is a credential. The account
    name is half the login, and real Steam never gives it to a game, so it is
    not used.
  - Achievements and Cloud are moved by the host after the game exits, so the
    guest never sees a token.
  - Phase 5 (the app ticket) does cross into the guest, so it waits for a new
    decision record.
- **Decision 0012: the UI is the only entry point.**
  - Every switch sits on a game's page or in Settings.
  - The drivers reach it with `set:` and `open:`.
- **Verify and repair must know about the swap.** A swapped `steam_api64.dll` or
  an unpacked exe fails the manifest SHA check. The installer keeps the original
  beside the swap (`.orig`), and verify checks the original.

## Phase 1: Steam API emulator

**State (2026-09-27):** done except its "fails without Steam" title. What was
built differs from the plan below in these places:

- The stage is `steamapi`, after `vulkan` rather than after `pe`: it needs no
  other tree, and `--from pe` should not rebuild it. It also pins Abseil
  (`abseil-cpp`), which protobuf would otherwise download during the build.
- Only `steam_api(64).dll` is built. gbe_fork builds `steamclient` only in its
  experimental flavour, with the GPL overlay and Detours; the regular
  `steam_api` holds the whole emulator.
- The swap happens at every launch (`LaunchCoordinator`), not at install. It
  follows the game's setting and leaves nothing to record: the state is on
  disk (`.orig` beside the emulator, a `steam_settings/` Playport marks). A
  game update or a repair needs no step of its own.
- The emulator's settings come from the service with no network, since the
  session is closed at launch. The SteamID64 comes from the stored session,
  so a game's per-user saves never move. The persona name and owned DLC come
  from a profile fetched while the session is up (page open, install finish,
  "Update from Steam") and deleted at sign-out.
- gbe_fork's LAN networking is off (`disable_networking=1`): it would ask iOS
  for local network access in the middle of a game.
- En Garde! was the candidate title, and it does not start with the emulator
  either. It is SteamStub-wrapped, so it moves to phase 2.

**Build.**

- Pin gbe_fork in `pins.lock`, with a `patches/gbe` series if it needs any.
- Build the x86-64 and i386 `steam_api(64).dll` and `steamclient(64).dll` with
  llvm-mingw in a new stage, `build/stages/steamapi.sh`, after `pe`.
- Ship them in the IPA like the other PE files, and record them in
  `app/artifacts.tsv`.
- Later, measure an ARM64EC build of `steam_api64.dll`. An x64 game in an
  ARM64EC process can load it, which takes `SteamAPI_RunCallbacks` and friends
  out of FEX.

**Licence.** gbe_fork is LGPL-3.0 (to be verified against its repository). Add it
to NOTICES.md and LICENSING.md. Check it against decision 0006 and the
corresponding-source duty in DISTRIBUTION.md.

**Install-time swap** (`SteamClientKit/Install`, a new step after commit):

1. Find every `steam_api.dll` and `steam_api64.dll` under the install directory.
2. Keep each original as `<name>.orig`, then put the emulator in its place.
3. Write `steam_settings/` beside each one:
   - `steam_appid.txt`;
   - `configs.user.ini`, with the account name, the SteamID64 and the language;
   - `configs.app.ini`, with the DLC the account owns. That is PICS appinfo
     `extended/listofdlc` intersected with the licences `Library` already reads.
4. Record the swap in `installs/<appID>.json`.
5. Uninstall, repair and "restore original" undo it.

**Verify.** `TitleInstaller`'s verify checks `.orig` against the manifest and
re-swaps.

**Saves.** gbe_fork keeps its own saves (stats, achievements, settings) under
the prefix's `%APPDATA%`. They stay in the container like the game's saves.

**UI.**

- A "Steam" section on a game's page shows:
  - the Steam API mode, `emulated` (the default when a `steam_api` DLL is
    present) or `original`;
  - the swap's state;
  - the DLC the emulator reports.
- It becomes a launch setting in `PlayportKit`, next to `GraphicsBackend`.

**Done when:**

- A `pp ui --play` shows a cohort title that fails today without Steam and now
  reaches its first frame.
- Hollow Knight still plays in both modes.
- Unit tests cover the swap, verify and restore on the Linux host
  (`swift test`, with fixture trees).

## Phase 2: SteamStub removed at install

- SteamStub wraps the exe. A game started without Steam exits or asks for Steam.
- **Detect it** at install: a `.bind` section, and the SteamStub header in the
  entry stub.
- **Unpack it in the host, in Swift**, in `SteamClientKit`: a SteamStub reader
  for variants 2.x, 3.0 and 3.1, x86 and x64.
  - It decrypts the stub header with its XOR key and the code section with
    AES-CBC, then restores the original entry point and writes a clean exe.
  - It runs on the Linux host in tests, needs no Wine, and works before the
    first play.
- **Do not run Steamless under Wine.** That needs Wine Mono, which runs x86 .NET
  under FEX. Steamless's licence also needs a reading before anything derived
  from it can ship; it is Creative Commons non-commercial, no-derivatives (to be
  verified). The Swift reader is written from the format, not from its code.
- Keep the original as `.orig`, and let verify handle it as in phase 1.
- The game's page shows "DRM removed: SteamStub v3.1 x64".
- **Done when:** a SteamStub title starts from Play, and the unpacker's tests
  pass on recorded stub headers. En Garde! (app 1654660, in the cohort) is the
  first: its shipping executable carries SteamStub (`steamdrmp.dll`) and exits
  `0x35` without Steam, with or without the emulator. Its `EnGarde.exe` only
  starts that executable as a second process, which must work too.
- **State (2026-09-27):** 3.1 x64 without code encryption is removed at
  launch, and adoption picks an Unreal game's shipping executable over its
  bootstrap. En Garde! then gets past the DRM and faults in FEX about 20 s
  in, which is [its own plan](2026-09-27-en-garde.md). Encrypted code, 3.0 and
  x86 are recognised but not removed, until a real executable can check
  them.

## Phase 3: Achievements and stats

**State (2026-09-27):** built. It differs from the plan below in these places:

- The schema and the values come in one `ClientGetUserStats` (with
  `schema_local_version` -1). An achievement is a bit of an achievement-block
  stat, so an unlock is stored as that block's new value. A store is made
  "in game" (`ClientGamesPlayed` with the app, then none).
- The sync (`SteamService.syncUserStats`) runs while the session is up: at
  page open, "Update from Steam", and at the app's next start for every game
  with an emulator save. That start is where a play's results go, since the
  process is suspended for good after a launch. The launch only writes the
  last schema into `steam_settings/`.
- Achievements only accumulate, both ways. A stat goes to Steam only when the
  game changed it since the last sync (a kept baseline), so a first sync sends
  no stats: a stale save never lowers a player's stats. Steam's refusals go
  back into the save.
- Checked on the phone: Hollow Knight's schema (63 achievements) and state
  (0 unlocked) are read, and its play still reaches its first frame with the
  schema in place. Not yet shown: an unlock during a play reaching the
  account.

**Schema.** Fetch the game's stats and achievement schema over CM. That is
`ClientGetUserStats` with the schema flag, whose reply carries the schema as
binary KeyValues, which `Wire/KeyValues.swift` already parses. Also fetch the
player's current values.

**Before a play.** Write the emulator's `achievements.json` and stats files from
the schema and current values, so the game sees what the account already has.

**After a play**, when `LaunchCoordinator` reports `.exited`:

1. Read the emulator's save.
2. Compare it with what was written.
3. Send new unlocks and stat changes with `ClientStoreUserStats2`. The host
   session is back by then, since `suspendForLaunch` ends with the play.
4. If the push fails, queue it and retry at the next sign-in.

**UI.** The game's page lists achievements (unlocked / total) and any pending
sends.

**Done when:**

- An unlock made during a `pp ui --play` shows on the account's Steam profile.
- Tests cover schema parsing and diffing, with a recorded schema.

## Phase 4: Steam Cloud

**State (2026-09-27):** built; 134 host tests pass. Nothing has been run on
the phone or against a real Steam Cloud yet. It differs from the plan below
in these places:

- **When it syncs.** Like phase 3's sync, it runs while the session is up:
  at page open, on "Update from Steam", and at the app's next start for every
  played game. There is no sync right before Play: the launch closes the
  session at once.
- **A baseline.** Each sync keeps Steam's change number and every file's
  SHA-1 as the phone last agreed with Steam, so each file's action is known:
  - changed on one side: that side wins;
  - changed on both: a conflict;
  - on Steam only: downloaded;
  - new or changed on the phone only: uploaded.
- **What needs the player.** A game's first sync (no baseline) never uploads,
  and never overwrites a differing file: both are conflicts the player
  settles. A conflict stays open until it is settled.
- **Keep both.** It became "the loser is backed up": a download backs up the
  phone's file, and "keep the phone's" first downloads Steam's copy into
  `Documents/Cloud Backups/<appid>/<time>/`.
- **Not carried or not supported.** Deletions are not carried either way.
  Encrypted cloud files are not supported. Every download must match
  Steam's size and SHA-1 (as sent, or unzipped) before it is written.
- **Roots.** `%WinMyDocuments%`, `%WinAppDataLocal%`, `%WinAppDataLocalLow%`,
  `%WinAppDataRoaming%`, `%WinSavedGames%`, `%GameInstall%`, and no token (the
  emulator's `remote/`). Path components are matched without case.
- **Switches.** A per-game one (the `cloudSync` launch setting) and a global
  one in Settings.
- **To check on the phone.** A read-only first sync of Hollow Knight: its
  cloud files and what the plan would do. Then, with the player's leave, a
  download, a play, and an upload seen from a PC.

1. **Paths.** Read the game's Cloud rules from PICS appinfo (`ufs`: `savefiles`
   with root, path, pattern, platforms and root overrides). Map each root (for
   example `WinAppDataLocal`, `WinMyDocuments`, `gameinstall`) into the prefix
   (`C:\users\playport\…`). The emulator's own remote storage folder counts as
   a root too.
2. **Before a play:**
   - Fetch the change list with `Cloud.GetAppFileChangelist`.
   - Download what changed.
   - When both sides changed, stop and ask in the UI: keep the phone's copy,
     keep the Cloud's, or keep both.
3. **After a play:** upload what changed with `Cloud.BeginAppUploadBatch`, the
   file upload calls and `Cloud.CompleteAppUploadBatchBlocking`.
4. **Transport.** All of this is service-method calls over the existing CM
   connection, with the file bodies over HTTP (`Net/HTTP.swift`). There is no
   guest involvement.
5. **UI.**
   - A per-game switch ("Sync saves with Steam Cloud") and the last sync time.
   - The conflict dialog.
   - A global off switch in Settings.
6. **Done when:**
   - A save made on a PC appears on the phone and the reverse, for one cohort
     title.
   - The conflict path is shown in a `--shot-each-action` run.
   - The rule mapping is unit-tested on appinfo fixtures.

## Phase 5: Encrypted app ticket (needs a decision first)

**State (2026-09-28):** the record is written:
[0017](../decisions/0017-encrypted-app-ticket.md), proposed. It cannot meet
0004's "revocation also invalidates what the guest received", and asks to
accept that for this secret alone. Nothing is implemented. gbe_fork takes a
ticket as `ticket=<base64>` in `configs.user.ini`, and ignores the data a
game asks to include.

- Some games send the encrypted app ticket to their own servers to prove
  ownership. The emulator can present a real one if it is given one.
- Getting one is a host call: `ClientRequestEncryptedAppTicket`. The ticket is
  per game, lasts a short time and is not a login credential. It is still
  derived from the session, and 0004's rule is to change "only by a new decision
  record".
- **Write that record first.** It needs:
  - the threat model for this one secret;
  - one channel into the guest (a file the emulator reads, written just before
    launch and deleted after exit);
  - the measured guest-side storage;
  - logout removing every copy.
- **Then** fetch the ticket in `TitleLaunch.start` before `suspendForLaunch`,
  and write and delete it as above.
- **Done when:** a game whose online login needs the ticket signs in.

## Order and size

| Phase | Depends on | Rough size |
| --- | --- | --- |
| 1. Emulator swap | a new build stage | the largest: build, installer, verify, UI |
| 2. SteamStub | none | a self-contained Swift reader and tests |
| 3. Achievements | 1 | CM messages and KeyValues schema work |
| 4. Cloud | 1 (for the emulator's storage root) | the most protocol work |
| 5. App ticket | 1, and a decision record | small once decided |

Phases 1 and 2 give the most titles that start. Phases 3 and 4 are about the
account. Each phase ships alone and goes through the phone gate: a play of
Hollow Knight plus the phase's own title.

## Not in this plan

- **The real Windows Steam client inside Wine.** It would have its own login
  (0004 allows that), but it is heavy under FEX and needs a second session.
  Consider it only if emulation fails a title we want.
- **Proton's `lsteamclient` and `steam.exe`.** There is no native Steam client
  library for iOS to bridge to.
- **Epic, GOG and Amazon stores.** They are separate plans if wanted.

# Plan: PC game import, GOG and Epic Games

**Date:** 2026-10-06. **Kind:** plan. **Status:** phases 0–3 done on branch
`pc-import-gog-epic`, with the phone checks listed in Progress still open; the owner's answers are folded in (see Settled). Phone
runs are kept to the phase gates (owner, 2026-10-06). Decision numbers: 0055 and
0056 were taken, so store identity is 0057, store sessions 0058 and the Epic
exchange code 0059.

## Progress

Evidence: [PC import and GOG on the phone](../evidence/2026-10-06-pc-import-and-gog.md),
[Epic Games on the phone](../evidence/2026-10-06-epic-games.md).

- **Phase 0: done.** `app/ContentKit` holds the store-neutral core (the parts plan,
  engine, journal, layout, codecs, hashes with md5, HTTP, secrets,
  `Store`/`StoreGameKey`/`StoreReceipt`); SteamClientKit re-exports it, and Steam's plans
  convert with the same journal numbering. The catalogue, library, queue and game routes
  carry the store identity. The app's queue (`UI/Downloads.swift`) runs each source's jobs
  through a `DownloadDriver` (Steam's `UI/SteamInstalls.swift`, imports'
  `UI/Import.swift`, GOG's `UI/GOGAccount.swift`). Settings › Accounts (old names `steam`
  and `account` still open it); the setup checklist's step is Accounts (Steam or GOG).
  Decisions 0057, 0058. On the phone: Hollow Knight plays; a Steam pause, resume and
  verify pass.
- **Phase 1: done apart from phone checks of 1.3, 1.4 and 1.6.** Add a game is on every
  Library filter (a header button, X, the Filter & sort picker, and a tile in All and
  Installed); a folder or a .zip becomes an `import` job (PlayportKit `GameImporter`).
  **The sources are separate (owner, 2026-10-06):** Local, Steam, GOG and Epic. An import
  is always Local; a store's launch record in the folder (`goggame-*.info`,
  `.egstore/*.mancpn`) only gives the executable and arguments, and `steam_appid.txt` is
  kept as a hint (the page's "Run with Steam's game ID" from 1.2 is not built). On the
  phone: a 5.2 GB folder imported, played and uninstalled, driven by
  `pp ui --action import:PATH` (owner's choice; see 1.7). Not yet on the phone: a .zip
  import, a hand pick in Files, the Executable and Name rows, icon art.
- **1.5 dropped** (owner, 2026-10-06): offline installers are not run. Spike A, for the
  record: Shogun Showdown's GOG installer (Inno Setup 5.6.2, i386) started under WoW64
  with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=…`, loaded kernel32 and
  kernelbase, and exited with code 1 after 147 ms, before writing its log or the target
  folder; not traced further. Picking an installer in Add a game says Playport doesn't run
  them and asks for the installed folder or a .zip.
- **Phase 2: done apart from a repair and an uninstall on the phone.** `app/GOGClient`
  (session, library, generation-2 content, chunk source, installer with update, verify and
  repair). GOG's desktop-client secret is 64 hex digits (the 32-digit form is refused).
  Test title Shogun Showdown (1104084973); Hollow Knight is not owned on GOG. On the
  phone: sign-in by the owner (the sheet allows portrait so a password manager's AutoFill
  draws), the library with art (800×370 tiles, 1920×655 behind the page and launch
  screen), install of an older build, Update offered, update, verify and play.
- **Phase 3: done apart from an update, a repair and an uninstall on the phone.**
  `app/EpicClient` (session, library with the catalogue, binary manifest, chunk slices,
  installer with update, verify and repair, refusals); zlib moved to ContentKit. The app's
  Accounts › Epic Games, the Epic filter, `epic-` pages and art, and `pp ui
  --action install:epic-APP`. 3.1 found that Epic can answer the sign-in with a corrective
  action (accept the privacy policy); the sheet says so. Test title Death's Door. Games that
  need Epic online sign-in (an ownership token, no offline play, or Epic's access control:
  Borderlands 3, Fortnite and six more) and those of another launcher are refused, and none is
  one the owner asked for, so 0059 is not written (3.6). On the phone: sign-in by the owner,
  install, verify 1334/1334, play to `first-frame+10`, Borderlands 3's refusal, Hollow Knight.
- **Open:** the phone checks left in each phase (above); 2.4 and 3.7 (cloud saves), 3.6 when a
  wanted game needs it.

## Goal

A player can get a Windows game into Playport without Steam and without a computer:

1. **Import**: a game folder or a `.zip`, picked in Files (On My iPhone, iCloud, a
   USB drive, an SMB share). It is copied into `C:\Games` and plays like any other
   title, as a Local game.
2. **GOG**: sign in, see the owned library with art, install, update and verify a
   game from GOG's content servers, and play it.
3. **Epic Games**: the same for the Epic library. Games that need Epic's online
   ownership check at launch wait for a decision record (see 3.6).

Each part ships alone. Order: 0 → 1 → 2 → 3. Import comes first because it needs
no account. Local, Steam, GOG and Epic are separate sources of games: an imported
game is Local and joins no store.

## Where things stood before the plan (the tree at `4a4a4c2`)

- **The catalogue** (`app/PlayportKit/Sources/PlayportKit/Catalog.swift`) is rebuilt
  by adoption from `Documents/prefix/drive_c/Games` each time the app comes to the
  front. A folder is `installed` (it has a Steam receipt), `cohort` (pinned in
  `titles.json`) or `found` (any other folder with a Windows `.exe`, id
  `dir-<lowercased folder>`). Adoption picks the executable heuristically (`pick`,
  `nested`, `notTheGame`) and records the Direct3D evidence and the PE machine.
- **The player cannot get a `found` game onto the phone today.** No `fileImporter`
  for games, no `UIFileSharingEnabled`, and Documents is not visible in Files
  (decision 0009). Only the workstation (AFC) or a Steam install fills `C:\Games`.
- **Identity is Steam-shaped.** The only stores are `LibrarySource.local` and
  `.steam`; `LibraryEntry.source` is `appID == nil ? .local : .steam`.
  `GameRef` is `.title(String)` or `.steam(UInt32)`. `DownloadJob.id` is the
  `appID: UInt32` (about 30 uses in `DownloadQueue.swift`, 74 in
  `UI/SteamInstalls.swift`). `InstallReceipt` and `InstallLayout.receiptFile(appID:)`
  are keyed on the Steam app ID.
- **Decision 0045 already sets the condition**: before another store, catalogue
  and game references carry an explicit `(store, store game ID)` end to end, with
  store-qualified IDs for new copies. `app-<ID>` and `dir-<folder>` stay as they are.
  Joins, art, downloads and navigation use that identity, never a name.
- **The install engine** (`app/SteamClient/Sources/SteamClientKit/Install/`) is
  good and store-neutral at its core: a bounded chunk task group, `pwrite` to
  each place a chunk occurs, a CRC-checked journal of verified chunks,
  free-space checks, a single-`rename` commit, and manifest path safety. Its
  types are Steam-shaped, though: `ChunkSource.chunk(depotID:_: ContentManifestPayload.Chunk)`
  checks Adler-32 and SHA-1, and `InstallPlan` is built from Steam depot manifests.
  It already has inflate, gzip, zip, LZMA and zstd decoders, SHA-1, the HTTP
  client, `Secret<T>`, `Redactor` and the Keychain `SecretStore`.
- **Launch** (`LaunchCoordinator.swift`) sets Steam's game ID variables and swaps
  `steam_api` only when the title has a Steam app ID. A title with no app ID
  launches with neither, which is right for GOG and Epic copies.
- **Rules that shape the design:** 0004 (no host secret enters the guest), 0012
  (the UI is the only entry point), 0029/0030 (one title per process, restart
  after each game), 0034 (gamepad-first UI; touch only where iOS forces it),
  0045 (store identity), 0005 (cohort scorecard for test titles), the name gate
  (no project other than willfaust/Madeira named as provenance: other store
  clients are prior art we studied, not sources, and they go unnamed).

## Phase 0: store identity and shared plumbing

Nothing visible changes. Every later phase depends on this.

**0.1 Decision record (0057): stores as `(store, store game ID)`.**
- `enum Store: String { local, steam, gog, epic }` in PlayportKit, with
  `StoreGameKey { store, id: String }`.
- Title IDs: `app-<steamID>` and `dir-<folder>` stay as they are. New:
  `gog-<productID>` and `epic-<appName>`. Saved launch settings, play time and
  cloud state are keyed by title ID, so nothing migrates.
- A store copy is identified by its install receipt. Never by its name. **Changed
  (owner, 2026-10-06):** the sources are separate; a folder's store marker does not
  make it a store copy (see 1.2).
- An installed copy joins its own store's listing only (0045 unchanged).

**0.2 Model changes (PlayportKit, host tests).**
- `InstalledTitle`: add `store: Store` and `storeID: String?` and keep `appID`
  for Steam. `Source` gains `imported`. `LibraryEntry.source` comes from `store`,
  not from `appID`.
- `LibrarySource` and `LibraryFilter` get `gog` and `epic`, shown only when that
  store is signed in or has a copy in the catalogue (0045: "connected stores add
  their own filters after Installed").
- `GameRef` gets `.store(StoreGameKey)`. Keep `.steam(UInt32)` as the Steam case,
  or fold it in; either way, routes and the driver's `open:` names stay stable.
- `DownloadJob` is keyed by `StoreGameKey`. Old queues decode with
  `store = .steam`, and there is a test for loading the old file.
- Receipts: a store-neutral `InstallReceipt` header (`store`, `storeID`,
  `installDir`, `version`/`buildID` as a string, `executable`, `arguments`,
  `workingDir`) in `installs/<store>-<id>.json`. Steam's `<appID>.json` stays
  readable as is.
- Adoption reads every store's receipts. A folder with a receipt is that store's
  copy, and `nested` and `pick` remain the fallback.

**0.3 Engine generalisation (store-neutral install core).**
Steam's tests must keep passing unchanged. Recommended: move the neutral core into
a new package, `app/ContentKit` (engine, journal, layout, plan safety checks,
HTTP, codecs, hashes, `Secret`, `Redactor`, `SecretStore`). `SteamClientKit`,
`GOGClientKit` and `EpicClientKit` then depend on it. The neutral plan model:

- a file is a list of **parts**, each `(chunkKey, offsetInChunk, length, fileOffset)`;
- a chunk is `(key, compressedSize, size, verify: sha1 | md5 | sha1+adler, decode: aes+zip | zlib | none)`.

Steam's chunks fill whole ranges (offset 0 in the chunk). Epic's files take slices
of chunks, and GOG's chunks are whole. The journal records each chunk by key. The
`-O` flag carries over (`app/SteamClient/Package.swift` has the reason).
**Settled:** the new `app/ContentKit` package, not an extension of SteamClientKit.

**0.4 Decision record (0058): store sessions.** This applies 0004 to GOG and
Epic. Their refresh and access tokens live only in the Keychain
(`ThisDeviceOnly`, separate service names) as `Secret<T>`. `Redactor` learns
their token shapes (GOG's JWT-like tokens, Epic's `eg1~` tokens). Nothing crosses
into the guest. Sign-out deletes the item and revokes where the store allows it
(Epic: kill the session; GOG: no revoke endpoint, so the item is deleted and that
is recorded). Store web logins happen in a `WKWebView` sheet, which is touch
(0034's exception, as the pairing-file import is). **Settled:** the logins use
the stores' public desktop-client OAuth identities, the only route open to a
third-party client. 0058 records this and the risk that a store blocks it.

**0.5 Settings.** The `steam` section becomes **Accounts**, with one row block per
store (Steam unchanged, then GOG and Epic once their phases land). `SettingsSection.from`
keeps `account` as an alias.

**Done when:** `./pp test` passes; Hollow Knight (Steam receipt) and a `found`
folder adopt with the same IDs as before; an old `downloads.json` and catalogue load;
the Steam install and repair run on the phone (`./pp ui --action install:…` of a
small owned game); `./pp ui --play app-367520 --until first-frame+10 --shot` passes.

## Phase 1: import a PC game

**1.1 Import a folder (the core).**
- Library gets **Add a game** on every filter (built: a header button, X, the
  Filter & sort picker, and a ring-reachable tile in All and Installed). Picking a source opens
  `fileImporter(allowedContentTypes: [.folder, .zip, .exe])`, which is touch
  (as the pairing-file import is).
- The copy runs as a **Downloads queue job** of kind `import`. It shows progress,
  can be paused and resumed, and continues after the restart that follows a game,
  because the queue is persisted. iOS security-scoped access does not survive a
  relaunch, so after a restart an unfinished import holds as `stopped("Pick the
  folder again")`, and a pick resumes it.
- The copy goes through a stage directory, as the install engine's does
  (`Games/.stage-import-<id>`), with a free-space check up front (size + 5% +
  reserve) and a single `rename` at the end. Each file is copied with
  `copyfile(COPYFILE_CLONE)`, falling back to a byte copy: on the same volume
  (On My iPhone) a clone costs no space. Paths get the same checks as manifests:
  symlinks are skipped and counted; control characters, case-insensitive
  duplicates and reserved Windows names are refused.
- The folder name in `C:\Games` is the picked folder's name, made unique. The
  title's ID is `dir-<folder>`, as for a `found` game today.
- An **import receipt** (`installs/local-<folder>.json`) records the source name,
  date, file count and bytes. It marks the copy as Playport's for verify and
  uninstall. No path to the source is kept, so no home path gets in.

**1.2 Recognise what was imported.** **Changed (owner, 2026-10-06):** an import is
always Local; Local, Steam, GOG and Epic are separate sources, and an imported copy
joins no store's listing.
- `goggame-<productID>.info` (JSON): the primary `playTasks` entry gives the
  executable, arguments and name; nothing more.
- `.egstore/*.mancpn`: read for nothing beyond that; the copy stays Local.
- `steam_appid.txt` or `steam_api64.dll` alone **do not** make a copy a Steam copy
  (0045: an app ID from a receipt or the cohort only). Recommended: record the ID
  as `hintSteamAppID`, and let the game's page offer "Run with Steam's game ID"
  (0020's variables, and the Steam API emulator when signed in). Off by default.

**1.3 The game's page for imported games.** Game options gain:
- **Executable**: a picker of the ranked candidates (adoption's `nested` ranking,
  shown in full, with `notTheGame` entries last), plus the detected machine and
  Direct3D;
- **Arguments** (`PadKeyboard`);
- **Name** (display only; the ID does not change).

These are stored per title and survive adoption: they go in `LaunchSettingsStore`,
or in the import receipt. Adoption's choice stays the default.

**1.4 Zip import.** A streaming zip reader in ContentKit: the central directory,
zip64, store and deflate (inflate exists already), CRC-32 checked, same path
rules as above, extracted into the stage. Other methods are refused with a
message saying which. A zip with a single top-level folder becomes that folder.
`.7z`/`.rar` are out of scope.

**1.5 GOG offline installers (`setup_*.exe` + `setup_*-N.bin`).** These are Inno
Setup, i386.
- **Spike first (A):** run the installer as a one-off title in the session root
  with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="C:\Games\<name>"`.
  This tests whether a silent i386 Inno install completes under WoW64 and FEX
  with no window (0047 runs i386; the launcher-feasibility record says GUI
  windows are not presented yet). The app then restarts (0029), and adoption
  picks up the folder with its `goggame-*.info`.
- **(B), only if A fails:** a host-side Inno Setup extractor in Swift
  (setup header + LZMA/LZMA2 slices; the LZMA decoder exists). The header layout
  varies across Inno versions, so this costs several days, and the plan would then
  limit it to the 5.5–6.x headers GOG uses.
- **Settled:** A first; B only if A fails. **Superseded (owner, 2026-10-06):** neither;
  installers are not run (see Progress). Generic GUI installers (NSIS, MSI with
  dialogs) are out of scope until GDI presentation exists.

**1.6 Tile art for local games.** The executable's icon (PE `RT_GROUP_ICON` →
largest `RT_ICON`, PNG or BMP) on a generated backdrop, cached under
`Caches/Playport/art/local/` (built there: it can be made again). With no icon, the name's initials.

**1.7 Driver and tooling.**
- Picking from Files is touch, so the UI driver cannot drive the picker.
  **Changed (owner, 2026-10-06):** the dev build's `pp ui --action import:PATH` hands
  `Documents/PATH` (put there by the workstation) to Add a game as the picked item,
  then waits for the library; a hand pick is still worth one run.
- `pp ui --action open:dir-<folder>` works already. Add `import:` events to
  `RunEvents`.

**Done when:** a DRM-free x86-64 game, imported as a folder from Files (ideally
from a USB drive), plays to `first-frame+10`. A zip import of a small game plays.
(An offline installer was in this list; dropped, see Progress.) Uninstall removes the
copy and its receipt. Hollow Knight still plays.

## Phase 2: GOG

API details below come from prior study and must be checked in 2.1 before code
depends on them.

**2.1 Research spike (workstation, read-only on the account).** In
`.work/agent-notes/gog/`, from Linux with the owner's GOG login, check:
- the auth: Galaxy's public desktop client ID/secret, the `auth.gog.com/auth` web
  login with `embed.gog.com/on_login_success` as redirect, `auth.gog.com/token`
  code exchange and refresh, and the token lifetimes;
- the library: `embed.gog.com/user/data/games` for owned IDs,
  `embed.gog.com/account/getFilteredProducts?mediaType=1&page=N` for titles, images
  and `worksOn.Windows`, and `api.gog.com/products/<id>?expand=…` for details;
- the content system, generation 2: `content-system.gog.com/products/<id>/os/windows/builds?generation=2`;
  each build's zlib JSON manifest (depots by language and bitness, `installDirectory`,
  `dependencies`); depot manifests on the CDN by hash; each file's chunks
  (`md5`, `compressedMd5`, `size`, `compressedSize`, zlib); the `secure_link`
  endpoint for CDN URLs; generation 1 for older games;
- `goggame-<id>.info` play tasks.

Fixtures are scrubbed and saved for the host tests. **No token, user ID or
signed CDN URL goes into the repository**, and `pp secrets` must be clean.

**2.2 `app/GOGClient` (`GOGClientKit`, Foundation only, tested on Linux).**
- `GOGSession` (an actor, like `SteamSession`): code exchange, refresh, sign-out,
  and token storage per 0058.
- `GOGLibrary`: owned Windows games, names, sizes and art (`ArtworkCache` gets a
  store-qualified key).
- `GOGContent`: builds → manifest → depot selection (Windows; the player's language
  plus language-neutral depots; 64-bit or neutral; owned DLC only) → a ContentKit
  plan with md5-verified zlib chunks → a chunk source over secure links, with
  expiry and refresh.
- Updates: a newer build ID from `builds`. Verify: md5 per file from the retained
  depot manifests.

**2.3 App.**
- Accounts › GOG: **Sign in to GOG** opens a `WKWebView` sheet on the auth URL;
  the navigation delegate catches the redirect, takes `code` and cancels the
  load. Then the status, Refresh library and Sign out rows.
- Library **GOG** filter; tiles `gog-<id>`; the game page with Install/Play, size
  and the facts card naming GOG.
- Downloads: install, update and repair jobs for `gog-*` through the generalised
  queue (`UI/SteamInstalls.swift` is split into a store-neutral runner plus a
  per-store job driver).
- Launch: the receipt's executable, arguments and working directory (from the
  primary play task). No Steam variables, no `steam_api` swap.
- Dependencies (the build manifest's `dependencies`, such as MSVC and DirectX
  redistributables): log them. Wine's builtins usually cover them. Installing GOG's
  redist depots is left until a title needs it.

**2.4 Later, separate items (not in "done").**
- **Cloud saves:** GOG's cloud storage needs the game's own client credentials and
  its save locations from GOG's remote config; it would sync on the host before
  and after a play, like `Cloud.swift`. Write this down after Phase 2 lands.
- **Achievements and Galaxy multiplayer:** these need the Galaxy SDK answered in
  the guest and a token there (0004), so they are out of scope.

**Done when:** sign-in, the library with art, an install, a play to
`first-frame+10`, a verify and an uninstall, all on the phone. **Settled:** the
test title is chosen in the 2.1 spike from the account's owned GOG games, by
0005's scorecard (DRM-free, x86-64, D3D11, fits `MemoryNeed`). Prefer Hollow
Knight if it is owned there, so frame and JIT numbers compare with the cohort
title. An update is shown when GOG publishes a
newer build, or by installing an older build and checking that an update is offered.

## Phase 3: Epic Games

As for GOG, the API details are to be checked in 3.1.

**3.1 Research spike** (`.work/agent-notes/epic/`). Check:
- the auth: the launcher's public client ID/secret; the web login with
  `www.epicgames.com/id/api/redirect?clientId=…&responseType=code`, whose page
  body is JSON with `authorizationCode`; the token endpoint on
  `account-public-service-prod03.ol.epicgames.com` (`eg1` tokens); refresh, token
  lifetimes and session kill;
- the library (`library-service…/library/api/public/items`, cursor-paged) and the
  catalogue bulk items for names, `keyImages` (`DieselGameBoxTall`,
  `DieselGameBox`) and custom attributes (cloud save folder, ownership-token flags);
- the manifest: `launcher-public-service-prod06…/assets/v2/platform/Windows/namespace/<ns>/catalogItem/<id>/app/<appName>/label/Live`
  for the manifest URLs and CDN bases; the **binary manifest** (header, zlib body,
  chunk data list, file manifest list, custom fields) and the older JSON form;
  chunk files (header, optional zlib, SHA-1/rolling hash) under
  `ChunksV4/<group>/<hash>_<guid>.chunk`;
- `LaunchExecutable`, `LaunchCommand`, and the arguments the launcher passes
  (`-AUTH_LOGIN`, `-AUTH_PASSWORD=<exchange code>`, `-AUTH_TYPE=exchangecode`,
  `-epicapp`, `-epicenv=Prod`, `-EpicPortal`, `-epicuserid`, `-epiclocale`);
- which owned games run with no exchange code. Record this per game: it decides
  how useful 3.6 is.

**3.2 `app/EpicClient` (`EpicClientKit`).** `EpicSession`, `EpicLibrary` and
`EpicContent`: the binary manifest parser (fuzzed with truncated and oversized
inputs, sizes capped as Steam's are), a plan whose file parts slice chunks (Phase
0's parts model), and a chunk source over the CDN bases with a failover pool.
Verify uses per-file SHA-1 from the manifest.

**3.3 App.** Accounts › Epic Games (a `WKWebView` login that reads the JSON from
the redirect page), the **Epic** filter, `epic-<appName>` tiles and pages, and
Downloads jobs.

**3.4 Launch** with `LaunchExecutable` and `LaunchCommand`, and the
non-secret Epic arguments only: `-epicapp`, `-epicenv=Prod`, `-EpicPortal`,
`-epiclocale`. With no exchange code.

**3.5 What is refused up front.** The page says why, before an install:
- anti-cheat (EasyAntiCheat, BattlEye), from the catalogue's attributes or files;
- 32-bit-only titles with an API outside 0047's scope;
- titles over the phone's free space or memory class (`MemoryNeed`).

**3.6 Decision record (0059, proposed): an Epic exchange code may enter the
guest, per game.** This is an exception to 0004 in the form of 0017. An exchange
code is a one-time, short-lived code from the host session, which the game trades
for its own Epic session. That makes it stronger than Steam's app ticket: the
game's session can act for the account in Epic's online services. The record needs
the threat model, the single channel (the command line, which is in the process's
`PEB` and in Wine's process list), the measured guest-side storage, and logout.
Until it is accepted, a game that needs it gets *"This game needs Epic online
sign-in, which Playport does not support yet"*. **Settled:** 0059 is written
later, and only if 3.1 shows that games the owner wants need it. It is not part
of Phase 3.

**3.7 Later:** Epic cloud saves (the datastorage service plus the catalogue's save
folder attribute, host-side as for Steam).

**Done when:** sign-in, the library with art, the install, a play to
`first-frame+10` and a verify on the phone. **Settled:** the title is chosen in
3.1 from the account's owned Epic games that run without an exchange code and fit
`MemoryNeed`, by 0005's scorecard. The refusals show for
one game that needs the exchange code.

## Order and size

| Phase | Depends on | Rough size | Phone gate |
| --- | --- | --- | --- |
| 0 Identity, engine core, sessions record | none | large refactor, mostly host tests | Steam install + HK play |
| 1.1–1.3 Folder import, recognition, page | 0.1–0.2 | medium | import + play |
| 1.4 Zip | 1.1 | small | zip import + play |
| 1.5 Inno installer | dropped (owner) | | |
| 1.6 Icons | 1.1 | small | a look (`--shot-each-action`) |
| 2 GOG | 0 | large (auth, library, content v2, UI) | install + play + verify |
| 3 Epic | 0 | large (binary manifest, chunk slices) | install + play + verify |
| 3.6 Exchange code | 3, a need found in 3.1, then a decision | small once decided | a game that needs it |

The writer does one chunk at a time and commits it (AGENTS.md). Every chunk ends
with `./pp test` and `./pp check` (or `./pp build`); the phone is used only at each
phase's gate (owner, 2026-10-06), where Hollow Knight to `first-frame+10 --shot`
runs on the IPA the phase commits. Each phase writes one evidence
record (`docs/evidence/<date>-<topic>.md`) with the IPA's sha256. No upstream
series changes are expected. If a title needs one (for example a missing Wine
builtin for a GOG redist), it is a patch with trailers, and the phase's gate is
that title plus Hollow Knight.

## Risks

- **Store terms.** Both store integrations use the stores' own desktop-client
  OAuth identities, which is the only route open to a third-party client. The
  stores tolerate this today but could block it. The owner accepted this risk;
  0058 records it.
- **Disk.** An imported folder can briefly take twice its size; cloning only
  helps on the same volume. The free-space check comes first, and the stage is
  resumable.
- **Phone memory and JIT.** Epic's library is mostly Unreal 4/5 games, many of them
  DX12 (0044 sends those to Vulkan) and heavy. Expect few to fit; the 3.1 spike
  should list candidates against `MemoryNeed`.
- **Launchers.** Some GOG play tasks and Epic `LaunchExecutable`s point at
  launchers. Adoption's preference for the real executable (Unreal `-Shipping`,
  not `REDprelauncher`) carries over, and the page's executable picker (1.3)
  is the escape hatch.
- **Token formats in logs.** New redaction rules come with tests before any
  network code ships (0058).
- **Release variant.** Store code is product code, not `Dev/`. `pp verify
  --variant release` must stay clean.

## Not in this plan

- Amazon, itch.io, EA app, Ubisoft Connect and Battle.net.
- Running GOG Galaxy or the Epic launcher inside Wine.
- Galaxy SDK achievements and multiplayer; Epic Online Services features beyond
  launch.
- Installers of any kind, GOG's offline ones included (1.5, dropped by the owner).
- Sharing one install between stores (a GOG and a Steam copy of one game stay
  two copies, as 0045 says).

## Settled (owner, 2026-10-06)

1. **Store logins:** yes, with the stores' public desktop-client OAuth identities
   in an in-app `WKWebView`. Decision 0058 records it and the risk (0.4).
2. **Installer import:** dropped (later answer, same day): installers are not run (1.5).
3. **Import tests:** first the owner's hand pick; then (later answer, same day) the
   workstation drives it with `pp ui --action import:PATH` (1.7).
4. **Test titles:** both are chosen in the research spikes (2.1, 3.1) by 0005's
   scorecard. For GOG, Hollow Knight is preferred if owned.
5. **Engine layout:** a new `app/ContentKit` package (0.3).
6. **Epic exchange code:** decision 0059 waits until 3.1 shows a wanted game
   needs it; until then those games are refused with a message (3.6).
7. **Sources are separate** (later answer, same day): Local, Steam, GOG and Epic; an
   import is Local whatever store its files came from (0057, 1.2).

# Plan: the release app runs Valve's defaults; emulator tuning is dev-only

**Linear:** [PLA-73](https://linear.app/playportdev/issue/PLA-73).
**Repository path:** `docs/plans/2026-10-05-release-simplification.md`.
**Status 2026-10-19:** still not started; the 2026-10-13 review below holds, except:
- the next free decision number is now **0118** (0117 is the highest);
- [decision 0115](../decisions/0115-a-steam-client-for-the-launched-app.md) (PLA-398) changed the
  release block in `LibraryModel.play` (now `UI/LibraryModel.swift:230-243`). It still forces
  the emulator, unless the title's compatibility default names `client`; that is RDR2
  (1174180) only today. So the "Steam API" point below is handled for that one case, by a
  special case rather than step 3's one path;
- the compatibility table now holds two titles: RDR2 (`windowsServices`, `jitPoolMB`,
  `steamAPI`, `graphics`) and an Epic title's aspect ratio.

**Review 2026-10-13:** open, not started. No step below is implemented: the release app
still shows the Metal HUD switch, About's Build and Runtime interface rows and Setup
check's JIT memory row, and `LibraryModel.play` still resets the dev-only fields by hand
(`UI/LibraryModel.swift:229-243`). What changed since 2026-10-05:

- **Decision number.** 0049 is taken (the pin policy, `0049-latest-pins.md`); the highest
  record is 0104. Step 1 takes the next free number when it is written.
- **New launch settings,** classified in step 2 and the appendix: the aspect ratio
  ([0073](../decisions/0073-screen-aspect-ratio.md), both variants, kept), the FEX disk
  cache ([0056](../decisions/0056-fex-disk-cache-on.md), a dev page's, dev-only) and the
  Vulkan layers' Graphics options ([0060](../decisions/0060-graphics-options.md), dev-only).
  [0055](../decisions/0055-maxinst-500-global.md) took Proton's `MaxInst=500`.
- **Compatibility defaults** ([0074](../decisions/0074-per-title-compatibility-defaults.md),
  [0091](../decisions/0091-compat-default-keys-merge.md)) are shipped data that can set any
  launch setting, dev-only ones included. Today the release block resets `runtime` and the
  graphics environment *after* the default is merged, so a default's Runtime keys or
  Graphics options would not reach a release launch (the table holds only Super Meat Boy's
  aspect ratio now, so nothing is lost yet). Step 3 filters the person's stored values
  before the merge instead; the owner confirms this in step 1.
- **Display modes** ([0097](../decisions/0097-display-mode-emulation.md)) add no control:
  the runtime emulates a game's mode change in both variants.
- **Steam API.** The Steam client bridge plan
  ([2026-10-12-steamclient-bridge.md](2026-10-12-steamclient-bridge.md), PLA-253) adds a
  `client` mode, set per title by a compatibility default or a dev page until its
  default flips, and the owner's D7 (2026-10-13) removes the emulator right after the
  bridge is proven (PLA-256). So the release app's Steam API is Playport's default for the
  title (the emulator today), never a stored player value, and step 3's one path is what
  lets a `client` compatibility default reach a release launch (the release block forces
  `.emulated` today).
- **Release gates.** [0068](../decisions/0068-release-owner-signoff.md): no `pp ui`,
  `pp perf` or scripted gate runs against the release app; the owner signs it off. Step 8
  now proves the change on the dev app and by host tests, and leaves the release app to the
  owner's sign-off.
- **Direct3D** stays a release row (owner, 2026-10-05). Under
  [0100](../decisions/0100-vulkan-is-the-direction.md) DXMT will be dropped; the row's
  future is that record's later work, not this plan's.

**Date:** 2026-10-05. **Status:** plan. Nothing is implemented yet. The
inventory behind it (every control, its file and line, and who needs it) is in
the appendix below, refreshed 2026-10-13. The owner settled the open questions on
2026-10-05; their answers are folded in.
**Decision to write:** the next free number (step 1); 0049 was a placeholder.

## Goal

`Playport.app` (release, decision 0009) holds only what a player acts on. Knobs
that tune the x86 emulator or the runtime exist only in `S1Probe.app` (dev):
FEX memory ordering, block size, x87 precision, the disk cache, runtime keys, Graphics
options, the Steam API choice, the persistent Metal HUD and the diagnostics. A release
launch takes those from Playport's defaults:

- Proton's FEX values, from `FEXProfile`: the global configuration plus
  per-game profiles (0021, 0048, 0055; the disk cache as 0056 holds it);
- the cohort entry's `madeira.cfg` keys, and the title's compatibility default
  (0074/0091), which is shipped data;
- Playport's Steam API for the title: the emulator today, the bridge's `client`
  where a compatibility default or its plan's per-class default sets it, and only the
  bridge after the emulator is removed (Review 2026-10-13, bridge plan D7).

What the player keeps, globally and per game (owner, 2026-10-05):

- **Aspect ratio** (added by 0073 on 2026-10-08, both variants; Review 2026-10-13),
  **resolution** and **frame rate limit**;
- **Direct3D** (DXMT or Vulkan, over the 0044/0047 detection): it is not yet
  known which games run on which backend, so a player must be able to switch;
- **Launch arguments**, as Steam offers them.

No dev-only value a dev build stored can change a release launch. The dev
build keeps every control it has today, because `pp ui`, `pp perf` and the
evidence depend on them.

## Target release UI

- **Settings › Graphics.** Rows: Aspect ratio, Resolution, Frame rate limit,
  Direct3D. The note keeps the battery and heat sentence, the aspect ratio sentence
  and the backend sentence. There is no Metal HUD row.
- **Settings › Accounts (Steam, GOG, Epic Games), Downloads, Controllers, Storage
  (with the Emulator cache and Steamworks Shared rows).** Unchanged.
- **Settings › Setup check.** Unchanged (JIT method included, 0051), except that the
  *JIT memory* row becomes dev-only.
- **Settings › About.** Version, Licences and the copyright. *Build* and
  *Runtime interface* become dev-only.
- **Game page.** Unchanged.
- **Game options.**
  - Graphics: the compatibility note (when the title has a default, 0074), Aspect
    ratio, Resolution, Frame rate limit, Direct3D, Launch arguments.
  - Game: Version, Cloud saves (and the conflict row), Executable and Name (a game
    without a store's launch record), Check game files / Repair (Steam, Epic Games,
    GOG), Achievements, Report a problem, Uninstall.
  - As today, no Developer section.
- **In-game menu.** Unchanged rows. *Performance overlay* starts off at every
  game start and lasts for that game only.
- **Home, Library, Downloads, sign-in, checklist, cloud conflict and launch
  screens.** Unchanged.

## Steps

### 1. A decision record: release runs Valve's defaults; emulator tuning is dev-only

A new record, at the next free number when it is written (0049 is the pin policy;
Review 2026-10-13). Add its line to `docs/decisions/README.md`. It covers:

- **Release.** The release app offers the aspect ratio, resolution, frame rate
  limit, the Direct3D backend and launch arguments, globally and per game, plus
  Steam-client choices (version, cloud saves).
- **Dev-only knobs.** FEX ordering, block size, x87 precision, the disk cache,
  runtime keys, Graphics options, the Steam API choice and the persistent Metal HUD
  are a dev build's.
- **Defaults.** We assume Valve/Proton defaults are ours. A game that needs
  another emulator value gets it as data (a `FEXProfile` entry, a cohort
  entry or a compatibility default, 0074/0091), not as a player switch.
- **Release launches.** A release launch ignores every value the person stored
  outside what the release app offers. A title's compatibility default applies in
  both variants, dev-only fields included (Review 2026-10-13: proposed; the owner
  confirms it here, since today's release block drops a default's Runtime keys and
  Graphics options).
- **Steam API** (Review 2026-10-13). The release app's Steam API is Playport's
  default for the title, from data: the emulator today, the bridge's `client` mode
  where a compatibility default or the bridge plan's per-class default sets it. The
  record names no permanent emulator default: the owner's D7 removes the emulator
  right after the bridge is proven (PLA-256), and the dev page's Steam API row then
  loses its emulator choice.

It restates 0034's "Fewer knobs" (the FEX controls already left the release
app there) and keeps 0044/0047's "explicit choices still win" for release.
0048's and 0055's dev pickers, 0056's dev Disk cache row and 0060's dev Graphics
options stand. Add a status line to each record it touches.

### 2. PlayportKit: one definition of what a release reads

In `LaunchSettings.swift`, add `LaunchSettings.playerSettings` (name to
match), a computed copy that keeps `screen`, `aspect`, `frameLimit`, `graphics`,
`arguments` and `cloudSync`. Every other field takes its default: `steamAPI`
nil, `ordering` empty, `maxInst` nil, `x87Reduced` nil, `diskCache` nil, `runtime`
"", `graphicsOptions` "". Its doc comment names the step 1 record. (Review
2026-10-13: `aspect`, `diskCache` and `graphicsOptions` were added after the plan,
`LaunchSettings.swift:16-56`.)

Tests in `PlayportKitTests.swift`, beside `testOrderingIsPerGameAndRoundTrips`
(`:718`):

- **It keeps exactly the player fields.** A fully set `LaunchSettings` maps to
  one with only those six fields set.
- **A compatibility default still applies.** `playerSettings.over(compat)` for a
  default with `runtime` and `graphicsOptions` keeps the default's items (beside
  the 0091 merge tests in `CompatDefaultsTests.swift`).
- **Ordering and x87 use the profile.**
  `FEXProfile.launch(…, ordering: MemoryOrdering(), maxInst: nil, x87Reduced: nil)`
  gives Proton's values: `tso=1 halfbar=1 vector=0 memcpyset=0`,
  `FEX_X87REDUCEDPRECISION=1`, `FEX_MAXINST=500`, and The Witcher 3's `setup*` entry
  at 0. Extend the existing tests `testProtonsDefaultsAreScalarOrderingWithHalfBarriers`
  (`:745`) and `testAGamesProfileAppliesToTheExecutablesItNames` (`:766`) rather than
  duplicate.

### 3. The app: release launches read `playerSettings`

`UI/LaunchSettingsStore.swift` (`effective(for:)`, `:51-59`):

- Under `#if PLAYPORT_RELEASE`, filter the person's stored values before the
  compatibility default goes over them: `games[id]?.playerSettings`, then
  `.over(compat)`, and `global.playerSettings` to `resolve`.
- Ignore, do not delete. The stored JSON keeps the dev keys, so a dev install
  over the release app gets them back.

`UI/LibraryModel.swift:229-243`:

- Replace the `#if PLAYPORT_RELEASE` block, which resets seven fields after the
  merge, with the store's filtered `effective`. There is then one path; the Steam
  API mode is the default's (`.emulated` from `steamAPI: nil`, or a compatibility
  default's), which a bridge `client` default needs (Review 2026-10-13).

`HostIO.swift` (`MetalHUD`, `:528-553`):

- In release, `enabled` is `false`. The in-game menu's overlay
  (`InGameMenuView.swift:39`) starts off, and `show(on:)` hides it, whatever
  `metalHUD` holds.
- `loadAtStart` still sets `MTL_HUD_ENABLED=1`, so the in-game toggle works.

### 4. The app: move controls behind the dev condition

Where possible, move code into `app/Sources/S1Probe/Dev/`, so that
`verify-ipa.py`'s type check covers it:

- **New `Dev/DeveloperGameOptions.swift`.** Move `developerRows`,
  `developerFacts` and the steamAPI/stub texts out of
  `GameDetailView.swift:912-1091` into a `struct DeveloperGameOptions: View`.
  Keep row ids (`opt:ordering-*`, `opt:maxInst`, `opt:x87Reduced`,
  `opt:diskCache`, `opt:runtime`, `opt:graphicsOptions`, `opt:steamAPI`, …) and
  their order in dev unchanged, so `pp ui` `open:ID#SECTION` and `pad:` scripts
  still work.
- **Settings › Graphics:** the Metal HUD switch behind `#if !PLAYPORT_RELEASE`
  (`SettingsView.swift:282-283`). The Direct3D row and its footer stay.
- **`LaunchSettingsText`** (`LaunchSettingsStore.swift:147-171`): move
  `ordering`, `orderingFooter`, `diskCacheFooter` and `x87Footer` into a Dev/
  extension.
- **Behind `#if !PLAYPORT_RELEASE`:**
  - `SettingsView.swift:411-416`: About's Build and Runtime interface rows.
  - `SetupCheckSettings.swift:213`: JIT memory.
- **Not touched:** the existing dev-only rows (Account renewal and preview,
  Setup previews, the JIT full panel, the memory facts, Settings › Developer).

Add `DeveloperGameOptions` (and any other new Dev/ type) to `DEV_TYPES` in
`build/verify-ipa.py:148`.

### 5. `pp verify --variant release`: dev-only control text

Add to `DEV_STRINGS` (`build/verify-ipa.py:150`) literal texts that only the
dev-only rows carry. Swift stores a literal of 15 UTF-8 bytes or fewer inline
in code, not in `__cstring`, so only longer literals can be found, for example
`Vector loads and stores`, `Block copies and fills`, `Unaligned atomics`,
`How closely the x86 emulator keeps`, `The precision at which the x86
emulator`, `Whether the x86 emulator keeps the code`, `Runtime interface`,
`Forget the cloud sync`, `For example vram-mb`, `For example dxvk.tilerMode`.
Check each with `strings` on a dev and a release executable before committing
the list. Name the check's line "variant: none of the dev-only controls' text".

A test in `tools/tests` (beside `test_release.py`) runs `release_checks` on a
stub executable holding one of these strings and expects the failure, without
needing `llvm-nm`.

### 6. Docs

- **`docs/DEVICE.md:275-297` (Launch settings).** The release app reads only
  the person's `screen`, `aspect`, `frameLimit`, `graphics`, `arguments` and
  `cloudSync`, with the title's compatibility default over them. At :417-418
  add: a release install over the dev app keeps whatever a session left, but
  reads only the player fields. Release is installed on demand only
  (`pp install --variant release`), never automatically, so a pending dev
  session undo needs no guard (owner, 2026-10-05).
- **`docs/BUILDING.md`, "Variants" (`:252`).** The new verify line.

### 7. Checks and commit

- `./pp check`, then `./pp test`.
- `./pp build`, then `./pp build --variant release`; `pp verify --variant
  release` on the new IPA. `pp verify` on the dev IPA still passes.
- Commit as one chunk with the step 1 record, the docs and any changed build
  records.

### 8. On the phone

**Review 2026-10-13:** reconciled with
[0068](../decisions/0068-release-owner-signoff.md). The change is proved on the dev
app, as `AGENTS.md` asks for a runtime and a UI change; no `pp ui`, `pp perf` or
scripted gate runs against the release app, and none is required. What a release
launch reads is proved by steps 2 and 5 on the host (`playerSettings`, the filtered
`effective`, `pp verify --variant release`). The earlier hand walk of the release app
under one lock (dev overrides left with `--keep-settings`, `pp install --variant
release`, a person's walk and `playport.log` pull, an evidence record) is withdrawn.

1. **Dev.** `pp install`, then a driven walk proves the dev app is unchanged:
   `pp ui --action open:settings#graphics --action open:app-367520#graphics --action open:app-367520#developer --shot-each-action`,
   and `pp ui --play app-367520 --until first-frame+10` and the same for
   `app-620`.
2. **Release.** The owner's sign-off at the next release covers it (0068: a comment
   on the release's Linear issue with the date, the IPA's sha256 and what the owner
   tried). A useful case for the owner to try, not a required gate: a release
   install over a dev container that holds dev overrides, then Hollow Knight from the
   Home Screen, with no Metal HUD at start and the FEX line in `playport.log` at
   Proton's values.

## Out of scope

- Proton's remaining global FEX values: `MaxInst=500` is taken by 0055 (item A1 of the
  [Proton alignment plan](finished.md#proton-arm64-alignment)); the disk cache is on by default
  (0056). The owner's direction is that Valve's defaults are ours.
- The Steam bridge itself and the emulator's removal (PLA-253, PLA-256); this plan
  only keeps the release app's Steam API a default, not a stored value.
- Dropping DXMT and with it the Direct3D row (0100's later record).
- Wording or layout changes beyond removing rows.

## Settled (owner, 2026-10-05)

- Direct3D stays a release knob, globally and per game.
- Launch arguments stay in release.
- Per-game resolution and frame rate limit stay.
- No guard against a pending dev undo record: the release variant is installed
  only on demand.

## Appendix: inventory (2026-10-05, refreshed 2026-10-13)

Visibility: **both** means dev and release, **dev** means
`#if !PLAYPORT_RELEASE` or Dev/. Who needs it: P is the player, T a tester, D
the developer. Driver: how `pp ui` reaches it (dev only, decision 0012). Class
is the proposed target: **keep** (in release), **dev** (dev-only) or
**remove**.

Review 2026-10-13: file and line references re-read at the tree of that day
(paths under `app/Sources/S1Probe/` unless named). Rows marked *(new)* were added
after 2026-10-05; their Class follows the decision that added them. The classes of the
2026-10-05 rows are unchanged.

#### Settings (≡) — `UI/SettingsView.swift` and its sections

| Control | file:line | What it controls | Now | Who | Driver | Class |
|---|---|---|---|---|---|---|
| Sections list (Accounts, Graphics, Downloads, Controllers, Storage, Setup check, About, Developer) | SettingsView.swift:39-45, 79-90, 141-161; PlayportKit SettingsModel.swift:15-36 | navigation; Developer only in dev | both / Developer dev | P | `open:settings#NAME` | keep (Developer stays dev) |
| Graphics › Aspect ratio (Phone/16:9/16:10/4:3) *(new, 0073)* | SettingsView.swift:265-271 | `global.aspect` (default Phone) | both | P | UI row; per game `--settings {"aspect":…}` | **keep** (0073: both variants) |
| Graphics › Resolution (‹ 540p…Native ›) | SettingsView.swift:272-274 | `LaunchSettings.global.screen` (default 720) | both | P (battery/heat vs sharpness) | `set:` n/a; global via UI rows / `pad:` | **keep** |
| Graphics › Frame rate limit (30/40/60/Off) | SettingsView.swift:275-277 | `global.frameLimit` (default 60) | both | P | as above | **keep** |
| Graphics › Direct3D (DXMT/Vulkan) | SettingsView.swift:278-281 | `global.graphics`; a value overrides 0044/0047 detection for **every** game (0047 notes a global DXMT breaks i386 titles) | both | P | UI row; per game `--settings {"graphics":…}` | **keep** (owner; 0100 drops DXMT later) |
| Graphics › Metal HUD | SettingsView.swift:282-283; HostIO.swift:528-553 | `metalHUD` UserDefaults; HUD on every game layer at start; dev also logs it (`pp perf`) | both | D (perf); P has the in-game overlay | `hud:on/off`, `set:metalHUD=` | **dev** (release: overlay only from the in-game menu, off at each start) |
| Graphics note (footer: aspect, DXMT/Vulkan/KosmicKrisp text) | SettingsView.swift:284-288; LaunchSettingsStore.swift:143-145 | text | both | P/D | — | keep (Target release UI: battery, aspect and backend sentences) |
| Downloads › Update games by themselves | SettingsView.swift:309-310 | `downloads.autoUpdate` | both | P | `set:downloads.autoUpdate=` | keep |
| Downloads › Download over cellular | SettingsView.swift:311-312 | `downloads.cellular` | both | P | `set:` | keep |
| Downloads › Dim the screen while downloading | SettingsView.swift:313-314 | `downloads.dim` | both | P | `set:` | keep |
| Downloads › Sync saves with Steam Cloud | SettingsView.swift:315-316 | `steamCloud` (global) | both | P | `set:steamCloud=` | keep |
| Controllers (list, battery) | SettingsView.swift:324-342 | info only | both | P | `open:settings#controllers` | keep |
| Storage (free, games, per-game size → page) | SettingsView.swift:347-361 | info, navigation | both | P | — | keep |
| Storage › Steamworks Shared *(new, 0081, PLA-171)* | SettingsView.swift:362-376 | size; removes Steam's shared redistributables | both | P | — | keep |
| Storage › Emulator cache *(new, 0056)* | SettingsView.swift:377-394; EmulatorCache.swift | FEX disk cache size; Clear | both | P | — | keep (0056: Settings › Storage clears it) |
| About › Version | SettingsView.swift:410 | info | both | P | — | keep |
| About › Build (Release/Development) | SettingsView.swift:411-415 | info | both | D | — | **dev** (Version is enough for a player) |
| About › Runtime interface (wine_host ABI) | SettingsView.swift:416 | info | both | D | — | **dev** (Developer section already repeats it, Dev/DeveloperSettings.swift:36) |
| About › Licences | SettingsView.swift:417-420; LicencesView.swift | licence pages | both | P (GPL) | `open:licences` | keep |
| Accounts › Steam: status, Sign in, Refresh library, Sign out | AccountView.swift:15, 23, 46, 52 | Steam session | both | P | `open:settings#steam`, sign-in UI | keep |
| Accounts › Steam: Last renewal check | AccountView.swift:39-45 | raw result | dev | D | — | dev (as is) |
| Accounts › Steam: Preview sign-in | AccountView.swift:60-64 | preview | dev | D | — | dev (as is) |
| Accounts › GOG: status, Sign in, Refresh library, Sign out *(new, 0063)* | GOGAccount.swift:341-370 | GOG session | both | P | `open:settings#accounts` | keep |
| Accounts › Epic Games: status, Sign in, Refresh library, Sign out *(new, 0059)* | EpicAccount.swift:414-443 | Epic session | both | P | `open:settings#accounts` | keep |
| Setup check › Setup checklist | SetupCheckSettings.swift:41-46 | opens first-run checklist | both | P | `open:setup` | keep |
| Setup check › Preview a first run (iOS 27/26) | SetupCheckSettings.swift:47-54 | simulated checklist | dev | D | — | dev (as is) |
| Setup check › Controller | SetupCheckSettings.swift:55-57 | info | both | P | — | keep |
| Setup check › LocalDevVPN | SetupCheckSettings.swift:59-66 | connect | both | P | — | keep |
| Setup check › Accounts (was Steam) | SetupCheckSettings.swift:82-89 | → Settings › Accounts | both | P | — | keep |
| Setup check › JIT method (Built-in, StikDebug, another app) *(new, 0051)* | SetupCheckSettings.swift:94-99; JitMethodPicker.swift | how a Play gets JIT | both | P | `jit:*` | keep |
| Setup check › JIT (release: plain status; dev: raw readiness, pairing file row) | SetupCheckSettings.swift:100-113, 129-184 | JIT state | both (two forms) | P / D | `jit:*` | keep (as is) |
| Setup check › Pair this iPhone / Pair again (iOS 27) | SetupCheckSettings.swift:186-195 | on-device pairing (0033) | both | P | `jit:setup`, `jit:pair` | keep |
| Setup check › Import pairing file | SetupCheckSettings.swift:197-203 | Files import | both | P (iOS 26, recovery) | touch only | keep |
| Setup check › Check again / Download the disk image again (release, on failure) | SetupCheckSettings.swift:136-141 | retry | release | P | — | keep |
| Setup check › Check readiness / Reset DDI (dev, always) | SetupCheckSettings.swift:176-183 | retry | dev | D | — | dev (as is) |
| Setup check › Memory limit | SetupCheckSettings.swift:208-209 | info (what refuses a Play) | both | P | — | keep |
| Setup check › Increased Memory Limit | SetupCheckSettings.swift:210-212 | info (how the IPA was signed) | both | P/T (re-signer) | — | keep |
| Setup check › JIT memory (512 MiB, 0036) | SetupCheckSettings.swift:213; PlayportKit JitPool.swift:31-44 | info, a constant | both | D | — | **dev** |
| Setup check › Real limit, In use now, Phone | SetupCheckSettings.swift:214-221 | info | dev | D | — | dev (as is) |
| Developer › GPU capture, GPU time per pass, CPU sampling, Metal validation, Runtime counters, Fastsync *(Fastsync new, madeira-unix 0081, 0054)* | Dev/DeveloperSettings.swift:41-60 | Diagnostics keys; `dev.fastsyncOff` (Fastsync.swift) | dev | D | `set:gpuCapture=` … | dev (as is) |
| Developer › Simulated limit, Simulated JIT memory | Dev/DeveloperSettings.swift:64-78 | MemoryLimit keys | dev | D | `set:memoryLimitSimulatedMB=` … | dev (as is) |
| Developer › On-device pairing (experiment) | Dev/DeveloperSettings.swift:86-97 | probe | dev | D | `probe:pairing*` | dev (as is) |
| Developer › Probes (Native authentication *(new)*, helper lifetime ×4, Restart now, Black screen *(new)*) | Dev/DeveloperSettings.swift:102-125 | probes; the unattended black screen | dev | D | `probe:*` | dev (as is) |
| Developer › Logs (share), wine_host ABI | Dev/DeveloperSettings.swift:129-137, 36 | logs | dev | D | — | dev (as is) |

#### A game's page and Game options — `UI/GameDetailView.swift`

| Control | file:line | What it controls | Now | Who | Driver | Class |
|---|---|---|---|---|---|---|
| Play | :330 | launch | both | P | `--play ID` | keep |
| Achievements button / panel | :333-336, 780-782, 1096+ | Steam stats | both | P | — | keep |
| Options (X) | :337-339 | opens Game options | both | P | `open:ID#SECTION` | keep |
| Update (Steam, GOG, Epic Games) | :340-352 | store update | both | P | — | keep |
| Install / Resume download / Discard / Version (X) | :356-397, 449+ | store install, Steam betas | both | P | `install:APP` | keep |
| Download Pause/Resume, Cancel | :400-420 | job | both | P | `pause-resume:APP` | keep |
| Close Playport (after a game, 0030) | :328 | exit | both | P | — | keep |
| Options › compatibility note *(new, 0074)* | :687-691 | the title's compatibility default and its reason | both | P | — | keep |
| Options › Aspect ratio *(new, 0073)* | :693-702 | game `aspect` over its compatibility default | both | P | `--settings {"aspect":…}` | **keep** (0073) |
| Options › Resolution | :704-716 | game `screen` | both | P | `--settings {"screen":…}` | **keep** |
| Options › Frame rate limit | :718-726 | game `frameLimit` | both | P | `--settings {"frameLimit":…}` | **keep** |
| Options › Direct3D | :727-736 | game `graphics` over global over detection (0044/0047) | both | P | `--settings {"graphics":…}` | **keep** (owner) |
| Options › Launch arguments (keyboard) | :738-744 | game `arguments`, added after the cohort's; also moves DX12 detection (0044) | both | P | `--settings {"arguments":…}` | **keep** (owner) |
| Options › Version (betas) | :752-755 | Steam branch | both | P | — | keep |
| Options › Cloud saves (per game) | :756-767 | game `cloudSync` | both | P | `--settings {"cloudSync":false}` | keep |
| Options › Choose which save to keep | :768-776; CloudConflictView.swift:124 | conflict | both | P | — | keep |
| Options › Executable, Name (no store launch record) *(new)* | :789-813 | which executable Play starts; the shown name | both | P | — | keep |
| Options › Check game files / Repair from Steam, Epic Games or GOG | :823-850 | verify, repair | both | P | `verify:ID` | keep |
| Options › Report a problem | :784-785, 1220+ | share sheet with log | both | P | — | keep |
| Options › Uninstall | :869-890 | uninstall | both | P | `uninstall:ID` | keep |
| Options › Developer › x86 memory ordering ×4 (Loads and stores, Unaligned atomics, Vector, Block copies) | :921-938 | `ordering` (0021) | dev | D | `--settings {"ordering":…}` | dev (as is) |
| Options › Developer › Block size | :939-950 | `maxInst` (0055) | dev | D | `--settings {"maxInst":…}` | dev (as is) |
| Options › Developer › x87 precision | :951-962 | `x87Reduced` (0048) | dev | D | `--settings {"x87Reduced":…}` | dev (as is) |
| Options › Developer › Disk cache *(new, 0056)* | :963-973 | `diskCache` | dev | D | `--settings {"diskCache":…}` | dev (as is) |
| Options › Developer › Runtime keys, with a default's keys shown *(0091)* | :974-988 | `runtime` (madeira.cfg keys) | dev | D | `--settings {"runtime":…}` | dev (as is) |
| Options › Developer › Graphics options *(new, 0060)* | :989-1000 | `graphicsOptions` (allowlisted Vulkan layer variables) | dev | D | `--settings {"graphicsOptions":…}` | dev (as is) |
| Options › Developer › Steam API | :1001-1015, 1070+ | `steamAPI` (emulator or the game's own; the bridge plan adds `client`) | dev | D | `--settings {"steamAPI":…}` | dev (as is; the emulator choice goes with PLA-256) |
| Options › Developer › facts, Forget the cloud sync, Update from Steam | :1017-1036, 1040-1069 | info, Steam | dev | D | — | dev (as is) |
| Not-installed / error wording | :156-162, 430-437, 857-866, 890-899 | text | release-specific text | P | — | keep (as is) |

#### Other screens

| Control | file:line | What it controls | Now | Who | Class |
|---|---|---|---|---|---|
| In-game menu: Resume, Screenshot, Performance overlay, Controller, Quit game | PlayportKit QuickMenu.swift:10-18; InGameMenuView.swift:39, 95, 124-128 | pause menu; overlay = Metal HUD for this game only, starting from `metalHUD` | both | P | keep all; release overlay starts **off** (ignores `metalHUD`) |
| In-game menu: screenshot copy in Documents | InGameMenuView.swift:142-144, 220+ | dev file | dev | D | dev (as is) |
| Library: Search, Filter & sort, store filters, Add a game *(Add a game new)* | LibraryView.swift:40-66; Import.swift | browse (0045); import a folder or .zip | both | P | keep |
| Home: hero, downloads, Find games | HomeView.swift:79-187 | navigation | both | P | keep |
| Downloads: queue, Pause/Resume, Cancel (confirm), Dim now | DownloadsView.swift:93-99, 132-158 | queue | both | P | keep |
| Cloud save conflict: phone / Steam / Decide later | CloudConflictView.swift:124; PlayportKit CloudChoice.swift | conflict | both | P | keep |
| Sign in: account name, password, Steam Guard, QR | SignInView.swift:60-100 | Steam sign-in | both | P | keep |
| GOG / Epic Games sign-in sheets *(new)* | GOGAccount.swift:282-340; EpicAccount.swift:308-413 | store's own sign-in page | both | P | keep |
| First-run checklist: Pairing / Pairing file, LocalDevVPN, Memory, Accounts | SetupView.swift:313-345; PlayportKit SetupChecklist.swift:19, 90-130 | setup | both (preview dev) | P | keep |
| Launch screen / result alerts | LaunchViews.swift:441-445, 480-485 | text | release-specific text | P | keep (as is) |
| Display mode change in a game *(new, 0097)* | patches/madeira-unix 0125 | the virtual monitor's mode | both (no control) | P | not a setting |

### Classification rationale (before the owner's answers: Direct3D, launch arguments and per-game resolution/frame limit stay in release)

- **Kept in release:** resolution and frame rate limit, globally and per game.
  They are the one trade a player makes knowingly: sharpness and smoothness
  against heat and battery. The defaults (720p, 60 fps,
  `docs/evidence/2026-09-29-hk-gameplay-baseline.md`) are measured, and Steam
  Deck exposes the same pair. They are not emulator internals. Everything else
  kept is Steam-client behaviour: versions, cloud, verify, achievements,
  downloads.
- **Dev-only:**
  - **The Direct3D backend.** It is an emulator internal. Proton chooses the
    translation layer itself, and Playport's 0044/0047 detection is the
    equivalent. A global choice can break i386 titles (0047's "Why and
    limits").
  - **Launch arguments.** The tested configuration already comes from the
    cohort entry's `arguments`, which is data, as Proton's per-game fixes are.
    A player-typed `-dx12` silently reroutes the backend (0044).
  - **The persistent Metal HUD switch.** It is a developer measurement tool;
    the player keeps the in-game Performance overlay.
  - **ABI, Build and JIT memory rows.** These are internals.
- **Removed entirely:** nothing. Every dev-only control serves `pp ui`,
  `pp perf` or debugging, and dev keeps them all.

# Plan: the release app runs Valve's defaults; tuning is dev-only

**Date:** 2026-10-05. **Status:** plan. Nothing is implemented yet. The
inventory behind it (every control, its file and line, and who needs it) is in
the appendix below.
**Decision to write:** 0049 (step 1).

## Goal

`Playport.app` (release, decision 0009) holds only what a player acts on. Any
knob that tunes the emulator, the graphics translation or the runtime exists
only in `S1Probe.app` (dev). A release launch always runs Playport's defaults:

- Proton's FEX values, from `FEXProfile`: the global configuration plus
  per-game profiles (0021, 0048);
- the backend detection of 0044 and 0047;
- the cohort entry's arguments and `madeira.cfg` keys;
- the Steam API emulator.

No value a dev build stored can change that. The dev build keeps every control
it has today, because `pp ui`, `pp perf` and the evidence depend on them.

## Target release UI

- **Settings › Graphics.** Rows: Resolution and Frame rate limit. The note
  keeps only the battery and heat sentence. There is no Direct3D row, no Metal
  HUD row and no Vulkan footer.
- **Settings › Downloads, Controllers, Storage, Steam account.** Unchanged.
- **Settings › Setup check.** Unchanged, except that the *JIT memory* row
  becomes dev-only.
- **Settings › About.** Version, Licences and the copyright. *Build* and
  *Runtime interface* become dev-only.
- **Game page.** Unchanged.
- **Game options.**
  - Graphics: Resolution and Frame rate limit.
  - Game: Version, Cloud saves (and the conflict row), Check game files /
    Repair, Achievements, Report a problem, Uninstall.
  - There is no Direct3D row, no Launch arguments row and, as today, no
    Developer section.
- **In-game menu.** Unchanged rows. *Performance overlay* starts off at every
  game start and lasts for that game only.
- **Home, Library, Downloads, sign-in, checklist, cloud conflict and launch
  screens.** Unchanged.

## Steps

### 1. Decision 0049: release runs Valve's defaults; tuning is dev-only

A new record. Add its line to `docs/decisions/README.md`. It covers:

- **Release.** The release app offers resolution and frame rate limit,
  globally and per game, plus Steam-client choices (version, cloud saves).
- **Dev-only knobs.** The Direct3D backend, launch arguments, FEX ordering,
  block size, x87 precision, runtime keys, the Steam API choice and the
  persistent Metal HUD are a dev build's.
- **Release launches.** A release launch ignores every stored value outside
  what the release app offers.
- **Per-game fixes.** A game that needs another value gets it as data: a
  `FEXProfile` entry, a cohort entry, or the detection. A player switch is not
  the way.

Supersedes:

- 0034: in its "Fewer knobs" bullet, Direct3D and launch arguments leave the
  release app.
- 0044 and 0047: "explicit choices still win" / "the player can still override
  the backend in Settings or Game options" holds in dev builds only.
- 0015: "opt-in per game or globally" becomes dev-only.
- The game-page override part of 0021, already moved by 0034: it states the
  final form.

0048's dev picker stands. Add a status line to each superseded record. Changing
Proton's remaining global values is not part of this record (open question 2).

### 2. PlayportKit: one definition of what a release reads

In `LaunchSettings.swift`, add `LaunchSettings.playerSettings` (name to
match), a computed copy that keeps only `screen`, `frameLimit` and
`cloudSync`. Every other field takes its default: `graphics` nil,
`arguments` "", `steamAPI` nil, `ordering` empty, `maxInst` nil,
`x87Reduced` nil, `runtime` "". Its doc comment names decision 0049.

Tests in `PlayportKitTests.swift`, beside `testOrderingIsPerGameAndRoundTrips`:

- **It keeps exactly three fields.** A fully set `LaunchSettings` maps to one
  with only `screen`, `frameLimit` and `cloudSync`.
- **Detection still decides the backend.**
  `resolve(game: g.playerSettings, global: gl.playerSettings, importsDirect3D12:, i386:)`
  with stored `graphics: .dxmt` (global and game) gives `.vulkan` for i386 and
  DX12-imported titles and `.dxmt` otherwise. This is the 0044/0047 detection.
- **Stored arguments do not reach the launch.** A stored `arguments: "-dx12"`
  neither appears in `Effective.arguments` nor moves the backend.
- **Ordering and x87 use the profile.**
  `FEXProfile.launch(…, ordering: MemoryOrdering(), maxInst: nil, x87Reduced: nil)`
  gives Proton's values: `tso=1 halfbar=1 vector=0 memcpyset=0`,
  `X87REDUCEDPRECISION=1`, and The Witcher 3's `setup*` entry at 0. The existing
  tests at `PlayportKitTests.swift:615` and `:651` cover part of this; extend
  them rather than duplicate.

### 3. The app: release launches and views read `playerSettings`

`UI/LaunchSettingsStore.swift`:

- Under `#if PLAYPORT_RELEASE`, `effective(for:)` passes
  `games[id]?.playerSettings` and `global.playerSettings` to `resolve`.
- Ignore, do not delete. The stored JSON keeps the dev keys, so a dev install
  over the release app gets them back. Release writes only change player
  fields, because the bindings write the whole struct back.
- The global must be filtered before `resolve`. Otherwise a stored global
  `graphics` would still win over detection.

`UI/LibraryModel.swift:164-175`:

- Replace the `#if PLAYPORT_RELEASE` block, which resets five fields, with the
  store's filtered `effective`. There is then one path, and the Steam API mode
  is `.emulated` from `steamAPI: nil`.

`HostIO.swift` (`MetalHUD`):

- In release, `enabled` is `false`. The in-game menu's overlay starts off, and
  `show(on:)` hides it, whatever `metalHUD` holds.
- `loadAtStart` still sets `MTL_HUD_ENABLED=1`, so the in-game toggle works.

### 4. The app: move controls behind the dev condition

Where possible, move code into `app/Sources/S1Probe/Dev/`, so that
`verify-ipa.py`'s type check covers it:

- **New `Dev/DeveloperGameOptions.swift`.**
  - Move `developerRows`, `developerFacts` and the steamAPI/stub texts out of
    `GameDetailView.swift:764-911` into a `struct DeveloperGameOptions: View`.
  - Move the **Direct3D** and **Launch arguments** rows there too, from
    `GameDetailView.swift:624-641`, as a `DeveloperGraphicsRows` view the Game
    options' Graphics section adds in dev.
  - Keep row ids (`opt:graphics`, `opt:arguments`, `opt:ordering-*`, …) and
    their order in dev unchanged, so `pp ui` `open:ID#SECTION` and `pad:` scripts
    still work.
  - `firstRow(ofSection:)` keeps its cases.
- **New `Dev/DeveloperGraphicsSettings.swift`** (or `#if !PLAYPORT_RELEASE`
  in `SettingsView.swift:268-276`): the global Direct3D row, the Metal HUD
  switch and the `graphicsFooter` sentence.
- **`LaunchSettingsText`** (`LaunchSettingsStore.swift:80-137`): move
  `graphicsDetail`, `graphics`, `graphicsRow`, `graphicsDetection`,
  `graphicsFooter`, `ordering`, `orderingFooter` and `x87Footer` into a Dev/
  extension.
- **Behind `#if !PLAYPORT_RELEASE`:**
  - `SettingsView.swift:360-365`: About's Build and Runtime interface rows.
  - `SetupCheckSettings.swift:165`: JIT memory.
- **Not touched:** the existing dev-only rows (Account renewal and preview,
  Setup previews, the JIT full panel, the memory facts, Settings › Developer).

Add `DeveloperGameOptions` and `DeveloperGraphicsRows` (and any other new Dev/
type) to `DEV_TYPES` in `build/verify-ipa.py:147`.

### 5. `pp verify --variant release`: dev-only control text

Add to `DEV_STRINGS` (`build/verify-ipa.py:149`) the literal texts that only
the dev-only rows carry. A release executable must not hold them.

Swift stores a literal of 15 UTF-8 bytes or fewer inline in code, not in
`__cstring`. So only longer literals can be found, for example:

- `Vector loads and stores`, `Block copies and fills`, `Unaligned atomics`;
- `How closely the x86 emulator keeps`;
- `The precision at which the x86 emulator`;
- `Vulkan is experimental`;
- `Launch arguments`;
- `Runtime interface`;
- `Forget the cloud sync`;
- `For example vram-mb`.

Each must be a substring of a literal in the dev code and of no release code.
Check with `strings` on a dev and a release executable before committing the
list. Name the check's line "variant: none of the dev-only controls' text",
separate from the environment-names line.

A test in `tools/tests` (beside `test_release.py`, which loads
`verify-ipa.py`) runs `release_checks` on a stub executable holding one of
these strings and expects the failure. It must not need `llvm-nm`: stub it, or
split the strings scan into its own function.

### 6. Docs

- **`docs/DEVICE.md:214-235` (Launch settings).**
  - The release app offers and reads only `screen`, `frameLimit` and
    `cloudSync`. `graphics` and `arguments` join the dev-only list.
  - At :339-340, write "a release install over the dev app keeps whatever a
    session left; it reads only the player's three fields".
- **`docs/BUILDING.md`, "Variants".** The new verify line.
- **The 0009 table.** Leave it as is: 0049 records the change.
- **README and site.** They describe the Vulkan backend as a feature; nothing
  there names a player switch, so no change. Check `site/index.html:271`'s
  "per-game options" wording still holds; it does.

### 7. Checks and commit

- `./pp check`, then `./pp test`: names, secrets, tools/tests, the PlayportKit
  tests.
- `./pp build`, then `./pp build --variant release`. Then
  `pp verify --variant release` on the new IPA: the new strings and types are
  absent. `pp verify` on the dev IPA still passes.
- Commit as one chunk with decision 0049, the docs and any changed build
  records.

### 8. On the phone

`pp ui` cannot drive the release app (0009, 0012), so the release check is
partly by hand. Run it as one lock session, and reinstall dev at the end.

1. **Dev first.** Run `pp install`. A driven walk proves the dev app is
   unchanged:

   ```sh
   pp ui --action open:settings#graphics --action open:app-367520#graphics \
     --action open:app-367520#developer --shot-each-action
   ```

   Then `pp ui --play app-367520 --until first-frame+10` and the same for
   Portal 2 (`app-620`, i386, so Vulkan by detection).
2. **Leave dev overrides in place.** In the same session, set
   `--settings 'app-367520:{"graphics":"vulkan","arguments":"-foo","x87Reduced":false}'`
   with `--keep-settings`, and `set:metalHUD=true` with `--keep-settings`.
   This makes the release app face stored overrides.
3. **Install release.** Run `pp install --variant release` under the same
   lock.
4. **A person walks the release app.**
   - Settings › Graphics, About and Setup check; Hollow Knight's Game options.
   - Take each screenshot with `pp phone shot FILE`.
   - Play Hollow Knight from the Home Screen.
   - `pp phone pull Documents/playport.log` must show that the play ran on
     DXMT with the cohort arguments only, and with no HUD.
   - The FEX line must show `x87reduced=1` with no `*` (the profile's value).
5. **Back to dev.** Run `pp install` (dev). Then
   `pp ui --settings 'app-367520:{}'` and `set:metalHUD=false` clear step 2's
   overrides.
6. **Record it.** Write `docs/evidence/2026-10-0X-release-simplification.md`
   with both IPAs' sha256 and the screenshots described in text (no images:
   `pp secrets`).

## Out of scope

- Proton's remaining global FEX values: `MaxInst=500`, and `Multiblock` (check
  FEX's own default at the pin). See open question 2.
- A per-game backend table as data (open question 3).
- Wording or layout changes beyond removing rows.

## Open questions

1. **Launch arguments in release.** Steam itself offers launch options, and
   0034 kept them for the player. This plan makes them dev-only for simplicity,
   and because `-dx12` reroutes the backend. Keep them if the owner wants
   Steam parity.
2. **Proton's `MaxInst=500` as the default.** The owner's direction is that Valve's defaults are ours; it is item A1 of `2026-10-05-proton-arm64-alignment.md`. "Valve's defaults are ours"
   implies taking it. Hollow Knight measured no difference
   (`docs/evidence/2026-09-30-hk-maxinst.md`); Portal 2 and the D3D11 cohort
   are unmeasured. This plan proposes a separate decision (0050) after a
   `pp perf` A/B on Portal 2, as 0048 planned.
3. **A game that only works on the other backend.** A release player has no
   switch. Should PlayportKit carry a per-app backend override as data (like
   `FEXProfile.protonApps`), filled as cohort testing finds such games? None is
   known today.
4. **Per-game resolution and frame limit.** Keep both levels (this plan), or
   only the global one in Settings for even fewer rows?
5. **Ignore or clear dev keys.** This plan ignores dev keys in release and
   keeps them for a later dev install. A pending `DriverUndo` record (Dev/)
   is never applied by release, so a session's player-field changes (screen,
   limit, cloud) stay in release until dev runs again. Should
   `pp install --variant release` refuse while the dev app holds an undo
   record, or is a note in DEVICE.md enough?

## Appendix: inventory (2026-10-05)

Visibility: **both** means dev and release, **dev** means
`#if !PLAYPORT_RELEASE` or Dev/. Who needs it: P is the player, T a tester, D
the developer. Driver: how `pp ui` reaches it (dev only, decision 0012). Class
is the proposed target: **keep** (in release), **dev** (dev-only) or
**remove**.

#### Settings (≡) — `UI/SettingsView.swift` and its sections

| Control | file:line | What it controls | Now | Who | Driver | Class |
|---|---|---|---|---|---|---|
| Sections list (Steam account, Graphics, Downloads, Controllers, Storage, Setup check, About, Developer) | SettingsView.swift:37-43, 77-89; PlayportKit SettingsModel.swift:16-34 | navigation; Developer only in dev | both / Developer dev | P | `open:settings#NAME` | keep (Developer stays dev) |
| Graphics › Resolution (‹ 540p…Native ›) | SettingsView.swift:262-264 | `LaunchSettings.global.screen` (default 720) | both | P (battery/heat vs sharpness) | `set:` n/a; global via UI rows / `pad:` | **keep** |
| Graphics › Frame rate limit (30/40/60/Off) | SettingsView.swift:265-267 | `global.frameLimit` (default 60) | both | P | as above | **keep** |
| Graphics › Direct3D (DXMT/Vulkan) | SettingsView.swift:268-271 | `global.graphics`; a value overrides 0044/0047 detection for **every** game (0047 notes a global DXMT breaks i386 titles) | both | D/T | UI row; per game `--settings {"graphics":…}` | **dev** |
| Graphics › Metal HUD | SettingsView.swift:272-273; HostIO.swift:475 | `metalHUD` UserDefaults; HUD on every game layer at start; dev also logs it (`pp perf`) | both | D (perf); P has the in-game overlay | `hud:on/off`, `set:metalHUD=` | **dev** (release: overlay only from the in-game menu, off at each start) |
| Graphics note (footer: DXMT/Vulkan/KosmicKrisp text) | SettingsView.swift:274-276; LaunchSettingsStore.swift:113-115 | text | both | D | — | release: battery sentence only; `graphicsFooter` dev |
| Downloads › Update games by themselves | SettingsView.swift:297 | `downloads.autoUpdate` | both | P | `set:downloads.autoUpdate=` | keep |
| Downloads › Download over cellular | SettingsView.swift:299 | `downloads.cellular` | both | P | `set:` | keep |
| Downloads › Dim the screen while downloading | SettingsView.swift:301 | `downloads.dim` | both | P | `set:` | keep |
| Downloads › Sync saves with Steam Cloud | SettingsView.swift:303 | `steamCloud` (global) | both | P | `set:steamCloud=` | keep |
| Controllers (list, battery) | SettingsView.swift:316-324 | info only | both | P | `open:settings#controllers` | keep |
| Storage (free, games, per-game size → page) | SettingsView.swift:339-349 | info, navigation | both | P | — | keep |
| About › Version | SettingsView.swift:359 | info | both | P | — | keep |
| About › Build (Release/Development) | SettingsView.swift:360-364 | info | both | D | — | **dev** (Version is enough for a player) |
| About › Runtime interface (wine_host ABI) | SettingsView.swift:365 | info | both | D | — | **dev** (Developer section already repeats it, DeveloperSettings.swift:33) |
| About › Licences | SettingsView.swift:366-369; LicencesView.swift | licence pages | both | P (GPL) | `open:licences` | keep |
| Steam account › status, Sign in, Refresh library, Sign out | AccountView.swift:15, 23, 46, 52 | Steam session | both | P | `open:settings#steam`, sign-in UI | keep |
| Steam account › Last renewal check | AccountView.swift:39-45 | raw result | dev | D | — | dev (as is) |
| Steam account › Preview sign-in | AccountView.swift:60-64 | preview | dev | D | — | dev (as is) |
| Setup check › Setup checklist | SetupCheckSettings.swift:32-37 | opens first-run checklist | both | P | `open:setup` | keep |
| Setup check › Preview a first run (iOS 27/26) | SetupCheckSettings.swift:38-45 | simulated checklist | dev | D | — | dev (as is) |
| Setup check › Controller | SetupCheckSettings.swift:46-48 | info | both | P | — | keep |
| Setup check › JIT (release: plain status; dev: raw readiness, pairing file row) | SetupCheckSettings.swift:83-137 | JIT state | both (two forms) | P / D | `jit:*` | keep (as is) |
| Setup check › Pair this iPhone / Pair again (iOS 27) | SetupCheckSettings.swift:139-147 | on-device pairing (0033) | both | P | `jit:setup`, `jit:pair` | keep |
| Setup check › Import pairing file | SetupCheckSettings.swift:149-155 | Files import | both | P (iOS 26, recovery) | touch only | keep |
| Setup check › Check again / Download disk image again (release, on failure) | SetupCheckSettings.swift:90-95 | retry | release | P | — | keep |
| Setup check › Check readiness / Reset DDI (dev, always) | SetupCheckSettings.swift:129-135 | retry | dev | D | — | dev (as is) |
| Setup check › LocalDevVPN | SetupCheckSettings.swift:50-57 | connect | both | P | — | keep |
| Setup check › Steam | SetupCheckSettings.swift:73-79 | → Steam account | both | P | — | keep |
| Setup check › Memory limit | SetupCheckSettings.swift:160-161 | info (what refuses a Play) | both | P | — | keep |
| Setup check › Increased Memory Limit | SetupCheckSettings.swift:162-164 | info (how the IPA was signed) | both | P/T (re-signer) | — | keep |
| Setup check › JIT memory (512 MiB, 0036) | SetupCheckSettings.swift:165 | info, a constant | both | D | — | **dev** |
| Setup check › Real limit, In use now, Phone | SetupCheckSettings.swift:166-173 | info | dev | D | — | dev (as is) |
| Developer › GPU capture, GPU time per pass, CPU sampling, Metal validation, Runtime counters | Dev/DeveloperSettings.swift:38-55 | Diagnostics keys | dev | D | `set:gpuCapture=` … | dev (as is) |
| Developer › Simulated limit, Simulated JIT memory | Dev/DeveloperSettings.swift:59-73 | MemoryLimit keys | dev | D | `set:memoryLimitSimulatedMB=` … | dev (as is) |
| Developer › On-device pairing (experiment) | Dev/DeveloperSettings.swift:81-93 | probe | dev | D | `probe:pairing*` | dev (as is) |
| Developer › Probes (helper lifetime ×4, Restart now) | Dev/DeveloperSettings.swift:97-113 | probes | dev | D | `probe:*` | dev (as is) |
| Developer › Logs (share), wine_host ABI | Dev/DeveloperSettings.swift:117-126, 33 | logs | dev | D | — | dev (as is) |

#### A game's page and Game options — `UI/GameDetailView.swift`

| Control | file:line | What it controls | Now | Who | Driver | Class |
|---|---|---|---|---|---|---|
| Play | GameDetailView.swift:293 | launch | both | P | `--play ID` | keep |
| Achievements button / panel | :295-298, 676-679, 916+ | Steam stats | both | P | — | keep |
| Options (X) | :299-301 | opens Game options | both | P | `open:ID#SECTION` | keep |
| Update | :302-305 | Steam update | both | P | — | keep |
| Install / Resume download / Discard / Version (X) | :313-327, 381-397 | Steam install, betas | both | P | `install:APP` | keep |
| Download Pause/Resume, Cancel | :345-350 | job | both | P | `pause-resume:APP` | keep |
| Close Playport (after a game, 0030) | :291 | exit | both | P | — | keep |
| Options › Resolution | :602-614 | game `screen` | both | P | `--settings {"screen":…}` | **keep** |
| Options › Frame rate limit | :615-623 | game `frameLimit` | both | P | `--settings {"frameLimit":…}` | **keep** |
| Options › Direct3D | :624-634 | game `graphics` over global over detection (0044/0047) | both | D/T | `--settings {"graphics":…}` | **dev** |
| Options › Launch arguments (keyboard) | :635-641 | game `arguments`, added after the cohort's; also moves DX12 detection (0044) | both | D/T (power user) | `--settings {"arguments":…}` | **dev** (see open question 1) |
| Options › Version (betas) | :649-652 | Steam branch | both | P | — | keep |
| Options › Cloud saves (per game) | :653-664 | game `cloudSync` | both | P | `--settings {"cloudSync":false}` | keep |
| Options › Choose which save to keep | :665-673; CloudConflictView.swift:103-124 | conflict | both | P | — | keep |
| Options › Check game files / Repair from Steam | :686-699 | verify, repair | both | P | `verify:ID` | keep |
| Options › Report a problem | :680-681, 1040-1058 | share sheet with log | both | P | — | keep |
| Options › Uninstall | :720-740 | uninstall | both | P | `uninstall:ID` | keep |
| Options › Developer › x86 memory ordering ×4 (Loads and stores, Unaligned atomics, Vector, Block copies) | :774-786 | `ordering` (0021) | dev | D | `--settings {"ordering":…}` | dev (as is) |
| Options › Developer › Block size | :787-798 | `maxInst` | dev | D | `--settings {"maxInst":…}` | dev (as is) |
| Options › Developer › x87 precision | :799-811 | `x87Reduced` (0048) | dev | D | `--settings {"x87Reduced":…}` | dev (as is) |
| Options › Developer › Runtime keys | :812-820 | `runtime` (madeira.cfg keys) | dev | D | `--settings {"runtime":…}` | dev (as is) |
| Options › Developer › Steam API | :821-836 | `steamAPI` | dev | D | `--settings {"steamAPI":…}` | dev (as is) |
| Options › Developer › facts, Forget the cloud sync, Update from Steam | :837-856, 860-888 | info, Steam | dev | D | — | dev (as is) |
| Not-installed / error wording | :132-136, 364-369, 711-716, 744-749 | text | release-specific text | P | — | keep (as is) |

#### Other screens

| Control | file:line | What it controls | Now | Who | Class |
|---|---|---|---|---|---|
| In-game menu: Resume, Screenshot, Performance overlay, Controller, Quit game | PlayportKit QuickMenu.swift:9-20; InGameMenuView.swift:83-92, 120-121 | pause menu; overlay = Metal HUD for this game only, starting from `metalHUD` | both | P | keep all; release overlay starts **off** (ignores `metalHUD`) |
| In-game menu: screenshot copy in Documents | InGameMenuView.swift:135-137, 168-182 | dev file | dev | D | dev (as is) |
| Library: Search, Filter & sort, store filters | LibraryView.swift:36, 47, 280-287 | browse (0045) | both | P | keep |
| Home: hero, downloads, Find games | HomeView.swift:79-186 | navigation | both | P | keep |
| Downloads: queue, Pause/Resume, Cancel (confirm), Dim now | DownloadsView.swift:92, 140-158 | queue | both | P | keep |
| Cloud save conflict: phone / Steam / Decide later | CloudConflictView.swift:103-124; PlayportKit CloudChoice.swift | conflict | both | P | keep |
| Sign in: account name, password, Steam Guard, QR | SignInView.swift:62-90 | Steam sign-in | both | P | keep |
| First-run checklist: Pairing / Pairing file, LocalDevVPN, Steam | SetupView.swift:270-360; PlayportKit SetupChecklist.swift:57-76 | setup | both (preview dev) | P | keep |
| Launch screen / result alerts | LaunchViews.swift:394-433 | text | release-specific text | P | keep (as is) |

### Classification rationale

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

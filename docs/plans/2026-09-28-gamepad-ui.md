# Plan: the gamepad-first UI

**Date:** 2026-09-28, revised 2026-09-30 for decisions 0029, 0030 and 0033.
**Kind:** plan, done on the phone with the driver's presses (step 5,
[evidence 2026-09-30-gamepad-ui](../evidence/2026-09-30-gamepad-ui.md)): the
graphics defaults and the removal of environment variables, Base, the shell
and Home with play time, [decision 0034](../decisions/0034-a-gamepad-first-ui.md),
the one Library grid, the drop of the compatibility labels, the game page
with Game options, Settings, Downloads with the queue kept across the
restart after a game, the launch screen, the Cloud save conflict, the
first-run checklist with its checks before each launch, the in-game menu,
Steam sign-in by account name, and the tooling. What is left needs a person
at the phone (below, and decision 0034's open items). The "Restarting
Playport" screen is gone too (done 2026-09-30): the restart after a game shows black, then Home.
**Design:** [`docs/design/2026-09-28-gamepad-ui/`](../design/2026-09-28-gamepad-ui/),
fifteen landscape screens at the iPhone's 874×402 points (`canvas.json` lays them
out; each `.dc.html` is one screen).

## Goal

Replace the touch-first, portrait app with a landscape UI driven by a controller:
Home, Library and Downloads switched with LB/RB, Settings behind ≡, one focus ring
as the only selection cue, and a footer on every screen naming what each button
does. Touch still works everywhere. The design is the target: where the app cannot
do what a screen shows, this plan lists the work, not a change to the screen.

What the design settles:

- **Defaults, few knobs.** Resolution, frame rate limit and Direct3D are set in
  Settings › Graphics and per game in Game options, where each shows
  "Default · X" until changed. Out of the box every game runs at 720p and
  60 fps on DXMT, both as the global setting and as each game's default.
  Launch arguments are per game. Environment
  variables are dropped as a feature (done, #41). Memory ordering and the Steam API choice
  leave the player's app (dev builds keep them).
- **One library.** Steam games and `C:\Games` in one grid with filter chips
  (Installed, All Steam games, Recently played). Every owned game is listed.
- **No compatibility labels.** "Plays well", "Tested" and "Untested" are dropped
  as a feature: no rating, filter or badge on a game, and no "(tested)" mark on
  a version or a setting, and no player-facing text says a game was tested.
- **One download queue** for installs, updates and repairs, reorderable, with
  updates queued by themselves and a dimmed Download mode.
- **No after-game screen.** A game that ends, quit from the in-game menu or on
  its own, returns to Home. Decision 0029 already does this: the app restarts
  itself after every game and the new process opens on the library, which
  becomes Home. Done: the restart shows no screen of its own either (no
  "Restarting Playport"); the app is black until the new process shows Home.
- **An in-game Playport menu** on a long press of the controller's Home button.

Steam sign-in by account name takes the password too (settled below, Hard
problem 3).

## Hard problems

These need a spike each before the screens that depend on them.

1. **Downloads across the restart after a game.** Decision 0029 ends the
   process after every game and starts a new one, so Steam no longer has to
   come back in the process that ran the guest, and 0004 stands. The new
   process signs in from the stored refresh token, and `syncPlayedStats`
   runs at that sign-in: the stats and cloud saves of every played game go
   up seconds after the game ends. What is left is the queue:
   `SteamInstalls` keeps it in memory, so `suspendForLaunch` pauses every job
   with `InstallCopy.afterLaunch` and the restart then loses the jobs. Their
   stages stay on disk (`hasStageOnDisk`), but nothing resumes them.
   - Done: the queue (order, kind, branch, paused by the player or not) is
     PlayportKit `DownloadQueue`, written to
     `Library/Application Support/Playport/downloads.json` after every change.
     A launch holds every job; the new process lets go of every hold but the
     player's Pause and runs the queue once Steam is signed in.
   - Done: `InstallCopy.afterLaunch` shows only when the restart failed
     (0029, LocalDevVPN down): that process keeps the jobs held.
   - Done on the phone (2026-09-30): three downloads queued, Hollow Knight
     played (first frame at +9.89 s) and quit from its menu, and the first
     download went on from its kept stage in the new process.
2. **The in-game menu.** Done (`UI/InGameMenuView.swift`, HostIOKit
   `QuickMenuControl` and `GuestPadGate`, PlayportKit `QuickMenu`;
   [ARCHITECTURE](../ARCHITECTURE.md#the-in-game-menu), evidence
   [2026-09-30-in-game-menu](../evidence/2026-09-30-in-game-menu.md)):
   - Done: Home held half a second (`buttonHome`, its system gesture off while
     a game runs) opens it over `GameSurface`; while it is up the pads'
     presses are the menu's and the guest's slots rest, and a button still
     down from the menu stays up for the game after it.
   - Done: the game is paused behind it: input and audio stop, and the
     session root suspends every thread of the game's processes
     (`SuspendThread`, which the wineserver holds only at a safe point, so no
     thread is stopped inside host code) until Resume. The retries of a hold
     deferred for long back off (`patches/madeira-unix` 0048).
   - Done: Screenshot (the last presented drawable to Photos), the
     performance overlay switched live, the controller and its battery.
   - Done: Quit game: the host asks the session root (`app/SessionRoot`,
     through `wine_host_session_control`) to post WM_CLOSE to the game's
     windows; it ends the game's job 10 s later if it still runs, and
     Playport restarts anyway 25 s after the request. The request needed no
     change to Wine: the session root already runs in the game's session
     and holds its job.
   - Done on the phone (2026-09-30): Hollow Knight paused, resumed, saved a
     screenshot and quit back to Home, driven by `menu:` actions.
   - Left: a real controller's Home button, the Photos permission prompt and
     a game that ignores WM_CLOSE were not seen on the phone.
3. **Steam sign-in on this phone.** Done (`UI/SignInView.swift`,
   SteamClientKit `loginWithCredentials`, `Crypto/RSA.swift` and
   `CredentialSignInModel`; [ARCHITECTURE](../ARCHITECTURE.md#native-steam-client)):
   - Done: the password. Steam's credential login cannot go without it, so
     the card asks for the account name, then the password, both on the
     controller keyboard. The password's keyboard draws dots and keeps its
     text out of the driver's log (so does the name's); the text goes
     straight into the sign-in, which encrypts it with the account's RSA key
     (`GetPasswordRSAPublicKey`, PKCS#1 v1.5) for
     `BeginAuthSessionViaCredentials` and drops it. It is never stored,
     shown or logged; the refresh token is stored exactly as the QR pairing
     stores it (decision 0004). The design's "Playport never sees your
     password" became "Playport keeps no password", and the card's steps
     name the password step.
   - Done: then an approval in the Steam Mobile app (`PollAuthSessionStatus`)
     or a Steam Guard code from the app or an e-mail, typed with A
     (`UpdateAuthSessionWithSteamGuardCode`); a refused code can be typed
     again. Leaving for the Steam app to approve does not cancel it: the
     poll reconnects and picks the same session up. A wrong password,
     throttling, a denial and an expiry each have their line and "Try
     again" or "Start again".
   - Done: the QR card, the same pairing as before, sits at the right; RB
     rings it and shows a code. The screen opens from Settings › Steam
     account and the checklist's Steam step; Settings no longer holds the
     QR rows itself.
   - Done: the messages, the RSA step (against OpenSSL), the code inbox,
     the service's `.credentials` sign-in over a scripted backend and every
     card state are tested on Linux. On the phone (2026-09-30) the screen
     was seen as a preview (`open:signin` while Steam is signed in): the
     name typed, the password as dots, the approval and a refused code.
   - Left: a live credential sign-in against Steam (it needs the paired
     session signed out), and the QR card showing a code on this screen.

## Work by area

### Base

Done: the router, the focus ring, the footer, landscape, the decision record
(0034), and the components in `UI/Pad/`: the list row (`PadRow`: title, grey line, value, chevron or
switch, the changed-for-this-game dot), the value picker changed with left
and right (`PadValueRow`), the list picker panel (`PadModal.picker`, as in
`GameOptionsPicker`), and the controller keyboard (`PadModal.keyboard`). The
key layout, the keyboard's cursor and text, and the pickers' stepping are
PlayportKit `PadKeyboard` and `PickerIndex`, tested on Linux. The Library's
search (Y) types on the controller keyboard, and its sort is a list picker.
The keyboard's buttons: the D-pad moves between keys, A types, B deletes
(closes on an empty text), X is space, Y Shift, LB and RB move the caret, ≡
is Done. Downloads confirms a Cancel in a list picker; its rows are the design's own.

### App shell and Home

Done (`UI/AppShell.swift`, `UI/HomeView.swift`, `UI/PlayClock.swift`,
PlayportKit `PlayTime`):

- Home, Library and Downloads on LB/RB in place of the `TabView`, a Downloads
  badge (the queue's length), the controller's battery, and Settings on the gear
  or ≡. The footer names A Play, X Options (on a game's card or tile),
  Y Search (the Library on All Steam games with the controller keyboard up) and
  ≡ Settings.
- Home: Continue playing (the game played last, "Played 2 hr. ago · 14 h
  total"), the current download with its percentage and time left, Up next
  with its size and "starts after …" (an update or repair named so), and the
  Installed row, five tiles across, with games still downloading into
  `C:\Games` dimmed after the installed ones.
- Play time: `InstalledTitle.playSeconds` beside `lastPlayed` in the
  catalogue, the sum of the sessions. A session is written to
  `session.json` at Play and beaten every 5 s while the game runs (a gap
  of more than 15 s, the app suspended, counts 15 s). The game's end adds it
  before the restart after the game (decision 0029); a session a process
  left (a crash, `pp ui` ending the app) is added by the next process up to
  its last beat. A launch refused before the runtime counts nothing. The
  game page shows it as Play time.

### Library

Done: one grid (`UI/LibraryView.swift`, PlayportKit `LibraryList`), chips on X,
a sort, search on Y; per tile ready and last played, update, download progress,
size. The lazy grid reports its off-screen tiles' frames to the ring and
scrolls to them. Search (Y) types on the controller keyboard and filters as
the player types; the sort is a list picker.

### Game page and Game options

Done (`UI/GameDetailView.swift`):

- Game page: the hero art, the developer and controller support (Steam's
  `controller_support`, read into `SteamAppInfo`), Play or Install with the
  size and free space, the achievements count, Options (X), Update; a
  running update or repair in Play's place with Pause and Cancel; a card with
  last played, cloud status and size on the phone (download size, version and
  achievements for a game not installed). Every control is on the ring.
- Game options, a panel over the page that scrolls:
  - Graphics: resolution, frame rate limit, Direct3D, each "Default · X" until
    changed and marked when changed for the game (PlayportKit `OptionValue`;
    `LaunchSettings.resolve` inherits game, then global, then 720p, 60 fps and
    DXMT), in list pickers; launch arguments on the controller keyboard; Y
    puts the ringed value back to its default (`PadFocus.resetFocused`).
  - Game: version (the branch picker; another version downloads over the
    installed one), cloud saves (a switch, and each conflict as a picker),
    check game files (and Repair from Steam), achievements (a list over the
    panel, from the stats SteamClient already syncs), report a problem (a
    share sheet with the app's log and drive C's logs), uninstall (confirmed in a picker).
- Memory ordering, block size and the Steam API choice are a dev build's
  Developer section; the release app's launch ignores what a dev build stored
  and runs the game's profile and the emulator.

Done: a game's cloud conflicts are one row, "Choose which save to keep",
which opens the Cloud save conflict screen (below).

### Dropping Plays well, Tested and Untested

Done. What went:

- `SteamApp.swift`: `Compatibility` goes with all its states (`.verified`,
  `.untested`, `.wontRun` and its reasons), their labels and the hardcoded
  cohort `[367520]`. Games that cannot run are no longer hidden or marked in the
  Library; a game with no usable Windows executable says so when its install or
  Play fails, from the installer's own errors.
- `SteamGamesView.swift`: the compatibility badge, its colours and "Show games
  that won't run" go (the view itself is merged into the Library).
- `Catalog.swift`: `InstalledTitle.badge` loses `.untested`, so a title found in
  `C:\Games` reads Ready like one installed from Steam; Needs repair and No
  executable stay. `LibraryView.swift` loses its colour for it.
- `GameDetailView.swift`: the " (tested)" suffix on the version picker
  (`testedBranch`) and on the resolution picker (`recommended`) goes.
- `titles.json` (`CohortTitle`) stays as data the player never sees: its memory
  figures and checksums keep their current uses, and its screen no longer sets
  a game's resolution (see Graphics defaults). Decision 0005 (the
  test cohort) is unchanged; only its labels leave the UI.
- The UI decision record states the drop.

### Graphics defaults: 720p at 60 fps

Mostly done (247e72b): `LaunchSettings.defaultScreen` (`"720"`) and
`defaultFrameLimit` (60) are the last fallbacks, a value the player set still
wins, a stored `nil` means the default, and `PlayportKitTests` cover it. Phone
runs since then play at 720p and 60 fps unless `--settings` says otherwise; an
evidence record that compares with an earlier run says which settings each
side used. Left:

- Done: `recommendedScreen` (a cohort title's screen) left `resolve` and its
  callers; a cohort entry's `screen` is data the launch no longer reads.
- Done: "Default · 720p", "Default · 60 fps" and "Default · DXMT" until
  changed, in Game options and in Settings › Graphics. The pickers keep their presets
  (`screenPresets`, Off and the rates up to the panel's maximum).

### Settings

Done (`UI/SettingsView.swift`, PlayportKit `SettingsSection`, `SettingSteps`,
`DownloadPreferences`):

- Sections down the left: Steam account, Graphics, Downloads, Controllers,
  Storage, Setup check, About, and a dev build's Developer. Up and down move
  the ring along the list and show each section; right goes into it; left
  and B come back to the list; B there closes Settings. Every row is on the
  ring.
- Graphics: the global resolution (default 720p), frame rate limit (default
  60 fps) and Direct3D (default DXMT), changed with left and right, each
  "Default · X" at its default (which stores nil), lower values to the left;
  and the Metal HUD.
- Downloads: update games by themselves (`downloads.autoUpdate`, on), download
  over cellular (`downloads.cellular`, off: Wi-Fi only; `NetworkPath`, an
  `NWPathMonitor`, names the network now), dim the screen while downloading
  (`downloads.dim`, on), sync saves with Steam Cloud (`steamCloud`). The
  switches only store the choice: the Downloads work reads them
  (`DownloadPreferences.current`, `NetworkPath.mayDownload`).
- Controllers: every controller connected, with its battery (`PadRouter.controllers`).
- Storage: free space, the games' total, each game's size; A opens its page.
- Setup check: the controller, JIT and its pairing (Pair again; the file
  import is touch), LocalDevVPN (A turns it on), the memory limit and JIT memory.
- About: version, build variant, the wine_host ABI, the licence.
- Developer (dev builds): diagnostics, the memory simulations, the on-device
  pairing experiment, the probes, the logs (each shared by A).
- The driver: `open:settings#SECTION` (the old `diagnostics`, `pairing`,
  `account` still work), and `pad:` log lines name the section and, in
  Graphics, the global settings.

Left: Settings › About's version is the bundle's (`1.0.0 (1)`), not the
build's commit.

### Downloads

Done (`UI/DownloadsView.swift`, `UI/SteamInstalls.swift`, PlayportKit
`DownloadQueue`, `DownloadRate`, `DownloadMode`):

- `SteamInstalls` runs PlayportKit's `DownloadQueue`: installs, updates and
  repairs in order. Y ("Download next") moves a waiting job to the front,
  behind the one running, and lets go of its Pause. An update is queued by
  itself when a Steam install's build is older than Steam's for its branch
  and Settings › Downloads says so, once per build: a cancelled one waits for
  the next build. A job waits while the network is one Settings does not
  allow (`NetworkPath.mayDownload`), and a running one stops and waits its
  turn again. "Done today" keeps what finished today.
- The page: the storage bar in the top bar, the first job with its time left
  and speed (over the last ten seconds), Up next, While you wait with Dim
  now, and Done today. Every job is on the ring: A pauses or resumes, Y
  Download next, X Cancel, confirmed in a picker.
- Download mode: after a minute without input while a download runs (and
  the dim switch is on), or on Dim now, a black page with the progress and
  the queue's time, the screen's brightness lowered and put back, woken by
  any button or tap.
- Paused while a game runs, resumed by the process after the restart (Hard
  problem 1).
- The driver: `queue:APP` queues a download and goes on, `downloading:APP`
  waits until the queue runs it.
- A job's size is the depots an install takes (the default language, no
  low-violence variant): RC Cars read 1.15 GB for a 0.99 GB install. A
  game whose update or repair waits in the queue does not play until it
  finishes or is cancelled, and its page says so.

Left: the automatic update and the cellular wait were not seen on the phone
(no Steam install had an update, and the phone was on Wi-Fi). Resume puts a
paused job behind the one that started in its place.

### Launch

Done (`UI/LaunchViews.swift`, PlayportKit `LaunchProgress`):

- The launch screen: the game's hero art dimmed (from the art cache on disk,
  so a Play right after the app starts has it), its name, one progress bar
  that moves with the steps and eases within each over its usual time, three
  dots for JIT, runtime and game, and the step in a word. It covers the
  title's surface until the first frame, as the sheet before it did; the
  driver's `title:`/`jit:` marks and the first-frame detection are unchanged.
- The steps are listed only when JIT waits longer than 10 s (with "Gives up
  in N s" and the fix: LocalDevVPN when its tunnel is down) or when a step
  failed. A launch that failed at JIT, the runtime or the game's start
  (`LaunchProgress.failedStage` of its result) shows the steps with the
  failed one marked, what happened and the fix, over the page it was started
  from or, after the restart that follows a spent launch, over Home:
  A Try again, Y Turn on LocalDevVPN (JIT with the tunnel down), B Back. A
  refusal before JIT (memory, a missing executable or backend), a crash and
  running out of JIT memory keep their alert.
- The tip: "hold ⌂ on your controller for the Playport menu", the in-game
  menu of Hard problem 2.

Left: the slow-JIT and failed-step states were not seen on the phone (they
need LocalDevVPN turned off at the phone); `LaunchProgress` is tested on
Linux.

### Cloud save conflict

Done (`UI/CloudConflictView.swift`, PlayportKit `CloudChoice`,
SteamClientKit `Cloud.Backups`, `SteamService.resolveAll`):

- Play asks first (`LibraryModel.play`): a game with open conflicts shows
  "Which X save do you want?", the phone's and Steam Cloud's side each with
  its newest time (and the phone's play time, or Steam's file count and
  size). A keeps the phone's, X Steam's: one `syncCloud(resolve:)` call with
  the same choice for every conflicting file, then the game starts. B,
  "Decide later", closes it and the game does not start. A game not synced
  yet in this process is synced before the check. Game options' row opens
  the same screen without a Play.
- The side not kept is backed up in `Documents/Cloud Backups/<appid>/<time>/`,
  and each process start (once per game played, decision 0029) removes
  backups older than 30 days (`Cloud.Backups.prune`), tested on Linux.
- A dev build's Game options › Developer has "Forget the cloud sync": the
  next sync is a first one, where a save that differs from Steam's is a
  conflict. That is how the screen was reached on the phone (2026-09-30):
  Hollow Knight's cloud saves off, a play that saved at a bench, forget, the
  cloud back on, then Play.

### First run

Done (`UI/SetupView.swift`, PlayportKit `SetupChecklist`):

- The checklist (Setup.dc.html): "Let's get you playing", four cards in a
  row: controller, pairing (on iOS 27 made on the phone through JitSetup,
  decision 0033; on iOS 26 the import from Files, by touch, with Y "How to
  make the file"), LocalDevVPN (`LocalDevVPN.tunnelUp`, read every 2 s; A
  turns it on as before), Steam (optional; A opens Settings › Steam
  account). A done step has a green tick; the ringed step shows its action
  button. Left and right or LB and RB move along the steps, A does the
  ringed one, B leaves ("Done" once pairing and LocalDevVPN are there,
  "Later" before).
- It opens by itself on a first run: no pairing, and the checklist never
  left (`setup.left`). It replaces the cold-launch setup sheet on iOS 27:
  its pairing step starts that setup. Afterwards Settings › Setup check's
  first row ("Setup checklist", "N of 4 done") opens it, and B goes back
  there; that section also gained a Steam row. A dev build's Setup check has
  "Preview a first run" (and "… on iOS 26"): the checklist as a phone with
  nothing set up shows it, display only.
- Before each launch (`LibraryModel.play`, `SetupState.beforePlay`), the
  same checks, logged as `setup: before play: controller=… pairing=… vpn=…
  steam=…`: a missing pairing on iOS 27 or LocalDevVPN down goes to JitSetup,
  which fixes it and goes on with the Play; a missing pairing file on iOS 26
  opens the checklist on that step with the fix, and the Play does not start.
  No controller and a signed-out Steam never stop a launch: the launch screen
  names them above its tip (the controller's line goes once one connects).
- The driver: `open:setup`, and the `pad:` log names the steps' states.

Left: the first run by itself, the iOS 26 file step and a Play refused for a
missing pairing file were not seen on the phone (they need the pairing
removed, or an iOS 26 phone); the preview shows their screens, and
`SetupChecklist` is tested on Linux.

### Tooling

- Done: the UI driver follows the new structure. `AppNavigation.Page` and
  `AppNavigation.screens` replace the tabs, `SCREENS` in `tools/ui.py`
  (tested) replaces `TABS`, `open:ID#SECTION` and `open:settings#SECTION`
  replace the page's old section ids, and the game page opens over the
  Library (`gamePath`), not through `installedPath`. `pp ui --help` and
  DEVICE.md ("The app's screens") are current. The `pad:` log line names the
  ringed item, the page and what is up over it.
- Done: a driven run removes the `ui-step` markers a run ended by the driver
  left, so `--shot-each-action`'s first shots are of their own action.
- Driver verbs for the new surfaces, still through the UI (decision 0012).
  Done for the in-game menu: after `play:`, `wait:S` and `menu:open|ROW` act
  on the running game (`menu:open` holds Home through HostIO's pad
  handling), and the scripted pad has `HOME`.
- Done: `pp verify --variant release` keeps driver names out of the release
  app (release IPA 35f02d5e, 72 checks).

## Order

1. Base, then the app shell and Home, then Library. Each with a
   `pp ui --action open:… --shot-each-action` run.
2. The three spikes start at once, beside step 1.
3. In parallel: Game page and Game options, Settings, Downloads,
   First run.
4. On top of the spikes: the download queue across the restart, the in-game
   menu, and sign-in (all done).
5. Done (2026-09-30): Hollow Knight to `first-frame+10` through the new
   Play button (Home's card, +9.57 s; the game page's, +8.86 s), and the
   evidence record [2026-09-30-gamepad-ui](../evidence/2026-09-30-gamepad-ui.md).

## Open questions

- **Steam sign-in by account name.** Settled: the card takes the account name
  and then the password on the controller keyboard (Hard problem 3); Steam's
  credential login has no way without it. The password goes only to Steam,
  encrypted, and Playport keeps none of it.

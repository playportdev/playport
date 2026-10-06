# Device reference

The phone's setup, JIT, and what is not obvious about driving it. The test
loop is in [AGENTS.md](../AGENTS.md#test); each command's options are in
`pp <cmd> --help`. The workstation drives the app only through its UI
([decision 0012](decisions/0012-the-ui-is-the-only-entry-point.md)).

## Setup, once

```sh
cp -r tools/systemd/netmuxd.service* ~/.config/systemd/user/ && systemctl --user daemon-reload
systemctl --user enable --now netmuxd      # usbmux over Wi-Fi (skip both when a netmuxd user unit already runs)
./pp setup                                 # records the toolchains and netmuxd's socket in .work/inputs.local
xtool auth login                           # from a terminal: it prompts (xtool auth status checks it)
./pp phone status                          # one phone, the app, what is installed
```

- The repository names no path outside itself. `pp setup` reads the socket
  from the running netmuxd unit's `--socket-path` (`--usbmux-socket PATH`
  gives it), so one netmuxd can serve this and other projects.

- netmuxd waits for a default route before it starts (the drop-in in
  `tools/systemd/`). One that started without a route never lists the phone
  again. When it lists none, `pp` restarts it once, and only when that is safe
  for everyone using it: under the device lock (`pp install` outside a session
  takes it for the restart alone, and skips the restart when another job holds
  it), when the unit serves this checkout's socket, and not within 5 minutes
  of the last restart (recorded in `netmuxd-restart.json` beside the lock).
  Otherwise, or when the restart fails, the command fails and says why (the
  drivers as a `netmuxd-restart-skipped` event).
- `pymobiledevice3` takes the bare socket path in `USBMUXD_SOCKET_ADDRESS`
  (a `unix:` spelling crashes it); `xtool` needs `UNIX:<path>`. `pp` sets it
  from `PLAYPORT_USBMUX_SOCKET` (`pp setup`; the environment variable wins).
- Developer Mode must be on (Settings, Privacy & Security). After a reboot
  someone must unlock the phone before it answers again. A launch on a locked
  phone waits for the passcode, and no query tells a locked phone from an
  unlocked one, so `pp ui` fails a launch that has not returned in 20 s.
- The app is `XTL-<team>.dev.playport.app`; `pp` finds it and
  refuses any other bundle ID. Committed records write the team as `TEAMIDXXXX`.

### Free-team limits

Three sideloaded apps at once, and each profile lasts about seven days: after
that the app stops launching until `pp install` (the container survives).
`pp install` refuses a first install into the last slot unless
`ALLOW_LAST_SLOT=1`, and never evicts anything. If `xtool ds devices` prints
nothing, the phone is not registered on the team and signing fails with a 409;
`xtool install --network <ipa>` (with `USBMUXD_SOCKET_ADDRESS=UNIX:<socket>`)
registers it. An install is a ~650 MB transfer; one that times out after the
upload still finishes on the phone, and `pp install` checks for that.

## JIT activation

Every launch that runs guest code needs a debugger-blessed JIT pool
([ARCHITECTURE.md](ARCHITECTURE.md#jit-activation)). It comes from the app's
own helper extension, which attaches with StikJIT
([decision 0011](decisions/0011-no-workstation-jit.md)). A launch waits up to
180 s for it; the `jit:` lines in the log show each step.

It needs Developer Mode, LocalDevVPN (App Store, takes no slot) with its
tunnel connected, and an RP pairing file. Playport cannot carry the tunnel
itself (a packet tunnel needs the Network Extension entitlement, which a free
team cannot have), so it turns LocalDevVPN on instead: a Play, the restart
after a game or Settings' *LocalDevVPN* row (Setup check) that finds no route to
`10.7.0.1` through a `utun` interface opens `localdevvpn://enable?scheme=playport`,
and LocalDevVPN connects and opens `playport://`, which brings Playport back
(`app/Sources/S1Probe/LocalDevVPN.swift`, `vpn:` lines in the log). The player
opens LocalDevVPN once to allow its VPN configuration. On iOS 27, Play and
the driver's `play:` action both await the root-owned setup flow before the
runtime starts.

A first run opens the checklist (`UI/SetupView.swift`): pairing, LocalDevVPN,
Memory (the Increased Memory Limit entitlement in this copy's signature; A
says how to get a copy signed with it, [DISTRIBUTION.md section
6](DISTRIBUTION.md#6-signing-tools-and-the-memory-limit)) and Steam (optional),
each with what A does. Steps can be visited in any order, but B cannot leave
until pairing and LocalDevVPN are ready and Memory and Steam are each on (signed
in) or put off with **X Not now** (also a tap in the footer). Then **You're all
set** appears over the dimmed steps: **Continue** (tap or A) leaves setup; B
closes only the overlay, and B on the settled steps leaves. An unfinished first
run resumes on the next launch, even after pairing has been stored. Existing
paired phones keep their setup. A controller is not a setup step.

Settings › Setup check's first row opens it afterwards (`pp ui --action
open:setup`); these later visits can always leave with B. A dev build's
*Preview a first run* rows show the same gate and completion overlay with
simulated facts (iOS 27, or iOS 26 with the file import), Memory off. A completes the ringed
step (on Memory it shows the real fix); X on Memory or Steam puts it off. Nothing changes in the phone's pairing, VPN or
Steam session, and the preview ends on leaving. The same checks run before every Play (`setup:
before play …` in the log): a missing pairing on iOS 27 or LocalDevVPN down
starts the setup below and the Play goes on; a missing pairing file on iOS 26
opens the checklist on that step and the Play does not start; no controller or
a signed-out Steam only shows a line on the launch screen.

On iOS 27, the checklist's pairing step (or a Play with no pairing) opens setup. Setup shows a code,
the person pairs in iOS Settings, Privacy & Security, Developer Mode, **Pair
with Playport**, then returns. Playport connects LocalDevVPN, checks readiness,
and saves the record in its this-device-only Keychain item. Settings › Setup
check's **Pair again** repairs a stale record without deleting the old one first. A driven
run can open or resume the product flow with `jit:setup`, `jit:pair`,
`jit:continue`, `jit:cancel` and `jit:wait`; iOS Settings still needs the
person.

For iOS 26 or recovery, an RP pairing file can still be imported in Settings ›
Setup check (*Import pairing file*; choosing the file uses touch):

```sh
# RP pairing file: jkcoxson/idevice's idevice-tools
cargo build --release --manifest-path <idevice>/tools/Cargo.toml --bin idevice-tools
SOCK=$(. .work/inputs.local && echo "$PLAYPORT_USBMUX_SOCKET")   # pp setup
socat TCP-LISTEN:19231,bind=127.0.0.1,fork,reuseaddr UNIX:$SOCK &
(umask 077; USBMUXD_SOCKET_ADDRESS=127.0.0.1:19231 <idevice>/target/release/idevice-tools \
    rppairing pair playport-workstation $PLAYPORT_BUILD/stikdebug/rp_pairing_file.plist)
```

- The pairing file is a secret: keep it under `$PLAYPORT_BUILD` and get it to
  the phone as a player would (AirDrop or Files). Playport keeps it in its
  Keychain, so an update or reinstall under the same team finds it again.
- StikJIT mounts the Developer Disk Image once per boot. **Reset Developer
  Disk Image** in Settings › Setup check clears its cache if mounting keeps failing. If
  readiness says unreachable, press the *LocalDevVPN* row there.
- A launch whose JIT step logs `Timed out connecting to 10.7.0.1` has
  LocalDevVPN's tunnel down. Only the person at the phone can bring it up:
  ask them, do not retry (every retry fails the same way).
- After every game that used the runtime, Playport restarts itself over
  LocalDevVPN and comes back on Home in a new process (black in between, no
  restart screen; the iOS Home Screen may flash for a frame), so every Play
  takes the JIT in a fresh process ([decision 0029](decisions/0029-restart-after-each-game.md)).
  A driven run plays several with `--action play:ID --play ID`: the actions
  after a play run in the restarted process, under the same run. A game that
  never ends its process (The Witcher 3's Exit, 2026-09-29) leaves the app on
  the game's black surface: nothing restarts it; end the app.
- **Keep the app in front** while the pool is blessed and the title loads: in
  the background the watchdog kills it (`0x8BADF00D`). **Connect a controller
  before launching**: a Unity title does not see one that connects later.

### Known-good iOS versions

JIT depends on iOS, StikJIT and LocalDevVPN, and no code of ours controls any
of them. **Keep the reference phone on a version in this table.** Do not install
an iOS update, even a point release, until a phone on it has passed a Hollow Knight
play (`pp ui --play app-367520 --until first-frame+10`) and the table has a row
for it. Before updating, read StikDebug's recent releases and issues for the new
version (`gh-axi issue list -R StikDebug/StikDebug`).

| iOS (build) | Phone | StikJIT | Last checked | Evidence |
| --- | --- | --- | --- | --- |
| 27.0 (24A437) | iPhone18,4 (A19 Pro, TXM present) | 1.6.0; 1.9.0 (the pin from 2026-10-05) in a trial IPA | 2026-09-28 | [stikjit-pin-cost](evidence/2026-09-28-stikjit-pin-cost.md): JIT in 3.19 s, first frame at +8.92 s |

- Not known good: iOS 27.2 (StikDebug issue #471, open: the tunnel fails with
  `missing field public_key`), and every iOS 26 version. The app installs from
  iOS 26.0 (its deployment target since 0.3.2); below 26.4 StikJIT 1.9.0 mounts
  the personalized DDI (1.6.0 could not), but no phone on iOS 26 has run it. On
  iOS 26 there is no on-device pairing: the player imports a pairing file.
- A new phone model also needs its DDI published in the repository StikJIT
  downloads it from at run time (`doronz88/DeveloperDiskImage`).

### Moving the stikjit pin

The `stikjit` pin is a StikJIT release tag (StikDebug/StikJIT, the framework).
The StikDebug app is not a candidate: it is AGPL-3.0 and has its own copy of the
JIT code. The StikJIT release that goes with a StikDebug 3.x release usually
comes out within a day of it. What a move from 1.6.0 to 1.9.0 costs was measured in
[stikjit-pin-cost](evidence/2026-09-28-stikjit-pin-cost.md).

1. **Read what changed**, in a StikJIT clone under `.work/`:
   `git diff --stat OLD NEW`, then in full:
   - `Sources/ScriptRunner.swift` and `Sources/JITSession.swift`: the script's
     host functions (`get_pid`, `send_command`, `prepare_memory_region`, `log`),
     no-ack mode, the TXM gate, and the bless packets
     (`$M<9 hex digits>,1:69`, so the pool must stay below 2^36). If any of these
     changed, `app/PlayportJIT/playport-universal.js` and
     `app/Sources/WineHost/wine_host.c` (`jit26_prepare_region`) must follow.
   - `Sources/StikJIT.swift`: the public API that
     `app/Sources/PlayportJIT/JITHelper.swift` calls.
   - `Sources/ProcessInfo+TXM.swift`: where TXM reads absent, StikJIT skips
     the script, and Playport's first `brk #0xf00d` then kills the app.
   - `idevice/`: `git ls-tree OLD idevice` against `NEW`. If the tree changed,
     move the `idevice` pin to an idevice commit of the new library's date (the
     binary does not record its revision), and update `IDEVICE_LICENSE_SHA256` in `build/stages/stikjit.sh` if its
     `LICENSE.txt` changed.
   - `Resources/`: the bundled scripts are removed at staging; check that the
     names are still `universal.js` and `legacy.js`.
2. **Change the pin**: the tag in `pins.lock`; `SHA256` (the release zip) and
   `COMMIT` (the tag's commit) in `build/stages/stikjit.sh`; the tag and commit
   in `docs/LICENSING.md` and `docs/NOTICES.md`.
3. **Build**: `./pp build`. The stage checks the zip, the tag's commit, the
   idevice licence and the swiftinterface rewrite; `verify` checks the embedded
   framework. A release built with Xcode 27 or later (StikJIT 1.7.0 on) writes
   its interface with module selectors (`StikJIT::StikJIT.StikJIT::`). The
   interface then needs no rewrite, but the check after the rewrite matches
   inside those names and must skip a match after `::` (the evidence has the
   line).
4. **Play on the phone**: `pp install`, then Hollow Knight to
   `first-frame+10`. The `jit:` lines must show `ready, TXM present`,
   `Running playport-universal.js`, `Blessed N JIT page(s)` and `detached after
   1 prepare(s)`. When the move changes DDI mounting, also run a launch after a
   reboot, when the DDI is not yet mounted (a person unlocks the phone).
5. **Record it**: an evidence record with the IPA's sha256, and a new row or
   date in the table above.

## Driving a title

- **The app's screens** ([decision 0034](decisions/0034-a-gamepad-first-ui.md)).
  `open:SCREEN` shows Home, Library (`library`: on All, `games`: on Steam), Downloads,
  Settings (`settings#SECTION`), the checklist (`setup`), Sign in to Steam
  (`signin`) or a game's page (`open:ID`, `open:ID#SECTION` with its Game
  options open); `pad:` presses then move the one focus ring and press the
  footer's buttons, as a controller does (`pp ui --help` has the buttons).
  Each `pad:` line in `s1-host.log` names the ringed item (`focus hero:app-367520`,
  `dl:job:APP`, `set:nav:graphics`, `opt:frameLimit`), the page and any panel,
  picker or keyboard up: read it beside each `--shot-each-action` screenshot
  before the next press, since a direction goes to the nearest item that way
  (on Downloads with one job, down from it rings *Dim now*, and A there
  dims the screen). A cancel that removes a job moves the ring: press
  `pad:x` and `pad:down+a` as separate actions for each job.
  Walk a changed screen this way and look at the shots; the evidence for the
  UI as a whole is [2026-09-30-gamepad-ui](evidence/2026-09-30-gamepad-ui.md).
- **Launch settings** (`pp ui --settings ID:JSON`, PlayportKit
  `LaunchSettings`) are what a game's Game options save: `screen` (`native`, `720`,
  `4:3`, `WxH`), `frameLimit` (0 for none), `maxInst` (FEX's block size),
  `graphics`, `arguments` (added to the game's
  command line, as `{"arguments":"-DX12"}`), `ordering` (FEX's
  memory ordering over the game's profile: any of `tso`, `vector`,
  `memcpySet` and `halfBarrier`, true or false, as in
  `{"ordering":{"vector":true}}`; [decision 0021](decisions/0021-fex-ordering-per-game.md)),
  and for a Steam game `steamAPI`
  (`emulated`, the default, or `original`) and `cloudSync`. Only a dev build
  offers ordering, block size and `steamAPI` in its options, and only a dev
  build's launch reads them. `pp ui --action open:app-367520#graphics` opens a
  game's page with its options at a section (`graphics`, `game`, `files`,
  `developer`, `ordering`, `steam`); `pad:` presses then move through them, and
  `pad:y` puts the ringed setting back to its default. They last for the
  driver's session and are undone after it, like `set:` and `hud:` (see
  [Sharing the phone](#sharing-the-phone)); `--keep-settings` keeps them as a
  player's would, and `ID:{}` clears them. A play with none set runs at
  720 rows and 60 FPS, the default. A measurement at native resolution or
  free-running must say so: `{"screen":"native","frameLimit":0}`. A game's options have no environment
  variables, so the runtime's environment switches (`WINE_HOST_LOG_STAMP`,
  `WINE_HOST_SAMPLE`, `WINE_HOST_DIAG` in `wine_host.c`) have no way in. A
  cohort title's madeira.cfg keys come from its `titles.json` entry
  ([ARCHITECTURE.md](ARCHITECTURE.md#madeiracfg-switches)).
- **The scripted pad.** A launch with `--pad` plays `Documents/vpad.txt` as a
  game controller; `pp pad` replaces the script while the title runs. A script
  is one step per line, `<ms> [control ...]` with XInput names (`A`, `LB`,
  `START`, `UP`, `LT=0.5`, `LX=-1`), `-` for rest, and an optional final
  `loop` (`app/HostIOKit/Sources/HostIOKit/VirtualPad.swift`). The app plays
  only a script written after it started. `tools/pad/` has Hollow Knight's
  `hk-new-game` (main menu to King's Pass), `hk-walk` and `hk-quit` (Quit
  Game from the main menu; its "Quit Game?" opens on No, so UP to Yes), Portal 2's
  `p2-new-game`, `p2-cold-boot` (to a test chamber), `p2-walk`, `p2-save-load` (save, then load it from the main menu), `p2-load-last` (the pause menu's LOAD LAST SAVE, the load a death makes) and `p2-quit`, Witcher 3's
  opening, and `multiversus-training` (a minute of play; its comment has the
  steps into Training). Time pushes from the first frame (`first-frame+25`): the JIT and
  runtime start before it vary. Within a title, `pp pad wait-still --shot
  FILE` waits for the screen to settle (a menu after a load) instead of a
  fixed wait, and leaves the settled screen in FILE.
- **The in-game menu.** Holding the controller's Home button half a second over
  a running game opens Playport's menu (`UI/InGameMenuView.swift`): the game is
  paused behind it (its pads at rest, audio stopped, its threads suspended by
  the session root) until Resume, B or Home. The driver reaches it through
  the same pad handling: after `play:`, `wait:S` and `menu:` actions run while
  the game runs; `menu:open` waits for the first frame and holds Home,
  `menu:resume`, `menu:screenshot`, `menu:overlay` and `menu:quit` move the
  ring and press A, and `pad:` presses go to the menu while it is up. The
  scripted pad has `HOME` as well (`pp pad send "800 HOME" "100 -"`). Screenshot
  saves to Photos, which iOS lets happen only after a person allows it once;
  a dev build also keeps the PNG in `Documents/Screenshots/`. `menu:quit` posts
  WM_CLOSE to the game's windows, the session root ends a game still running
  10 s later, and the run follows the restart to Home:
  `pp ui --action play:app-367520 --action wait:10 --action menu:open --action menu:resume
  --action wait:5 --action menu:open --action menu:quit --action open:home --shot-each-action`.
- **The memory limit.** Settings › Setup check shows the app's limit
  ([DISTRIBUTION.md, section 6](DISTRIBUTION.md#6-signing-tools-and-the-memory-limit)).
  Settings › Developer's *Simulated limit* (`set:memoryLimitSimulatedMB=2048`, undone like
  any `set:`) is what every Play is then checked against: a Hollow Knight play
  ends refused with `launch=refused memory=2048 need=3200`, and no JIT is spent.
  Each play logs a `title: memory:` line.
- **The JIT pool.** A play gets a pool sized from that limit (Setup check's
  *JIT memory*; a `title: jit pool:` line) and logs its use as `title: pool:`
  lines; `pp ui` and `pp perf` put the last one in the `result` event as
  `pool` (`head_mb`, `tail_mb`, `alias`, `children`, `exhausted`, …): the
  high-water marks for [evidence](evidence/2026-09-28-jit-pool.md). Developer's
  *Simulated JIT memory* (`set:jitPoolSimulatedMB=128`) sets the pool
  instead: Hollow Knight then ends with `pool=exhausted:head …` and the alert
  *Hollow Knight ran out of JIT memory*, which `pp ui` does not count
  as ok ([ARCHITECTURE.md](ARCHITECTURE.md#jit-pool-use)). At 184 MiB it fails
  to load at once (`exit=0xc0000135`); at 240 MiB it reaches its first frame,
  runs on after the pool ran out, and the launch ends without it
  (`pool=exhausted:head still-running after_s=…`). Playport then restarts,
  which ends the game, and shows why in an alert over the library: `pp ui --action set:jitPoolSimulatedMB=240 --action play:app-367520
  --action open:settings --shot-each-action` shows it.
- **The runtime's known limits.** A play logs `title: limits:` lines, and
  `pp ui` and `pp perf` put the last one in the `result` event as `limits`
  (`wx_dropped`, `x18_images`, `x18_sites`, `split_lock`). No measured title
  reaches any of them, so a count above 0 names a title that does
  ([ARCHITECTURE.md](ARCHITECTURE.md#known-runtime-limits)).
- **The FEX host band.** A play logs `title: band:` lines, and `pp ui` and
  `pp perf` put the last one in the `result` event as `band` (`used_mb`,
  `largest_free_mb`, `span_slots`, `threads`, `refused`, …). `refused` above
  0 is a thread or allocation the band had no room for
  ([ARCHITECTURE.md](ARCHITECTURE.md#the-fex-host-band)).
- **Steam.** Settings' Steam account (or the checklist's Steam step) opens *Sign in to
  Steam*: the account name and password on the controller keyboard, then an approval in
  the Steam Mobile app or a Steam Guard code; or RB, a QR code scanned with the Steam app
  on **another** device (switching to Steam on this phone cancels the QR code, not the
  account-name sign-in). While Steam is signed in, `pp ui --action open:signin` (and a dev
  build's *Preview sign-in* row) shows the same screen as a preview that sends nothing to
  Steam; the account name, password and code keyboards are not logged. Do not sign the
  paired session out to test the real one.
  `pp ui --action install:APP` presses a game page's buttons and pulls
  `steam-drive.log` after; `queue:APP` queues a download and goes on, and
  `downloading:APP` waits until the queue runs it. The queue is kept in the
  container (`Library/Application Support/Playport/downloads.json`) and runs
  again at the app's next start, a driven run's too: cancel test downloads
  (Downloads, X) or let them finish, and uninstall what they installed.

## Sharing the phone

Every job on the machine, a person's, an agent's or a `pp sync` candidate's,
shares the one phone ([decision 0016](decisions/0016-agents-share-the-phone.md)):

- **One lock.** The device lock, its holder record and the install record
  (`device-state.json`) live in `.work` (`$PLAYPORT_DEVICE_DIR` moves them).
  `pp phone status` shows who holds the phone and whose IPA it has.
- **Sessions.** One hold of the lock is a session (`PLAYPORT_DEVICE_SESSION`,
  recorded in the holder). Every command holds the lock only while it runs;
  `pp phone lock -- CMD` makes everything CMD runs one session, so no other
  agent's command runs between its steps. A process that says it holds the
  lock (`PLAYPORT_DEVICE_LOCK_HELD=1`) is believed only when its session is the
  live holder's.
- **Whose build.** `pp install` records the IPA, its sha256 and the checkout;
  it removes the record before it installs, so an interrupted install leaves
  none. `pp ui` and `pp perf` refuse to drive an IPA another checkout
  installed, or none on record: `pp install --no-build` installs yours,
  `--expect-ipa FILE|SHA256` insists on one IPA, `--any-build` drives
  whatever is there. A run's `installed` event and `result` line carry the
  sha256; an `installed-stale` event says this checkout has built a newer IPA
  than the phone has.
- **Settings.** `set:`, `hud:` and `--settings` go through the UI as before,
  and the dev app records the value each key had before its session first
  changed it (`app/Sources/S1Probe/Dev/DriverUndo.swift`). The app's first
  launch outside that session, driven or from the Home Screen, puts them back
  and logs `ui: undo session <id>: restored <keys>` (a `settings-restored`
  event). `--keep-settings` makes a run's changes stay. A release install
  over the dev app keeps whatever a session left.
- **netmuxd.** One netmuxd serves every agent, and possibly other projects. A
  restart drops all their connections, so `pp` restarts it only under the lock
  and at most once per 5 minutes. `pp install` takes the lock for the restart
  when it is free; while another job holds it, nothing restarts netmuxd.
- **A running title.** `--leave-running` outside `pp phone lock` warns: the
  next agent's run ends the app, and its `pp pad` would play into your game.

## Measuring a title

`pp perf` plays a title for `--secs` after its first frame and tables, per
5 s, frame rate and time, GPU time, CPU by cluster and clock, the power budget
and thermal pressure, FEX compiles, protection changes and mach exceptions;
`threads.txt` has the busiest threads (`Mi/f`, million instructions per frame,
is the work measure to compare), `server.txt` the wineserver requests per frame
by kind and the threads that spend most time on them, and `hitches.txt` every
frame of 25 ms or more with what was logged around it. `pp perf --help` has the sources.
`pp perf --compare DIR DIR ...` sets finished runs side by side: their
figures, the launch settings that differ, and the frame rate per 30 s.

- **Thermals decide the frame rate**: when a CPMS client reaches its floor
  (660 mW for client 9 on the A19 Pro), the SoC parks the P cores (the `P%`
  column falls to 0) and clocks down. Measure unplugged (charging adds heat),
  but charge between campaigns: Vulkan runs took the phone from 82 % to 8 %
  in about two hours, and near empty it fails runs and drops off. `pp phone
  status` shows the battery.
  - `--cool MIN` waits MIN minutes since the last `pp perf` ended, and then
    until thermalmonitord's last pressure level is 0. Only runs whose
    `summary.json` says `thermal_start: nominal` compare.
  - The `budget` column is the lowest client, each carried forward from its
    last line; `summary.json` has each client's lowest and last value.
  - The `sysmW` column is the whole phone's draw from the battery gauge,
    updated about every 20 s.
  - Evidence: [witcher3-profile](evidence/2026-09-26-witcher3-profile.md),
    [hk-power-budget](evidence/2026-09-26-hk-power-budget.md).
- **Where the CPU and GPU go**: Settings › Developer's diagnostics (dev builds) switch
  the runtime's profilers on for the next launch; `pp perf --cpu-prof` and
  `--pass-prof` turn them on for one run.
  - CPU sampling (`WINE_IOS_PROF=1`): the busiest threads at about 1 kHz,
    3 s in every 15 s; `profile.txt` has the class, thread, leaf function and
    the PE function each sample runs under, symbolised against the staged DLLs,
    and an i386 guest's module+rva by thread (`guest-thread`).
  - GPU time per pass (`DXMT_PASS_PROF=1`, patches/dxmt 0008): every encoder
    of two frames in every 1200 presents; `passes.txt`
    (`tools/passprof.py LOG`) tables the sampled frames and the passes that
    cost most GPU time a frame, alike passes (size, attachments) together.
- **One frame's GPU work**: Settings › Developer's GPU capture (dev builds) has DXMT write
  frame N of the next game as a Metal `.gputrace` into the game's folder. It
  needs a Playport started with it set (Metal allows a capture only then, and
  it costs every frame), so set it in one `pp ui` run and play in the next,
  in one session:
  `./pp phone lock -- sh -c './pp ui --action set:gpuCaptureFrame=600 && ./pp ui --play app-367520 --until first-frame+30'`.
  The log's `A new capture will be saved to` line names the bundle;
  `pp phone pull 'Documents/prefix/drive_c/Games/<game>/<name>.gputrace' DIR`
  fetches it whole (a Hollow Knight frame: 694 MB in 26 s), and
  `tools/gputrace.py BUNDLE` lists its encoders and calls. Nothing on this
  workstation replays it, so it has no timings
  ([evidence](evidence/2026-09-29-metal-tools-without-a-mac.md)); what a
  Mac would add is in [GPU-DEBUGGING.md](GPU-DEBUGGING.md).
- `--no-hud` measures without the Metal HUD's logging cost. `--energy`
  perturbs the title: use it for the CPU-to-GPU ratio only.
- `--settings`, the HUD switch and Diagnostics last for the run's session and
  are undone at the app's next launch outside it (`--keep-settings` keeps them).
  A game's page has no environment variables, so the other measurement
  switches (`MADEIRA_QUIET`, `DXMT_SHADER_CACHE=0`, `WINE_IOS_THREAD_QOS`,
  [Hollow Knight's list](evidence/2026-09-25-hk-thread-qos.md)) have no way
  in; one that is needed again goes into Diagnostics.

## Logs

`pp ui` pulls this run's `s1-host.log` to the run's `pull/` (`pp perf`: to
`run/pull/`); `pp phone log` pulls it by hand. A run directory's `events.jsonl`
has every event; its last `"event": "result"` line is the outcome (grep for
that, not for `"result"`: the UI steps' events carry a `result` field too).
`argv.txt` records the command, checkout and HEAD that made the run. A play
that could not get JIT because LocalDevVPN is down ends with exit 4 and
`why: "jit-unreachable"`. A play's result also carries `selfcheck`: the
start-up self-check's last verdict (`report`: the pool, the TSD slot, the
host page) and the TEB's TSD slot from ntdll (`teb`); a launch it refused
ends `launch=refused selfcheck=<what>` or `launch=failed selfcheck=<what>`
([ARCHITECTURE.md](ARCHITECTURE.md#start-up-self-check)).

Where things are in the app's container (`pp phone ls DIR` lists a directory):

| Path | What |
| --- | --- |
| `Documents/s1-host.log`, `s1-host.prev.log` | the dev app's runtime log, this launch and the one before |
| `Documents/steam-drive.log`, `run-events.jsonl`, `vpad.txt` | the Steam client's log, the UI driver's events, the pad script |
| `Documents/Screenshots/` | a dev build's copies of the in-game menu's screenshots |
| `Documents/Cloud Backups/<appid>/<time>/` | the copies of saves a Steam Cloud sync replaced (the side not kept in a conflict), kept 30 days |
| `Documents/prefix/` | the Wine prefix; `drive_c/Games/<title>/` holds the installed titles |
| `Documents/prefix/drive_c/users/playport/` | the guest user: saves and Unity logs under `AppData/LocalLow/<company>/<game>/` |
| `Documents/prefix/drive_c/hollow_knight-player.log` | Hollow Knight's player log (its `-logFile` argument in `titles.json`) |


- A release build logs to `Documents/playport.log` (`pp phone pull`): 4 MB a
  session at most, and a log over 2 MB becomes `playport.previous.log` at launch.
- Pull named files only (`pp phone pull` refuses a directory): `Documents`
  holds the prefix, whose `z:` drive links to `/`, so pulling a directory
  recurses through the workstation's root. `pp phone ls` finds the names.
- The unix layer's start-up messages and fatal errors go to os_log only: for a
  run that fails before it writes a log,
  `pp phone lock -- pymobiledevice3 syslog live -pn S1Probe > syslog.txt`.
- Before committing evidence, fixtures or logs, `pp secrets` must be clean (it
  also runs in `pp test`); a new kind of secret goes into its patterns.

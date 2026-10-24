# Playport

An iOS app that runs x86-64 Windows games on a non-jailbroken iPhone. It is
built on [willfaust/Madeira](https://github.com/willfaust/Madeira): Wine
(ARM64EC), FEX-Emu and DXMT as one Mach process. Everything builds, signs and
installs from Linux or natively from macOS with Xcode's SDKs. This file covers how to
work here: build, ship, test. Reference material is in `docs/`, listed at the
end.

## Layout

| Path | What |
| --- | --- |
| `pp` | the one entry point for everything below (`./pp --help`; `pp <cmd> --help` for each command) |
| `pins.lock`, `upstream/madeira` | the upstream commits a build uses; Madeira is a submodule, and `pins.lock` madeira must equal its gitlink |
| `patches/<target>/` | every change to upstream code, as `git format-patch` files in `series` order |
| `build/` | what `pp build`, `pp install` and `pp verify` run: `pipeline`, `install`, `verify-ipa.py`, `stages/`, `toolchain/` |
| `app/` | the iOS app (a Swift package: `Sources/S1Probe` is the app, `HostIOKit`, `PlayportKit`, `SteamClient`) |
| `tools/` | `pp`'s modules: `phonelib.py` (the phone, the lock, events), `checks.py` (what `pp test` and `pp sync` both check), `ui.py`, `perf.py`, `gpu.py` (GPU debugging), `pad.py` with the scripts in `pad/`, `afc.py`, `sync.py`, `slots.py`; `tests/`; the netmuxd unit in `systemd/` |
| `docs/` | reference (below), decisions (`docs/decisions/`), evidence records (`docs/evidence/`) |
| `.work/` | the build area (`$PLAYPORT_BUILD`, gitignored): run trees, caches, IPAs, run state, and the phone's lock and install record |

## Rules

- **Linear tracks everything.** Team PLA is the source of truth for planned work,
  bugs, follow-ups and release handoffs, not just compatibility reports. Every plan
  (including drafts under `.work/plans/`) must be reflected in a Linear issue when
  written, before commit or execution: search first and reuse an issue that covers
  its scope, or create one. Put a `**Linear:**`
  issue link in the plan and its repository path in the issue. Keep progress,
  blockers, evidence and completion in sync; split follow-ups into linked issues
  rather than leaving them only in a document. Remove completed plans after their
  outcomes are recorded in decisions/evidence and `docs/plans/finished.md`, with any
  remaining work tracked in open issues. [Plans](docs/plans/README.md) indexes the
  documents; it is not a second backlog.
- **Commit every completed chunk of work.** After the relevant checks pass, commit
  each coherent chunk before starting the next or reporting completion; do not
  wait for a separate request. Include its documentation and changed build records,
  but never unrelated changes or private data. If a check blocks completion, report
  the blocker rather than committing the chunk as finished.
- **Upstream code is never edited in place.** Change it with a `git format-patch`
  file in `patches/<target>/` and its `series`, with `Class:`, `Evidence:` and
  `Offered-upstream:` trailers ([ARCHITECTURE.md](docs/ARCHITECTURE.md#patch-series)).
  The build checks every tree against its series by content, so an edited patch
  is reapplied on the next build.
- **Name gate.** `pp names` must stay clean (also run by `pp test` and CI). Name no project other than willfaust/Madeira as provenance.
- **Pins.** The Madeira pin is frozen at `8c050d0` and Playport owns that layer
  (decision 0054): `pp sync` only reports Madeira's new commits, and a wanted fix is
  ported by hand as a Playport patch ([UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md)). The `wine`, `dxmt`, `fex` and `rpmalloc` pins
  and their `patches/*-port` series (for Wine also the `madeira-port` patches at the end of
  `patches/madeira-unix`, and `patches/wine-valve` with its `wine-valve` pin, Valve's
  Proton Wine commits picked onto WineHQ) move only by a manual rebase or pick plus a Hollow Knight
  play on the phone (decisions 0007, 0008, 0013, 0018). `pp rebase` does such a rebase in scratch
  ([UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md#moving-a-component-pin)); check every hunk it flags
  against both sides: git misplaced several auto-merged hunks in the FEX rebase. After a DXMT
  rebase, rerun `gen_remote_guard.py` and `gen_api_names.py` in the patched tree
  (`run/dxmt-patched/dxmt/src/winemetal/`), then `pp slots` must be clean: the slot
  numbers are an ABI a merge cannot check.
- **Committed build records.** A build in `.work/run` rewrites
  `app/artifacts.tsv` and `build/generated/wine-pe-*.tsv` when its outputs change. Commit
  them with the change that caused it; any other diff there means a tree was built from
  something else. Wine PE and DXMT hash their build directory, so a build anywhere else
  (another `PLAYPORT_RUN`, a `pp sync` candidate) puts them back and leaves its own beside
  the IPA (`out/…/records/`).
- **Checkout isolation** (decisions [0028](docs/decisions/0028-one-checkout.md),
  [0069](docs/decisions/0069-host-only-worktrees.md)). Builds and device work stay in
  the main checkout, on a branch, one build at a time. An owner-authorized side
  worktree may edit docs/code and run isolated host checks only: no main checkout
  source, index, branch or runtime-state changes; no builds, installs, phone commands,
  browser or games. Keep scratch and test outputs in its own `.work`; do not copy,
  symlink or share main's `.work`, mutable caches or submodules. A command that needs
  those inputs waits for the main session; report unrun build/device gates explicitly.
- **The UI is the only entry point** (decision 0012). A person does everything in the
  app's UI, and the workstation tests it by driving that UI (`pp ui`). Add no launch
  mode, environment switch, terminal client or push-a-file tool that reaches app
  functionality another way; a capability the tooling needs goes into the UI first.
- **Two apps from one tree** (decision 0009). `dev` (the default) is `S1Probe.app`,
  which the UI driver can drive; every driver needs it installed. `release` is
  `Playport.app`: no driver, a quiet runtime, a size-capped `playport.log`. Dev-only
  Swift goes in `app/Sources/S1Probe/Dev/` or under `#if !PLAYPORT_RELEASE`;
  `pp verify --variant release` fails an executable that names a driver variable or file.
- **Swift in the app.** xtool builds it at `-Onone`; a CPU-heavy package must opt into
  `-O` itself (as `app/SteamClient/Package.swift` does). The app build loads no
  Observation macro plugin, so `@Observable` fails there: use `ObservableObject`.
- **Disk.** Everything the project makes stays in the repository: build and scratch
  work go under `.work/` (`$PLAYPORT_BUILD`, gitignored), never `/tmp` (a small
  RAM-backed tmpfs) or elsewhere in `$HOME`. System tools (llvm-mingw, xtool's darwin
  SDK and account, pymobiledevice3, netmuxd) stay installed system-wide, and nothing
  committed or built names a path outside the repository: `./pp setup` records where
  those tools are in `.work/inputs.local`; write `$PLAYPORT_BUILD`, `$LLVM_MINGW` or a
  repo-relative path in docs and evidence (`pp secrets` and `pp verify` fail a home
  path). Gitignore anything that must not be pushed.
- **The phone.** One phone, three free-team app slots, profiles that last seven days.
  Never uninstall the app: that deletes its container (the Wine prefix, the Steam
  session, the installed titles). `pp install` upgrades in place.
- **Secrets.** The RP pairing file, the Steam session, the device UDID and the team ID
  never go into the repository. `pp secrets` (also in `pp test`) must be clean before
  committing evidence or logs.

## Build

In the main checkout, after `./pp setup` records the machine's tools:

```sh
./pp build --plan              # inspect what would run and why
./pp check                     # compile the app unsigned; first builds changed dependencies/notices
./pp build                     # build what changed into a verified dev IPA
```

Use focused host checks first when they can answer the question. Incremental builds
reuse input stamps, but app/verification still run; do not assume a fixed warm-loop
time. A second build using the same run directory exits at once (`flock -n`), not
waits. Variants, clean builds, stages, outputs and logs: `pp build --help` and
[BUILDING.md](docs/BUILDING.md).

## Ship

`./pp install` checks the account, phone and profile, builds what changed, then
upgrades in place; `--no-build` uses the newest verified IPA. Options and records:
`pp install --help` and [DEVICE.md](docs/DEVICE.md). An IPA for a tester is a
distribution: follow [DISTRIBUTION.md](docs/DISTRIBUTION.md).
`pp release VERSION` requires a clean, pushed HEAD, reuses its unsigned release IPA
(or builds it), and makes a GitHub draft; it never publishes (decisions 0038, 0050).
Commit changed build records and push before the release build/handoff. The release
app gets no automated phone tests: the owner installs it, plays and signs off
(decision 0068).

## Test

**Host.** `./pp test` runs the name gate, the secret scan, the pin and patch-series
checks (series entries, trailers), `tools/tests`, the app's host C tests (`app/tests`)
and the Swift package tests. `--quick` leaves out Swift; CI runs it.

**The phone.** Every device command takes the device lock itself. When another job
holds it, the command prints who holds it and waits in the kernel, so there is nothing
to check first. Long commands print JSON events, one per line, ending with a
`"event": "result"` line (grep for that: UI step events carry a `result` field too).

**Waiting.** Use a timeout that covers the whole operation (at least 600 seconds
for build/install/play). Follow the current harness's foreground/background and
completion-notification contract; confirm the producer's exit status, not a trailing
`echo` or `tail` status. Do not poll with `pgrep -f`, wait with `tail -f | grep -m1`,
or kill with `pkill -f`: these can match themselves or outlive/kill unrelated jobs.

**Sharing the phone** (decision 0016). One lock and one install record, in `.work`,
for every job on the machine. `pp ui` and `pp perf` refuse an IPA another checkout installed
(`--any-build` drives it anyway, `--expect-ipa` names the one you want). What a run
changes with `set:`, `hud:` or `--settings` lasts for its session (one hold of the lock)
and is undone at the app's next launch outside it (`--keep-settings` keeps it). The
lock is released between commands, so a sequence that must not be split (install,
then plays, a pad) runs as one session:
`./pp phone lock -- sh -c './pp install --no-build && ./pp ui --play app-367520 --until first-frame+10'`.

```sh
./pp ui --play app-367520 --until first-frame+10 --shot  # Hollow Knight launch smoke check
./pp ui --action open:settings --shot-each-action       # show a UI page
```

- The final `result` event carries the run directory and timeline; retain its logs,
  screenshots and any crashes. Action ordering, bounded waits, pad routes and measured
  gameplay: `pp ui --help` and [DEVICE.md](docs/DEVICE.md#driving-a-title).
- A runtime change needs a Hollow Knight (`app-367520`) play through first frame+10;
  a UI change needs a run showing the changed page/setting or launch. This is a smoke
  gate, not proof of gameplay or performance. Do not call those changes verified until
  a run shows them; without a run, say they were not checked on the phone.
- Check charge and setup with `pp phone status`. Built-in JIT (the default) needs
  Developer Mode, LocalDevVPN and pairing; Settings › Setup check also offers
  StikDebug and Another app, with different prerequisites
  ([JIT activation](docs/DEVICE.md#jit-activation), decision 0051). No workstation
  provides JIT. Keep the app in front during runtime startup, and connect a controller
  before it.
- When told the session is unattended, run `./pp phone unattended on` first: between
  runs the phone then shows a black screen, not the lit Home Screen (OLED burn-in;
  [DEVICE.md](docs/DEVICE.md#sharing-the-phone)). `off` when the person is back.
- A JIT step that times out connecting to `10.7.0.1` means LocalDevVPN is down, and a
  phone near empty fails runs: both need the person at the phone, so ask; do not retry.
- A result that others rely on goes in `docs/evidence/<date>-<topic>.md` with the
  IPA's sha256 (the `installed` event of a `pp ui` run, and `pp phone status`, have it).
  Screenshots stay in the run directory under `.work`: describe them in the text
  (games' artwork is not ours to publish; `pp secrets` fails an image in `docs/evidence/`).
- Every game you play on the phone gets its latest result in Linear (team PLA, project
  Compatibility; one issue per title, `Name (Steam appID)`, with **Status:** Works,
  Playable with issues or Broken and **Best known:**, the IPA and the run directory).
  Search first and update the existing issue, then its status in
  `site/compatibility/games.json` (playport.dev/compatibility).
  A failure outside your task is filed
  there, not fixed in passing; a subagent lists its games for the supervisor to file.
- When a question is quicker to answer on this workstation than on the phone (what a game
  waits for, Playport or the game, its network, a file's format, a binary), answer it under
  desktop Wine/Proton here first, then fix and confirm on the phone. A game alive with no
  first frame is often behind a window, which the phone shows until then (`[guest-window]`,
  `[win-pos]` lines; decision 0075):
  [HOST-DEBUGGING.md](docs/HOST-DEBUGGING.md) (the setup in the build area; sway display
  only, never the owner's niri session or browser).

## Reference

This file is the current working contract; command help and reference docs describe
current behavior. [Plans](docs/plans/README.md) are proposals/work in progress, not
accepted policy. Check a [decision's](docs/decisions/README.md) status and later
amendments: proposed records are not accepted, and superseded rules are historical.
[Dated evidence](docs/evidence/) records what a particular build/run showed, not an
evergreen command recipe.

| Doc | What it holds |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | the one-process runtime, JIT, the app's host pieces, the patch series |
| [BUILDING.md](docs/BUILDING.md) | build inputs, the build area, each stage, variants, signing, the IPA checks, CI |
| [DEVICE.md](docs/DEVICE.md) | phone setup, JIT, driving the UI, measuring, Steam, logs, the secret scan |
| [HOST-DEBUGGING.md](docs/HOST-DEBUGGING.md) | the workstation as a debugging aid: a game under desktop Proton, hidden windows, browser pages, requests, A/B in a scratch prefix |
| [UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md) | moving the Madeira pin |
| [DISTRIBUTION.md](docs/DISTRIBUTION.md), [LICENSING.md](docs/LICENSING.md), [NOTICES.md](docs/NOTICES.md) | giving an IPA to anyone: source, relinking, notices |
| [decisions/](docs/decisions/README.md) | why things are the way they are; a decision changes only by a new record |

## Maintaining this file

Keep this file for knowledge useful to almost every session in this project. Do not
repeat what the code or `pp --help` already shows; point to it. Rewrite or prune
entries rather than appending new ones, and keep them concise.

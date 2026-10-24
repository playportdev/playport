# Playport

An iOS app that runs x86-64 Windows games on a non-jailbroken iPhone, built on
[willfaust/Madeira](https://github.com/willfaust/Madeira): Wine (ARM64EC), FEX-Emu
and DXMT as one Mach process. One Linux workstation builds, signs and installs it;
there is no Mac. This file is how to work here — build, ship, test. Reference docs:
below.

## Layout

| Path | What |
| --- | --- |
| `pp` | the one entry point (`./pp --help`, then `pp <cmd> --help`) |
| `pins.lock`, `upstream/madeira` | the upstream commits a build uses; `pins.lock` madeira must equal the submodule gitlink |
| `patches/<target>/` | every change to upstream code, as `git format-patch` files in `series` order |
| `build/` | what `pp build`/`install`/`verify` run (`pipeline`, `install`, `verify-ipa.py`, `stages/`, `toolchain/`) |
| `app/` | the iOS app (Swift package: `Sources/S1Probe` the app, `HostIOKit`, `PlayportKit`, `SteamClient`) |
| `tools/` | `pp`'s modules (`phonelib.py` the phone/lock/events, `checks.py` the `pp test`/`pp sync` checks, `ui.py`, `perf.py`, `gpu.py`, `pad.py`, `afc.py`, `sync.py`, `slots.py`), `pad/` scripts, `tests/`, netmuxd unit in `systemd/` |
| `docs/` | reference (below), `docs/decisions/`, `docs/evidence/` |
| `.work/` | build area (`$PLAYPORT_BUILD`, gitignored): run trees, caches, IPAs, run state, phone lock, install record |

## Rules

- **Linear tracks everything.** Team PLA is the source of truth for planned work, bugs,
  follow-ups and release handoffs. Any plan — including drafts under `.work/plans/` — gets
  a Linear issue when written, before commit or execution: search first, reuse an issue
  covering its scope, or create one. Link it in the plan under `**Linear:**` and put the
  plan's repository path in the issue. Keep progress, blockers, evidence and completion in
  sync; split follow-ups into linked issues, not prose. Delete a plan only once its outcome
  is in decisions/evidence and `docs/plans/finished.md`, with leftover work in open issues.
  [Plans](docs/plans/README.md) indexes documents; it is not a backlog.
- **Commit each completed chunk** once its checks pass, before the next chunk or reporting
  done: code, its documentation and changed build records — never unrelated changes or
  private data. A check that blocks it is a blocker to report, not a chunk to commit as
  finished.
- **Upstream code is never edited in place.** Change it as a `git format-patch` file in
  `patches/<target>/` plus its `series` entry, with `Class:`, `Evidence:` and `Offered-upstream:`
  trailers ([ARCHITECTURE.md](docs/ARCHITECTURE.md#patch-series)). The build compares each tree
  to its series by content, so an edited patch reapplies next build.
- **Name gate:** `pp names` must stay clean (also run by `pp test` and CI) — name no project
  as provenance except willfaust/Madeira.
- **Pins.** Madeira is frozen at `8c050d0` and Playport owns that layer (decision 0054):
  `pp sync` only reports new upstream commits and moves none, and a wanted fix is hand-ported
  as a Playport patch ([UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md)). The `wine`, `dxmt`, `fex`,
  `rpmalloc` pins and their `patches/*-port` series (for Wine also the `madeira-port` patches
  `patches/madeira-unix`, and `patches/wine-valve` with its pin) move only by a manual rebase or pick
  **plus a Hollow Knight play on the phone** (decisions 0007, 0008, 0013, 0018). `pp rebase`
  does that rebase in scratch; check every hunk it flags against both sides — git misplaced
  several auto-merged hunks in the FEX rebase. After a DXMT rebase rerun `gen_remote_guard.py`
  and `gen_api_names.py` in `run/dxmt-patched/dxmt/src/winemetal/`, then `pp slots` must be
  clean: the slot numbers are an ABI no merge can check.
- **Build records are committed.** A build in `.work/run` rewrites `app/artifacts.tsv` and
  `build/generated/wine-pe-*.tsv` when its outputs change: commit them with the change that
  caused it. Wine PE and DXMT hash their build directory, so a build anywhere else (another
  `PLAYPORT_RUN`, a `pp sync` candidate) puts them back and leaves its own beside the IPA
  (`out/…/records/`); any other diff there means a tree was built from something else.
- **Checkout isolation** (decisions [0028](docs/decisions/0028-one-checkout.md),
  [0069](docs/decisions/0069-host-only-worktrees.md),
  [0117](docs/decisions/0117-side-copies-that-build.md)): device work stays in the main
  checkout, on a branch. An owner-authorized side worktree (`.work/worktrees/<name>`, own
  branch, one writer) may build/test in its own `.work`, which reflinks (never symlinks or
  shares) main's `cache`, `inputs`, `run` with main's paths rewritten first as 0117 lists,
  proven by a marker that main's `.work` was not written. It never changes main's source,
  index, branch or runtime state, and never runs `pp install`, `pp ui`, `pp perf`, `pp phone`,
  `pp release` or `pp sync`: its branch moves to the main checkout, rebased, for phone gates.
  It commits only path-independent build-record rows and reports unrun device gates.
- **The UI is the only entry point** (decision 0012): a person does everything in the app's
  UI, and the workstation tests it by driving that UI (`pp ui`). No launch mode, environment
  switch, terminal client or push-a-file tool reaches app functionality another way; a
  capability the tooling needs goes into the UI first.
- **Two apps from one tree** (decision 0009): `dev` (default) `S1Probe.app`, which the UI
  driver drives and every driver needs installed; `release` `Playport.app`, no driver, quiet
  runtime, size-capped `playport.log`. Dev-only Swift goes in `app/Sources/S1Probe/Dev/` or
  under `#if !PLAYPORT_RELEASE`; `pp verify --variant release` fails an executable naming a
  driver variable or file.
- **Swift.** xtool builds it at `-Onone`, so a CPU-heavy package opts into `-O` itself
  (`app/SteamClient/Package.swift` does). The app build loads no Observation macro plugin:
  `@Observable` fails, use `ObservableObject`.
- **Disk.** Everything the project makes stays in the repository: build and scratch work go
  under `.work/` (`$PLAYPORT_BUILD`, gitignored), never `/tmp` (a small RAM-backed tmpfs) or
  elsewhere in `$HOME`. System tools stay installed system-wide (`./pp setup` records them in
  `.work/inputs.local`);
  nothing committed or built names a path outside the repository, so docs and evidence write
  `$PLAYPORT_BUILD`, `$LLVM_MINGW` or a repo-relative path (`pp secrets` and `pp verify` fail a
  home path). Gitignore anything that must not be pushed.
- **The phone.** One phone, three free-team app slots, profiles that last about seven days
  ([DEVICE.md](docs/DEVICE.md#free-team-limits)). Never uninstall the app: that deletes its
  container (the Wine prefix, the Steam session, the installed titles). `pp install` upgrades
  in place.
- **Secrets.** The RP pairing file, the Steam session, the device UDID and the team ID never
  enter the repository; `pp secrets` (also in `pp test`) must be clean before committing
  evidence or logs.

## Build

In the main checkout, after `./pp setup` records the machine's tools:

```sh
./pp check                     # compile the app unsigned; first builds changed dependencies/notices
./pp build                     # build what changed into a verified dev IPA
./pp build --plan              # inspect what would run and why
```

Prefer focused host checks when they can answer the question. Stamps make builds incremental
while app and verification still run: assume no fixed warm-loop time. A second build on the
same run directory exits at once (`flock -n`). Options, variants and stages: `pp build --help`.

## Ship

`./pp install` checks the account, phone and profile, builds what changed, then upgrades in
place; `--no-build` uses the newest verified IPA. An IPA for a tester is a distribution:
[DISTRIBUTION.md](docs/DISTRIBUTION.md). `pp release VERSION` requires a clean, pushed HEAD,
reuses its unsigned release IPA (or builds it), and makes a GitHub draft it never publishes
(decisions 0038, 0050) — commit changed build records and push before that build/handoff.
The release app gets no automated phone tests: the owner installs it, plays and signs off
(decision 0068). Options and records: `pp install --help` and [DEVICE.md](docs/DEVICE.md).

## Test

**Host.** `./pp test` runs the name gate, the secret scan, the pin and patch-series checks
(series entries, trailers), `tools/tests`, the app's host C tests (`app/tests`) and the
Swift package tests. `--quick` leaves out Swift; CI runs it.

**The phone.** Every device command takes the device lock itself: it prints who holds it and
blocks in the kernel while another job has it, so there is nothing to check first. One lock, one
install record and one session of settings undo cover every job in `.work` (decision 0016,
[DEVICE.md](docs/DEVICE.md#sharing-the-phone)): `pp ui`/`pp perf` refuse another checkout's IPA
(`--any-build` drives it anyway, `--expect-ipa` names one), and `set:`/`hud:`/`--settings` last
for the session and are undone at the app's next launch outside it (`--keep-settings` keeps them).
The lock is released between commands, so a sequence that must not be split runs as one session:
`./pp phone lock -- sh -c './pp install --no-build && ./pp ui --play app-367520 --until first-frame+10'`.

**UI sessions.** Prepare explicit `pp ui` actions on the workstation, announce the start,
then run one short, focused batch. Finish or cancel every queued input, release the lock and
announce completion before doing offline analysis. Keep Playport visible throughout UI work;
no black-screen interludes followed by more input. App navigation and settings use semantic
`pp ui` paths: add a missing path first, rather than improvising taps, pad scrolling or direct
input scripts. If the owner reclaims the phone or another app takes foreground, stop input;
do not automatically relaunch and continue. These quick sessions apply to UI work, not
gameplay, and have no arbitrary hard time limit.

Long commands print JSON events, one per line: read only the final `"event": "result"` line
(step events carry a `result` field). It gives the run directory and timeline — retain those logs,
screenshots and crashes; ordering, bounded waits, pads and measurement: `pp ui --help`.

**Waiting.** Use a timeout that covers the whole operation (at least 600 seconds for build/install/play).
Follow the current harness's foreground/background and completion-notification contract, and
confirm the producer's exit status, not a trailing `echo` or `tail` status. Do not poll with
`pgrep -f`, wait with `tail -f | grep -m1`, or kill with `pkill -f`: these can match themselves
or outlive/kill unrelated jobs.

```sh
./pp ui --play app-367520 --until first-frame+10 --shot  # Hollow Knight launch smoke check
./pp ui --action open:settings --shot-each-action       # show a UI page
```

- **Smoke gate.** A runtime change needs a Hollow Knight (`app-367520`) play through first
  frame+10; a UI change needs a run showing the changed page/setting or launch. Neither proves
  gameplay or performance: do not call such a change verified until a run shows it, and without
  one say it was not checked on the phone.
- Check charge and setup with `pp phone status`. Built-in JIT (the default) needs Developer
  Mode, LocalDevVPN and pairing; Settings › Setup check also offers StikDebug and Another app
  with different prerequisites ([JIT activation](docs/DEVICE.md#jit-activation), decision 0051).
  No workstation provides JIT. Keep the app in front during runtime startup, and connect a
  controller before it.
- Told the session is unattended? `./pp phone unattended on` first, `off` when the person is
  back: between runs the phone shows a black screen, not a lit Home Screen (OLED burn-in).
- A JIT step that times out connecting to `10.7.0.1` means LocalDevVPN is down, and a phone
  near empty fails runs: both need the person at the phone, so ask; do not retry.
- A result that others rely on goes in `docs/evidence/<date>-<topic>.md` with the IPA's sha256
  (the `installed` event of a `pp ui` run, and `pp phone status`, have it). Screenshots stay in
  the run directory under `.work`: describe them in the text (games' artwork is not ours to
  publish; `pp secrets` fails an image in `docs/evidence/`).
- Every game you play on the phone gets its latest result in Linear (team PLA, project
  Compatibility; one issue per title, `Name (Steam appID)`, with **Status:** Works,
  Playable with issues or Broken and **Best known:**, the IPA and the run directory). Search
  first and update the existing issue, then its status in `site/compatibility/games.json`
  (playport.dev/compatibility). A failure outside your task is filed there, not fixed in
  passing; a subagent lists its games for the supervisor to file.
- When a question is quicker to answer on this workstation than on the phone (what a game waits
  for, Playport or the game, its network, a file's format, a binary), answer it under desktop
  Wine/Proton here first, then fix and confirm on the phone:
  [HOST-DEBUGGING.md](docs/HOST-DEBUGGING.md) (the setup in the build area; sway display only,
  never the owner's niri session or browser). A game alive with no first frame is often behind a
  window, which the phone shows until then (`[guest-window]`, `[win-pos]` lines; decision 0075).

## Reference

This file is the current working contract; command help and reference docs describe current
behavior. [Plans](docs/plans/README.md) are proposals/work in progress, not accepted policy.
Check a [decision's](docs/decisions/README.md) status and later amendments: proposed records are
not accepted, and superseded rules are historical. [Dated evidence](docs/evidence/) records what
a particular build/run showed, not an evergreen command recipe.

| Doc | For |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | runtime, JIT, the app's host pieces, patch series |
| [BUILDING.md](docs/BUILDING.md) | build inputs, stages, variants, signing, IPA checks, CI |
| [DEVICE.md](docs/DEVICE.md) | phone, JIT, driving the UI, measuring, logs, secret scan |
| [HOST-DEBUGGING.md](docs/HOST-DEBUGGING.md) | desktop Proton/Wine debugging, scratch prefix |
| [UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md) | moving a pin |
| [DISTRIBUTION.md](docs/DISTRIBUTION.md), [LICENSING.md](docs/LICENSING.md), [NOTICES.md](docs/NOTICES.md) | shipping an IPA: source, relinks, notices |
| [decisions/](docs/decisions/README.md) | why it is this way; a decision changes only by a new record |

## Maintaining this file

Keep this file for knowledge useful to almost every session in this project. Do not
repeat what the code or `pp --help` already shows; point to it. Rewrite or prune
entries rather than appending new ones, and keep them concise.

# Playport

An iOS app that runs x86-64 Windows games on a non-jailbroken iPhone. It is
built on [willfaust/Madeira](https://github.com/willfaust/Madeira): Wine
(ARM64EC), FEX-Emu and DXMT as one Mach process. Everything builds, signs and
installs from one Linux workstation, with no Mac. This file covers how to
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
- **Pins.** The Madeira pin moves only through `pp sync <sha>`
  ([UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md)). The `wine`, `dxmt`, `fex` and `rpmalloc` pins
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

```sh
./pp setup                     # once per machine: where llvm-mingw, the darwin SDK and netmuxd's socket are
./pp build                     # build what changed into a verified IPA (dev)
./pp build --variant release   # the player's app, from the same trees
./pp build --clean             # every tree again from its pin (a release for a tester, a suspect tree)
./pp build --plan              # what a build would run and why, building nothing
./pp check                     # compile the app unsigned: Swift errors in about 10 s, no IPA
                               # (it first builds any tree whose inputs changed, and the notices,
                               # whose first run fetches about 0.5 GB of locked inputs; it says so)
```

- The pipeline's stages are `inputs sources unix pe fex dxmt vulkan steamapi idevice stage notices app verify`.
  Each tree stage stamps a digest of its inputs (pins, series, build scripts, the
  toolchains) and runs again only when that changes, so a Swift-only change takes about 20 s and a patch
  change rebuilds what its patches touch (`unix`, `mesa`: about a minute; a Wine PE patch
  about 2.5 minutes with the `dxmt` and `vulkan` rebuilds after it). A first build takes 10
  to 15 minutes. `--from STAGE` forces STAGE and everything after it.
- Work in this checkout, one build at a time: a second one exits at once. Changes go
  on a branch here (decision 0028).
- Output: `out/<time>-<sha8>/Playport-26.5-<sha8>.ipa` (release: `-release-`), with
  `SHA256SUMS`, `artifacts.tsv`, `provenance.txt` and the logs. Stage logs are in
  `run/logs/<stage>.log`; a failure prints the last 25 lines. Inputs, stages and
  checks in detail: [BUILDING.md](docs/BUILDING.md).

## Ship

```sh
./pp install                   # build what changed, then install on the phone in place
./pp install --no-build        # the newest verified IPA (--ipa FILE for another)
./pp install --variant release # the release app, over the same bundle ID and container
```

`pp install` checks the account, the phone (one device, Developer Mode, a free slot,
space) and the IPA's profile before it builds. It then closes the running app and
installs in place. An IPA the phone already has is not sent again (`--force` sends
it). Its log goes to `$PLAYPORT_BUILD/install-runs/`, and what the phone runs, from which
checkout, to `.work/device-state.json`. An IPA for a tester is a distribution: follow
[DISTRIBUTION.md](docs/DISTRIBUTION.md). `pp release VERSION` takes a clean, pushed HEAD's
unsigned release IPA (reusing the newest build of HEAD; `--clean` rebuilds every tree)
and makes a GitHub draft; it never publishes (decisions 0038, 0050). So: build, commit
the build records, push, build again (about a minute), then release.

## Test

**Host.** `./pp test` runs the name gate, the secret scan, the pin and patch-series
checks (series entries, trailers), `tools/tests`, the app's host C tests (`app/tests`)
and the Swift package tests. `--quick` leaves out Swift; CI runs it.

**The phone.** Every device command takes the device lock itself. When another job
holds it, the command prints who holds it and waits in the kernel, so there is nothing
to check first. Long commands print JSON events, one per line, ending with a
`"event": "result"` line (grep for that: UI step events carry a `result` field too).

**Waiting.** Most runs fit a foreground call: `pp install` about 1.5 min, a play to
`first-frame+10` about 1 min, `pp perf --secs N` N plus about 1 min plus `--cool`. Run
those in the foreground with a long enough timeout (at least 600 seconds). Put longer ones in the harness's background mode and do other work: the
harness reports when they exit. Where a turn must block on a background job, wait for
the job's own exit line (end its command with `; echo "exit $?"` and wait for `^exit`
in its output file). Never `while pgrep -f NAME` (it matches the waiting loop's own
command line, so it never ends) or `tail -f FILE | grep -m1` (tail outlives the job),
and no `pkill -f`: past sessions lost hours to both.

**Sharing the phone** (decision 0016). One lock and one install record, in `.work`,
for every job on the machine. `pp ui` and `pp perf` refuse an IPA another checkout installed
(`--any-build` drives it anyway, `--expect-ipa` names the one you want). What a run
changes with `set:`, `hud:` or `--settings` lasts for its session (one hold of the lock)
and is undone at the app's next launch outside it (`--keep-settings` keeps it). The
lock is released between commands, so a sequence that must not be split (install,
then plays, a pad) runs as one session:
`./pp phone lock -- sh -c './pp install --no-build && ./pp ui --play app-367520 --until first-frame+10'`.

```sh
./pp phone status                                   # the phone, the app, what is installed, who holds the lock
./pp ui --play app-367520 --until first-frame+10 --shot       # Hollow Knight through the Play button, a screenshot, app ended
./pp ui --action open:settings --shot-each-action               # look at a page; open:app-367520 is a game's page
./pp ui --action set:metalHUD=true --play app-367520 --until first-frame+5 --shot   # a setting, then a play
./pp ui --settings 'app-367520:{"frameLimit":30}' --play app-367520
                                                    # a game's launch settings, as its page saves them (ID:{} clears)
./pp ui --action install:367520                      # install from Steam with the paired session
./pp ui --play app-367520 --pad --until first-frame+20 --leave-running   # a scripted pad, then (one session: pp phone lock):
./pp pad send "150 A" "2500 -" --shot FILE           # press, wait for it to play, screenshot
./pp pad push hk-walk                                # a script from tools/pad/ (pp pad rest stops it)
./pp perf --secs 180 --pad first-frame+25:hk-new-game   # a measured run (DEVICE.md)
./pp phone kill | log | crashes | shot FILE | pull REMOTE
./pp phone lock -- CMD                              # CMD as one session (a sequence), or any other phone command
```

- The `result` event carries the run's directory and `timeline`: the `title:`/`jit:`
  marks, seconds from Play to the JIT pool, the game start and the first frame. The
  directory holds `events.jsonl`, `timeline.txt`, `pull/s1-host.log` (this run only:
  the driver moves the old log aside first), the screenshots, and `crashes/` when the
  app died.
- A run stops at `--until` (`done`, `first-frame+S`, `mark:TEXT+S`, `event:NAME+S`) and
  ends the app (`--leave-running` keeps it); `pp ui --help` has the rest.
- Hollow Knight (`app-367520`) is the installed cohort title. Its first frame comes about
  10 s after Play, and JIT takes about 3.4 s of that. A change is good on the phone when
  that play reaches its first frame and runs on (`--until first-frame+10`), and a UI
  change when a run shows it.
- Do not report a change as done until a run shows it: `pp ui --action open:…
  --shot-each-action` for a page or a setting, a `--play` for a launch. When there is
  no run, say that the change was not checked on the phone.
- The phone needs Developer Mode, LocalDevVPN connected, the pairing file (once per
  phone) and charge (`pp phone status` shows the battery). JIT comes only from the app's
  own helper extension, for every launch ([DEVICE.md](docs/DEVICE.md#jit-activation)).
  Keep the app in front during a launch, and connect a controller before it.
- A JIT step that times out connecting to `10.7.0.1` means LocalDevVPN is down, and a
  phone near empty fails runs: both need the person at the phone, so ask; do not retry.
- A result that others rely on goes in `docs/evidence/<date>-<topic>.md` with the
  IPA's sha256 (the `installed` event of a `pp ui` run, and `pp phone status`, have it).
  Screenshots stay in the run directory under `.work`: describe them in the text
  (games' artwork is not ours to publish; `pp secrets` fails an image in `docs/evidence/`).

## Reference

| Doc | What it holds |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | the one-process runtime, JIT, the app's host pieces, the patch series |
| [BUILDING.md](docs/BUILDING.md) | build inputs, the build area, each stage, variants, signing, the IPA checks, CI |
| [DEVICE.md](docs/DEVICE.md) | phone setup, JIT, driving the UI, measuring, Steam, logs, the secret scan |
| [UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md) | moving the Madeira pin |
| [DISTRIBUTION.md](docs/DISTRIBUTION.md), [LICENSING.md](docs/LICENSING.md), [NOTICES.md](docs/NOTICES.md) | giving an IPA to anyone: source, relinking, notices |
| [decisions/](docs/decisions/README.md) | why things are the way they are; a decision changes only by a new record |

## Maintaining this file

Keep this file for knowledge useful to almost every session in this project. Do not
repeat what the code or `pp --help` already shows; point to it. Rewrite or prune
entries rather than appending new ones, and keep them concise.

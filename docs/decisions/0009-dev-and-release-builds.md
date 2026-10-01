# 0009: A dev build and a release build

**Status:** accepted, 2026-09-25. It replaces the earlier rule that the app
has one identity with no dev/release split. The bundle ID stays shared. Its
harness modes, test programs and guests are retired by
[0012](0012-the-ui-is-the-only-entry-point.md): the dev build keeps the UI
driver and the scripted pad.

## Decision

`build/build-from-pins --variant dev|release` builds one of two apps from
the same trees: the same runtime, DXMT, FEX, Wine PE set and XInput DLLs.
The two differ only in the app package and in what the runtime is asked to
do at start.

| | dev (the default) | release |
| --- | --- | --- |
| Who it is for | the workstation, the harness and the device gates | a player |
| Bundle, executable, Swift module | `S1Probe.app`, `S1Probe`, `S1Probe` | `Playport.app`, `Playport`, `Playport` |
| Bundle ID | `dev.playport.app` | the same, so each installs over the other and keeps the container |
| Harness modes (`S1_MODE`, `LADDER_*`, the test prompt, the scripted pad) and LadderKit | yes (`Sources/S1Probe/Dev/`) | not compiled |
| JIT | workstation for a driven launch; built-in or StikDebug from the Home Screen | built-in only; `Info.plist` queries no StikDebug URL |
| Test programs (`P5-proc`) and ladder/G2 guests in the bundle | yes | no |
| Settings | storage; JIT with the method picker, raw readiness (TXM), the helper's reason and a disk image reset; Logs; Diagnostics; ABI version | storage; JIT as a plain status (Ready, Needs a pairing file, Can't connect, Not ready), the pairing file import, and a retry and a disk image download only when a check failed |
| Result screen | the driver's result line, the exit code and the helper's JIT failure | a plain explanation and what to do |
| Account tab | the last token renewal's raw result | not shown |
| Game pages | state, developer, size, build, Steam app ID, `C:\Games` folder, executable, last played, the cohort's note, raw verify and launch-plan errors | state, developer, size, last played; failures worded without internals (the reason goes to the log) |
| Runtime switches set at start | none | `MADEIRA_QUIET=1`, `MADEIRA_NO_DIAGNOSTICS=1`, `WINEDEBUG=-all`, `DXMT_LOG_LEVEL=error` |
| Log | `Documents/s1-host.log` (and `steam-drive.log`), appended with no limit | `Documents/playport.log` only, at most 4 MB per session, one older file kept |

The Swift code tells them apart with the compile condition
`PLAYPORT_RELEASE`. `app/Package.swift` reads `PLAYPORT_VARIANT` from the
environment and sets the product name, the dependencies and the condition.

## Why

A copy that leaves the workstation should hold only what a player uses.
The dev build carries a whole test apparatus. There are six launch modes the
workstation selects through the environment, a banner that polls a file
four times a second, a scripted gamepad, probe executables, and screens that
show ABI numbers and raw result lines. Its runtime logs without limit (a
Hollow Knight session writes megabytes a minute) and samples every thread
for the whole session. None of that belongs on a player's phone.

The dev build stays the default because every gate, driver and evidence
record depends on it.

## How the release build is kept quiet

- **Runtime.** `WineHostRuntime.swift` sets the switches above before
  `wine_host_init`, without overwriting what a title's configuration sets.
  `MADEIRA_QUIET` and `WINEDEBUG=-all` are the configuration the Hollow Knight
  thermal runs measured. `MADEIRA_NO_DIAGNOSTICS` is new. With it,
  [madeira-unix 0018](../../patches/madeira-unix/0018-ntdll-skip-the-diagnostic-samplers-and-censuses-when.patch)
  skips the `[thread-sample]`, `[xp]` and `[wprof]` samplers and the
  `[span-census]`, `[valloc]` and `[vfree]` census lines, and
  [dxmt 0007](../../patches/dxmt/0007-dxmt-report-no-memory-census-when-MADEIRA_NO_DIAGNOS.patch)
  skips the port's memory census, which logs at error level. `MADEIRA_QUIET`
  stops none of these, and `perf-run.py` needs them in a dev build.
- **Size.** At launch, a `playport.log` over 2 MB becomes
  `playport.previous.log`. Within a session the log stops at 4 MB. The app's
  own appends and `host_log.c` check the size before they write. A watchdog
  in `wine_host.c` (`wine_host_set_log_limit`) points the runtime's stderr at
  `/dev/null` once the file reaches the limit. The wineserver's own log file
  is not opened.
- **Not shown.** Nothing in the UI shows or exports a log. The file is in
  the container's Documents, which the Files app does not show, so reading it
  takes a computer.
- **Checked.** `build/verify-ipa.py --variant release` fails an IPA whose
  executable holds a LadderKit, `Dev/` or `S1Probe`-module symbol, or a
  harness environment name or file name, or whose bundle carries a test
  program or a guest.

## What it costs

- A release build cannot be driven: no `S1_MODE`, no ladder, no
  `title-device-run.py`. Every device gate needs a dev build installed, and
  installing one replaces the release build (the container stays).
- A failed launch in the field leaves at most two files of a few MB, and
  they hold only what the runtime calls an error. Diagnosing more needs a dev
  build.
- The release build is still debug-configured Swift (`-Onone`, as xtool
  builds it) with `get-task-allow`, which the JIT attach needs. It is not an
  App Store build.
- `build-from-pins` builds the release app from a shadow package in
  `app/.release/`, because xtool reads the product name from `./xtool.yml`.
  That package links to `app/` and holds its own `Package.swift`, a generated
  `xtool.yml` and a hard-linked `Runtime/`.

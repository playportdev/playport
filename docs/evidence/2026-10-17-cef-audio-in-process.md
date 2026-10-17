# CEF with the audio service in the browser process (desktop Proton)

**Linear:** [PLA-381](https://linear.app/playportdev/issue/PLA-381),
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Plan:** [low-VA CEF](../plans/2026-10-16-cef-low-va-build.md).
**Decisions:** [0110](../decisions/0110-own-cef-build-for-a-clients-cef.md),
[0111](../decisions/0111-fewer-cef-processes-with-chromium-features.md).
Branch `dev/pla-291-rockstar-launcher`. Host only; nothing ran on the phone.

**Question:** With `AudioServiceOutOfProcess` off by default in our CEF, does Social Club still
show its sign-in page under desktop Proton, and is the audio utility process gone?

**Answer:** Yes to both. Social Club reached `FINISHED` at 2.2 s and showed its sign-in page from
30 s to 150 s. The tree has 5 Chromium processes instead of PLA-378's 6, and no audio service
process started at any time.

## The change

- `patches/chromium/0007` makes `features::kAudioServiceOutOfProcess`
  (`content/public/common/content_features.cc:108` in the pinned tree) disabled by default on
  Windows; macOS and Linux keep it on.
  - Social Club replaces the browser's `--disable-features` for its children (0111), so the switch
    could not do this. A compiled default it never names can.
  - Chromium's in-process path is the one `--single-process` and `--disable-features` use
    (`content/browser/browser_main_loop.cc:1567-1576`).
- Nothing from the dropped PLA-379 V8 patch is in it.

## Build [M]

- **Series check.** The scratch replay (stock patches, `patches/cef`, `patches/chromium`) matched the
  live tree before the change (114 patches, 422 files) and after it (115 patches, 423 files), with
  zero mismatches.
- **Build directory.** The previous low-VA ninja directory, parked as
  `agent-notes/pla379-parked/Release_GN_x64_lowva-rejected/`, was moved back to
  `cef-src/src/out/Release_GN_x64_lowva` and used as an incremental build directory. Its V8 source
  edits had been reverted in the live tree, so ninja rebuilt `v8/src/api/api.cc` (both toolchains),
  the context snapshot and `content_features.cc`, then relinked `libcef.dll`. None of its earlier
  outputs is the payload: every recorded file was rehashed after this build.
- **Commands.** `build/cef/run-project-files.sh` (GN only, 35,966 targets), then
  `build/cef/run-ninja-lowva.sh pla381 12`: `nice -n 15`, `-j 12`, `-k 50`, exit 0, 14 edges after
  restat. `run-gen.sh` and the stock patcher were not run. `out/Release_GN_x64`, `out-stage-b` and
  `out-pla379-baseline` are untouched. Disk: 590 GB free.
- **Payload** (`build/cef/assemble-payload.py` into `cef-src/out-stage-c`, then `verify-payload.py`
  and `stage-payload.py`: 233 files, 232 runtime files plus 5 notices staged):

  | File | Before (`a07bb71d` payload, kept in `out-pla379-baseline`) | Now |
  | --- | --- | --- |
  | `Release/libcef.dll` | `a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e` | `f724d38b21abaf9cf14ff6b4eea97b0e9f483c83d525a81d79cca431468d0500` |
  | `Release/v8_context_snapshot.bin` | `ab1090ad…f0ad99f` | unchanged |
  | `Release/chrome_elf.dll` | `6ceaf1f1…aa67367` | unchanged |
  | the other 230 files | — | unchanged |
  | `build/generated/cef-143.0.14.sha256` | `59517039…68d89c78` | `47551eef8139d6ff9d6ee1f2bcf61b0253f6a753ec691995e605342672ac817c` |

  The unchanged snapshot shows the reverted V8 sources match the approved baseline. The notices
  record (`82aaaa0d…`) is unchanged: the patch adds no third-party code.

## Desktop Proton swap [M]

The PLA-378 procedure: the scratch prefix `prefix-swap`, our payload copied over Social Club's CEF
files, the Stage R wrapper adding 0109's four switches and 0111's `--enable-features`, 150 s, then
the originals restored. `lsteamclient`, `steamclient` and `steamclient64` were disabled,
`STEAM_COMPAT_CLIENT_INSTALL_PATH` was an empty directory in the build area, and URL opens were
blocked. The prefix had no processes before or after either run; cleanup signalled only PIDs whose
`WINEPREFIX`, compared without a trailing slash, was the scratch prefix. After each run all 81
Social Club files matched their original hashes. No sign-in was attempted.

- **First run, on an owned Xvfb display: invalid.** `Launcher.exe` crashed 1.4 s in, with exception
  `0xc0000094` in a worker thread retrieving D3D11 device info, before Social Club created its
  browser. Earlier Xvfb runs crashed the same way with Rockstar's own files (`pla379-original-xvfb`),
  so the display, not the payload, caused it. It was rerun once under sway.
- **Second run, under the sway session** (its Xwayland `:0`, `WAYLAND_DISPLAY=wayland-1`; the
  owner's niri session was not used):
  - Social Club's states: `WAIT_BROWSER_WINDOW` 73 ms, `LOADING` 507, `WAITING_FOR_PAGE_READY`
    2047, `PAGE_READY`, `START_SIGN_IN` 2216, `FINISHED` 2228.
  - The screenshots at 30, 60, 90, 120 and 150 s all show the launcher window with Rockstar's logo,
    the **Sign In** form (Email, Password, Auto sign-in) and Rockstar's cookie notice over its lower
    part. They stay in the build area.
  - The browser process (Wine pid `033c`) loaded `mmdevapi.dll` and `winepulse.drv` itself.

| Chromium process at 145 s | PLA-378 (`pla378-f2`, stock 0111 payload) | This build |
| --- | --- | --- |
| browser | 63 threads | 65 threads |
| storage service | 9 | 9 |
| audio service | 10 | — (never started) |
| renderers | 3 (30, 30, 34) | 3 (30, 31, 33) |
| **processes** | **6** | **5** |
| CEF PSS / threads, with the wrapper | 2,096 MiB / 177 | 1,874 MiB / 169 |

- Utilities the browser started over the run: storage, `ProcessorMetrics` and 3 renderers in both;
  here also a `FilePatcher` and two `Unzipper` utilities, which ended. They are Social Club's or
  the launcher's own update work and were not looked into.

## Not done

- No phone run: not the Hollow Knight gate, not the launcher Open. On the phone the browser now runs
  the audio work, so its own threads and FEX code grow by what the service ran.
- Rockstar's logs, the run directories and the screenshots stay in
  `$PLAYPORT_BUILD/agent-notes/pla254-rockstar/runs/audio381*`.

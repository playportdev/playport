# Debugging on the workstation

The phone is slow to iterate on and hides a lot: no windows but the game's swapchain, no
browser, opaque TLS, logs only after a run, one lock shared by every job. The workstation runs the
same Windows game under desktop Wine/Proton in seconds, shows everything, and costs no phone time.
**When a question is quicker to answer on the workstation, answer it there first**, then fix and
confirm on the phone. This holds for any title and any store, and for any kind of question:

- **What is the game waiting for or complaining about?** A dialog, a launcher or DRM check, a
  browser sign-in, a missing file or registry value.
- **Is it Playport or the game?** If it fails the same way under desktop Proton with Playport's
  arguments and files, the cause is the game, its store or the arguments; if it works there, the
  cause is in Playport's runtime, and the desktop run narrows it (DLL loads, requests, traces).
- **What does the game do on the network?** Which servers, which requests, which errors.
- **What does a file, argument or registry value need to look like?** A/B it in a scratch prefix
  in minutes instead of a build and an install per try.
- **Static questions:** a binary's imports, strings, packer, architecture, or a store's API reply,
  read with workstation tools.

The phone stays the judge: a desktop run is evidence of a cause, never of a fix.

## Signs on the phone that point here

In a run's `pull/s1-host.log`:

- **Alive, no first frame:** CPU in `[thread-sample]`, black screenshots, no `first frame`. A small
  top-level window in `[win-pos]` (e.g. 550×146, centred) is a dialog: Playport draws only the
  game's swapchain, so GDI windows (message boxes, a DRM's or launcher's error box, a setup page)
  are invisible on the phone.
- **What ran just before:** DLL loads (`uxtheme.dll` comes with dialogs), file creates and their
  status (`c0000035` = exists), the same steps repeated (a check retrying).
- **A login or online feature failing with a generic error** (`UnexpectedError`, a timeout) and
  nothing else in the log: the game may want a browser page (`ShellExecute` of a URL), a launcher,
  or a file the store's launcher writes.
- **Strings in the executable** are a hint only: the message that matters may come from a DRM or a
  helper (Jurassic World Evolution's "Epic launcher is installed" string never showed; its DRM's
  error box did).

## The setup

Working copies live under `$PLAYPORT_BUILD/agent-notes/` (left in the build area, reused, not
committed). As of 2026-10-07 (under `agent-notes/store-auth/`):

- **Game files without the phone.** Epic and GOG: a Linux build of Playport's own installer
  (`eos/desktop/src`, `build`: a copy of `app/EpicClient` + `app/ContentKit` built with
  `swift test --build-system native --scratch-path …`, a scratch test that installs a title from
  the workstation's store session). Steam has no workstation session, so take a Steam game's files
  from the phone (`pp phone pull`, between other jobs) or reason from its manifest.
- **Runners** (`eos/desktop/run.py`, `jwe-launcher/run.py`, `gog-desktop/run.py` with a
  stand-in Galaxy service, `gog-desktop/svc` the real one built for Linux): Proton 10 `waitforexitandrun` outside
  Steam, a scratch prefix, Playport's exact arguments (for Epic: `EpicInstaller.arguments` +
  `authArguments`, a fresh code and ownership token from the workstation session just before
  launch), the run's own process group killed and `wineserver -k` at the end, logs scrubbed. Copy
  and adapt one for a new title.
- **Agent browser** (`eos/desktop/agent-browser/`, README): a Chrome the agent drives (own
  profile, CDP on 127.0.0.1:9333, `chrome-devtools-axi`), with the prefix's browser opens routed to
  it. The agent answers sign-in and consent pages itself; for Epic it signs the profile in with an
  exchange code.
- **HTTPS proxy for the game only** (`eos/desktop/mitm/`): `HTTPS_PROXY` set for the game, the
  proxy's CA in the scratch prefix's Root store, an addon that logs one scrubbed line per request
  (method, host, path, status, the few form keys that matter, the error code) and keeps no flows.

Store sessions on the workstation are read-only for these scripts: never refreshed, written or
printed. Codes and tokens stay in memory and in the child's argv or a 0600 file deleted after the
run.

## Rules (the owner works on this machine)

- **Display.** The owner's session is niri (`WAYLAND_DISPLAY=wayland-2`, `DISPLAY=:1`). Run every
  game, browser and screenshot on the sway session: set `env DISPLAY=:0 WAYLAND_DISPLAY=wayland-1`
  in the command itself, never inherit the environment's values. Check that `:0` answers first;
  otherwise `xvfb-run -a` (DXVK may not start under Xvfb; WineD3D does). Screenshots: `grim` with
  `WAYLAND_DISPLAY=wayland-1` set. If anything lands on niri, kill it by PID.
- **Browser.** Nothing opens in the owner's browser. Route a prefix's URL opens to the agent
  browser (the prefix's `WineBrowser` entry, `BROWSER`, an `xdg-open` shim first on `PATH`), or
  block them (`WINEDLLOVERRIDES=winebrowser.exe=d BROWSER=/bin/false`). Never ask the owner to
  approve a page.
- **Input.** Sway's headless seat did not pass synthetic input to a game (wtype, XTEST,
  `swaymsg seat cursor`); `ydotool` would type into the owner's session, so do not use it. A
  desktop run shows how far a game gets without input.
- **Processes.** Kill only your own process group by PID and `wineserver -k` with your
  `WINEPREFIX`; no `pkill -f`.
- **Disk.** Game copies and prefixes stay under `$PLAYPORT_BUILD/agent-notes/`; delete copies
  over a few GB when done unless they are reused.

## Techniques

- **Traces:** `WINEDEBUG=+loaddll`, `+msgbox,+reg,+file`, or narrower, for about a minute around
  the moment. `+msgbox` catches only `MessageBox`; a custom dialog shows only on screen, so take a
  screenshot.
- **The probes just before a window** name the check: the registry keys and files read, and their
  sizes.
- **A/B in a scratch prefix**, with a table of runs: one changed input per run (a file's content,
  an argument, a cache present or deleted).
- **Requests through the proxy** show a sign-in's path (a launch code redeemed, a device-code
  browser flow, a token refused) and a server's error codes.
- **Compare with the phone:** DLL load order, request sizes and order (`[sock-tl]` on the phone),
  the point where the two diverge.

## Cases

| Date | Title | Phone symptom | Desktop finding |
| --- | --- | --- | --- |
| 2026-10-07 | Snakebird Complete (Epic) | EOS `UnexpectedError` | its login opens a browser page (device code); the phone had no URL opener (decision 0064) |
| 2026-10-07 | Jurassic World Evolution (Epic) | alive, no frame, a hidden 550×146 window | the DRM's error box: the ownership-token file needed Epic's JSON reply, not the bare token ([evidence](evidence/2026-10-07-jwe.md), PLA-41) |
| 2026-10-07 | Moonscars (GOG) | the Galaxy SDK connects to the host's service, sends nothing, signs out (`GALAXY_SERVICE_NOT_AVAILABLE`) | the same files send `AUTH_INFO` at once and read Playport's reply (its listener built for Linux); no service registration needed; a probe of the SDK's socket calls works on the phone: cause not found ([evidence](evidence/2026-10-07-gog-galaxy.md)) |

Add a row for each new case, and file or update the game's Linear issue (AGENTS.md, "The phone").

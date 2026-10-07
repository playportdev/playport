# Reproducing a game on the workstation, and finding what a stuck game is waiting for

When a game fails on the phone and the log does not say why, run the same build of the game under
desktop Proton on this workstation, with Playport's exact arguments. The desktop shows windows,
browser pages and network requests the phone hides, and it costs no phone time. Two 2026-10-07
findings came this way in under an hour each:

- Snakebird Complete's EOS sign-in ends `UnexpectedError` on the phone: its login uses Epic's
  AccountPortal (a device code and a browser page), and the phone had no URL opener
  ([store game sign-in plan](plans/2026-10-06-store-game-auth.md), decision 0064).
- Jurassic World Evolution sat behind a window the phone never shows: its DRM's error box, because
  the `-epicovt` file held the bare token and not Epic's JSON reply (PLA-41,
  [evidence](evidence/2026-10-07-jwe.md)).

## Signs that a game is stuck behind something hidden (phone)

Check these in a run's `pull/s1-host.log` before guessing:

- **Alive, no first frame.** The process uses CPU (`[thread-sample]`), no `first frame` mark, black
  screenshots. Look for `[win-pos]` lines: a small top-level window (e.g. 550×146, centred) is a
  dialog. Playport draws only the game's swapchain, so GDI windows (message boxes, a DRM's or
  launcher's error box, a setup dialog) are invisible on the phone.
- **What ran just before the window.** The DLL loads (`uxtheme.dll` loads for dialogs), file
  creates and their status (`c0000035` = already exists), and repeated attempts of the same steps
  (a check retrying).
- **Strings in the executable** are a hint only; the message that matters may come from a DRM or a
  helper, not the strings you find (JWE's "Epic launcher is installed" string never showed).
- **A URL the game opens** (`ShellExecute` of http/https) goes nowhere on the phone before the URL
  opener; a game waiting on a browser sign-in looks stuck or fails its login at once.

Then reproduce on the desktop to read the window.

## The desktop setup

Everything lives under `$PLAYPORT_BUILD/agent-notes/` (left in the build area; reusable, not
committed). The working copies from 2026-10-07:

| Path under `agent-notes/store-auth/` | What |
| --- | --- |
| `eos/desktop/src`, `eos/desktop/build` | a copy of `app/EpicClient` + `app/ContentKit` built on Linux (`swift test --build-system native --scratch-path …`), with a scratch test that installs an Epic game with Playport's own `EpicInstaller` from the workstation's Epic session (no phone) |
| `eos/desktop/run.py`, `jwe-launcher/run.py` | runners: a fresh exchange code (and ownership token) from the workstation session just before launch, Playport's exact arguments (`EpicInstaller.arguments` + `authArguments`), Proton 10 `waitforexitandrun` outside Steam, a scratch prefix, the run's own process group killed and `wineserver -k` at the end, logs scrubbed |
| `eos/desktop/agent-browser/` (README) | a Chrome the agent drives (own profile, CDP on 127.0.0.1:9333) that the prefix's browser opens are routed to; signed in to Epic with an exchange code; pages answered with `chrome-devtools-axi` |
| `eos/desktop/mitm/` | an HTTPS proxy for the game only (`HTTPS_PROXY`, its CA in the scratch prefix's Root store); the addon logs one scrubbed line per Epic request (method, path, status, `grant_type`, `errorCode`) and keeps no flows |

Store sessions on the workstation are read-only for these scripts: never refreshed, written or
printed; codes and tokens only in memory and in the child's argv or a 0600 file deleted after the
run. Steam has no workstation session (it is only on the phone).

## Rules for the desktop (the owner works on this machine)

- **Display.** The owner's session is niri (`WAYLAND_DISPLAY=wayland-2`, `DISPLAY=:1`). Run every
  game, browser and screenshot on the sway session: set `env DISPLAY=:0 WAYLAND_DISPLAY=wayland-1`
  in the command itself, never inherit the environment's values. Check that `:0` answers first;
  otherwise use `xvfb-run -a` (DXVK may not start under Xvfb; WineD3D does). Screenshots of sway:
  `grim` with `WAYLAND_DISPLAY=wayland-1` set. If anything lands on niri, kill it by PID.
- **Browser.** A game's web pages must never open in the owner's browser. Route them to the agent
  browser (`prefix-setup.sh` sets the prefix's `WineBrowser` entry; `BROWSER` and an `xdg-open`
  shim first on `PATH`), or block them (`WINEDLLOVERRIDES=winebrowser.exe=d BROWSER=/bin/false`,
  which reproduces the phone before the URL opener). The agent approves sign-in and consent pages
  itself; the owner is not asked.
- **Input.** Sway's headless seat did not pass synthetic input to the game (wtype, XTEST,
  `swaymsg seat cursor`); `ydotool` would inject into the owner's session, so do not use it. A
  desktop run shows how far a game gets without input (dialogs, first-run pages, sign-in).
- **Processes.** Kill only your own process group by PID and `wineserver -k` with your
  `WINEPREFIX`; no `pkill -f`.
- **Disk.** Game copies and prefixes stay under `$PLAYPORT_BUILD/agent-notes/`; delete copies over
  a few GB when done unless they are reused.

## Reading what a stuck game waits for

- `WINEDEBUG=+msgbox,+reg,+file` (or narrower) for about 60 s around the moment: `+msgbox` catches
  only `MessageBox`; a custom dialog shows only on screen, so take a screenshot of `:0`.
- The probes just before the window name the check (registry keys, files read and their sizes).
- A/B the suspected input in the scratch prefix (JWE: the `-epicovt` file's content, the DRM's
  licence cache present or deleted) and keep a table of runs.
- Epic's requests through the proxy show the sign-in path: `grant_type=exchange_code` (the launch
  code is used), `deviceAuthorization` then `device_code` polling (AccountPortal: a browser page),
  `external_auth` / `users` (EOS Connect).
- Compare with the phone's `[sock-tl]` request sizes and order when the phone's TLS is opaque.

## After a finding

- File or update the game's Linear issue (AGENTS.md, "The phone"), with the desktop run as
  evidence and what the phone still needs.
- A fix in Playport is checked on the phone as usual; the desktop run is evidence of the cause,
  not of the fix.

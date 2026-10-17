# Debugging on the workstation

The phone is slow to iterate on: it shows the game's swapchain, not guest GDI windows, and
shares one device lock. Supported game URLs open in [Playport's web panel](decisions/0064-game-web-sheet.md),
not a general desktop browser. Desktop Wine/Proton can expose windows, requests and traces without
using the phone. **When a question is quicker to answer on the workstation, answer it there first**,
then fix and confirm on the phone:

- **What is the game waiting for or complaining about?** A dialog, a launcher or DRM check, a
  browser sign-in, a missing file or registry value.
- **Is it Playport or the game?** Matching desktop failure suggests a shared game, store or
  input issue; desktop success suggests a runtime or environment difference. Neither proves the
  cause: compare the game build/files, arguments, prefix state, credentials, network and graphics
  backend, and use controlled A/B runs to narrow the difference.
- **What does the game do on the network?** Which servers, which requests, which errors.
- **What does a file, argument or registry value need to look like?** A/B it in a scratch prefix
  instead of a build and an install per try.
- **Static questions:** a binary's imports, strings, packer, architecture, or a store's API reply,
  read with workstation tools.

The phone stays the judge: a desktop run supports a diagnosis, not verification of a phone fix.
Start with existing logs (`[win-text]`, `[msgbox]`) and the [dated cases](#cases), then use a bounded
static or desktop reproduction. Plan one relevant phone check plus the required
[regression gates](../AGENTS.md#test). If the target symptom does not reproduce, record the gap
rather than hunting unrelated titles or repeating speculative no-frame runs.

## Signs on the phone that point here

In a run's `pull/s1-host.log`:

- **Alive, no first frame:** CPU in `[thread-sample]`, black screenshots, no `first frame`. A small
  top-level window in `[win-pos]` (e.g. 550×146, centred) may be a dialog. Until the game's first
  frame Playport shows GDI windows (message boxes, a DRM's or launcher's error box, a setup page) on
  the phone, and `[guest-window]` lines say which and when ([decision 0075](decisions/0075-guest-windows-before-the-first-frame.md));
  after it the windows the game makes since (a message box, a dialog) are shown too, and the windows it
  had at its first frame are not ([0076](decisions/0076-guest-dialogs-over-a-running-game.md)): a dialog it
  made earlier and shows later stays hidden. Look for `[win-text]` with that `hwnd` or `root`: `kind=caption`
  is a top-level window's title, `kind=static` is a textual Static child's body (including a
  custom dialog that never calls MessageBox). Changed creation/update text is logged independently
  of geometry, bounded and escaped; Edit fields, non-text Static controls, message-only trees and
  owner-drawn text that never becomes window text are excluded. `[msgbox]` names standard
  MessageBox calls. See the [diagnostic's evidence and verification limits](evidence/2026-10-07-hidden-dialog-text.md).
  Guest captions/dialogs can contain private information: inspect and redact before sharing logs.
- **What ran just before:** DLL loads (`uxtheme.dll` comes with dialogs), file creates and their
  status (`c0000035` = exists), the same steps repeated (a check retrying).
- **A login or online feature failing with a generic error** (`UnexpectedError`, a timeout) and
  nothing else in the log: the game may want a browser page (`ShellExecute` of a URL), a launcher,
  or a file the store's launcher writes.
- **Strings in the executable** are a hint only: the message that matters may come from a DRM or a
  helper (Jurassic World Evolution's "Epic launcher is installed" string never showed; its DRM's
  error box did).

## The setup

Working copies belong under `$PLAYPORT_BUILD/agent-notes/`, uncommitted. The inventory below
is a **2026-10-07 snapshot** under `agent-notes/store-auth/`, not supported tooling or guaranteed
present files. Check availability in the authorized checkout before reuse; missing scripts are not
an instruction to recreate live store clients. Host-only side worktrees cannot run games, browsers
or phone commands or borrow this state ([0069](decisions/0069-host-only-worktrees.md)).

- **Game files:** scratch Linux builds of Playport's Epic/GOG installers (`eos/desktop/src`,
  `build`, copies of `app/EpicClient` + `app/ContentKit`) used an authorized workstation session.
  Steam files were pulled from the phone under its lock, or inspected via manifests.
- **Runners:** `eos/desktop/run.py`, `jwe-launcher/run.py`, `gog-desktop/run.py` and
  `gog-desktop/svc` used Proton 10 `waitforexitandrun`, scratch prefixes and Playport's launch
  arguments. Epic codes/tokens were freshly minted before launch; GOG used a stand-in or a Linux
  build of Playport's service. Each run cleaned up its own processes and scrubbed logs.
- **Agent browser:** `eos/desktop/agent-browser/` used its own profile and routed the prefix's
  URL opens there, not to the owner's browser (see [rules](#rules-the-owner-works-on-this-machine)).
- **Game-only HTTPS proxy:** `eos/desktop/mitm/` set `HTTPS_PROXY` for the game and installed
  its CA only in the scratch prefix. It kept scrubbed request summaries, no flows.

Keep workstation store sessions read-only: never refresh, write or print them. Launch codes and
per-game tokens may be minted only within the authorized task; keep them in memory, transient
child arguments or a 0600 file deleted after the run. Scrub arguments and requests before sharing.

## Rules (the owner works on this machine)

- **Display.** Run games, browsers and screenshots only on the authorized sway session, never
  the owner's niri session. Display/socket names are snapshots, not ownership checks: verify the
  session's ownership and availability before setting `DISPLAY` and `WAYLAND_DISPLAY` explicitly
  in each command (including `grim`); never inherit them blindly. If sway is unavailable, use an
  owned `xvfb-run -a` display where suitable (DXVK may not start; WineD3D can), or stop. Never fall
  back to niri. If a process lands there, terminate only that process by PID.
- **Screenshot recipe (sway).** The sway session is the process whose command line names
  `sway-nocap` (`ps -eo pid,args | grep '[s]way-nocap'`); its `SWAYSOCK` and its Wayland socket are
  in `/proc/<pid>/environ` (dated setup: `$XDG_RUNTIME_DIR/sway-sunshine.sock`, socket `wayland-1`;
  niri is `wayland-2`). A bare `grim` takes the inherited display, which may be niri, so name both:
  `XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-1 grim $PLAYPORT_BUILD/<dir>/desk.png`,
  and run the game with the same `WAYLAND_DISPLAY`/`DISPLAY` that its sway session gives (check
  `swaymsg -s $SWAYSOCK -t get_tree` lists the game's window). Confirm the file shows the game, not
  the owner's desktop, before keeping it. These names are a snapshot: re-read them each session.
- **Browser.** Nothing opens in the owner's browser. Route a prefix's URL opens to an authorized
  agent browser with its own profile (`WineBrowser`, `BROWSER`, an `xdg-open` shim first on `PATH`),
  or block them (`WINEDLLOVERRIDES=winebrowser.exe=d BROWSER=/bin/false`). New sign-ins, account
  linking or consent grants require explicit owner authorization for that client and scope;
  without it, stop and ask rather than approve the page.
- **Input.** In the dated setup, sway's headless seat did not pass synthetic input (wtype, XTEST,
  `swaymsg seat cursor`); `ydotool` would type into the owner's session, so do not use it. A
  desktop run shows how far a game gets without input. Input made inside the game's prefix
  does reach it: a Win32 program run there (`proton run`) that calls `SendInput` drove RDR2's
  menus and play, keyboard and relative mouse ([evidence](evidence/2026-10-17-rdr2-vulkan-needs.md#in-story-mode-2026-10-17-h1)).
- **Processes.** Kill only your own process group by PID and `wineserver -k` with your
  `WINEPREFIX`; no `pkill -f`.
- **Disk.** Game copies and prefixes stay under `$PLAYPORT_BUILD/agent-notes/`; delete copies
  over a few GB when done unless they are reused.

## Techniques

- **Traces:** `WINEDEBUG=+loaddll`, `+msgbox,+reg,+file`, or narrower, for a bounded interval
  around the moment. `+msgbox` catches only `MessageBox`; for a custom dialog check the phone's
  `[win-text]` first, then take a screenshot on the verified desktop display if still needed.
- **The probes just before a window** name the check: the registry keys and files read, and their
  sizes.
- **A/B in a scratch prefix**, with a table of runs: one changed input per run (a file's content,
  an argument, a cache present or deleted).
- **Requests through the proxy** show a sign-in's path (a launch code redeemed, a device-code
  browser flow, a token refused) and a server's error codes.
- **Compare with the phone:** DLL load order, request sizes and order (`[sock-tl]` on the phone),
  the point where the two diverge.

## Cases

These are dated findings, not current compatibility claims; follow the linked evidence for later
updates. Existing diagnostics may already answer the question without another desktop run.

| Date | Title | Phone symptom | Desktop finding |
| --- | --- | --- | --- |
| 2026-10-07 | Snakebird Complete (Epic) | EOS `UnexpectedError` | its login opens a browser page (device code); the phone then had no URL opener ([0064](decisions/0064-game-web-sheet.md)) |
| 2026-10-07 | Jurassic World Evolution (Epic) | alive, no frame, a hidden 550×146 window | the DRM's error box: the ownership-token file needed Epic's JSON reply, not the bare token ([evidence](evidence/2026-10-07-jwe.md), PLA-41) |
| 2026-10-07 | Moonscars (GOG) | the Galaxy SDK connects to the host's service, sends nothing, signs out (`GALAXY_SERVICE_NOT_AVAILABLE`) | the same files send `AUTH_INFO` at once and read Playport's reply (its listener built for Linux); no service registration needed; a probe of the SDK's socket calls works on the phone: cause not found here; found later, the next row ([evidence](evidence/2026-10-07-gog-galaxy.md)) |
| 2026-10-07 | Moonscars (GOG), PLA-55 | the Galaxy SDK connects, sends 0 bytes, closes after 15 s (`GALAXY_SERVICE_NOT_AVAILABLE`); one `[apc-nosignal]` on the SDK thread | an `LD_PRELOAD` shim in wineserver withholds SIGUSR1 from the SDK thread, and that reproduces the phone's host log exactly. ConnectEx completes only through a system APC on its thread, and the SDK polls its IOCP with timeout 0 and never enters a server wait. The SCM is consulted only after the 15-s failure. Fix: on iOS a zero-timeout `NtRemoveIoCompletion` selects (wine-unix 0018); the SDK then sends `AUTH_INFO` and gets the token, and its sign-in stops next (PLA-58, the next row) ([evidence](evidence/2026-10-07-gog-galaxy.md)) |
| 2026-10-07 | Moonscars (GOG), PLA-58 | the SDK gets its token (`AUTH_INFO -> 200`); a Schannel handshake completes; the game closes the service connection at once (`CONNECTION_FAILURE`), right after an `[nsi-ios] non-tcp module eb004a11` line | not secur32/lsass (Schannel is built in, and its handshake completed) and not TLS (desktop picks the same ChaCha20 suite). Right after AUTH_INFO the SDK calls `InternetGetConnectedState`, which Wine answers from `GetAdaptersAddresses`, and that fails on iOS (no `\\.\Nsi`, err 2). Desktop with a real game token signs in; with the nsiproxy service disabled it fails the same way 3 ms after the reply; a wininet shim that answers "LAN" signs in again with the NSI still gone (the SCM-dead run fails only because winedevice dies with it). Fix: wine-pe 0029; the phone then signs in ([evidence](evidence/2026-10-07-gog-galaxy.md)) |
| 2026-10-07 | Valheim (Steam), PLA-51 | c0000005 16 s after Play, right after Player.log's PlayFab login line; "jump to address 1" | not PlayFab. The intro video's Media Foundation worker makes a `MISC_SHARED` D3D11 texture on DXVK. With no `VK_KHR_external_memory_win32`, DXVK still calls `vkGetMemoryWin32HandleKHR`, which is NULL in Playport's winevulkan (a stub in Proton's). Found from the phone log (d3d11 rva 0x17f9f4, 4/4 plays) and a desktop A/B probe with the extension off. Fix: a `patches/dxvk` patch (on `vulkan-performance`); on DXMT it plays ([evidence](evidence/2026-10-07-steam-ticket-valheim.md)) |
| 2026-10-08 | Super Meat Boy (Epic), PLA-108 | alive, presenting at 60 Hz, textures loading, no error, black; its debug trace "stops" after 78 lines | the trace stop is Playport's own 80-exception log cap. The phone's game files under Proton render at the desktop's mode and in a 1280x720 virtual desktop, and show only black in any virtual desktop wider than 16:9 (1312x720 to 1600x720, the phone's 1564x720 included), with Proton's DXVK as with the IPA's DLLs. Fix: an aspect ratio setting and per-title compatibility defaults, 16:9 for this game (decisions 0072, 0073) ([evidence](evidence/2026-10-08-super-meat-boy.md)) |
| 2026-10-10 | Tomb Raider (Steam), PLA-150 | presents, picture black; UI glyph quads about 1000 times too large | the same files under Proton draw normal glyphs at 1564x720 too. gdb on the desktop and `FEX_TRACE_RIP` snapshots on the phone at the same addresses walked the glyph scale back to `SetViewport` width 1, an aspect of 0, and an empty monitor table: `EnumDisplayMonitors(GetDC(0))` listed no monitor because iOS never sized the thread-less desktop window in wineserver. Fix: madeira-unix 0108 ([evidence](evidence/2026-10-10-tomb-raider-draw-diagnostics.md)) |
| 2026-10-11 | House of Golf 2's prerequisites (WiX Burn), PLA-145 | `Failed to get signer chain from authenticode certificate` for every payload | the same installer under Proton verifies; deleting the prefix's `Cryptography\Providers\Trust` reproduces the phone's log exactly: wintrust's trust providers (and its OID decoders, and msisip's SIP for the MSI payload) are written by `DllRegisterServer`, which the app never ran. Fix: the seed carries them (decision 0078) ([evidence](evidence/2026-10-11-uepre-authenticode.md)) |
| 2026-10-11 | Castle Crashers Demo's DirectX June 2010 setup (Steam), PLA-170 | `CFusion::CFusion(): LoadLibraryShim() failed, error = 0x80070006`, DXSETUP -9 | under Proton the same `DXSETUP /silent` succeeds; deleting the prefix's `Microsoft.NET\Framework\v*\fusion.dll` links, or pointing its 32-bit `InstallRoot` at `Framework64\`, reproduces the phone's log exactly. Fix: the .NET Framework directories as links and a WoW64 `mscoree` reading `Framework\` (decision 0085); DXSETUP then stops at the x64 `infinst.exe`'s fixed base `0x100000000` ([evidence](evidence/2026-10-11-i386-dotnet.md)) |
| 2026-10-13 | BioShock (GOG), PLA-248 | c0000005 14 s after its first window, `[0+8]` in `Bioshock.exe`, with or without Visual C++ 2005 | Proton 10 with the files pulled from the phone reaches the main menu, with and without Creative's OpenAL. Static reading plus `FEX_TRACE_RIP` on the phone: FMOD's semaphore is a 0x14-byte `CreateFileMapping` + `MapViewOfFile`, and the view fails on the phone (`unaligned shared mapping … not supported`, a writable shared section under one 16 KiB host page), so FMOD's semaphores are 0 ([evidence](evidence/2026-10-13-gog-msvc2005-command-line.md)). A probe then showed only i386 views fail: the WoW64 window's view is whole host pages but was mapped with the section's size. Fix: madeira-unix 0135; the game reaches its menu scene ([evidence](evidence/2026-10-13-small-shared-sections.md)) |
| 2026-10-13 | Tomb Raider: Anniversary (GOG), PLA-249, PLA-252 | alive, no window at all (no `[win-text]`), black; one thread in a message wait after DXVK, `uxtheme.dll` and the builtin classes | with the files pulled from the phone the game shows its Rendering Setup dialog; a relay trace shows `DialogBoxParamW` owned by `GetDesktopWindow()`, and user32 disables the owner first: `EnableWindow(desktop, FALSE)` sends `WM_CANCELMODE`, which explorer's desktop thread answers. On the phone that thread is the session root's, which never read its queue. Fix: the session root answers messages sent to it while a title runs; the dialog shows and Ok starts the intro ([evidence](evidence/2026-10-13-desktop-window-messages.md)) |
| 2026-10-15 | Red Dead Redemption 2 (Steam), PLA-364 | `PlayRDR2.exe` shows "File not found." about 4 s after Play; `RDR2.exe` never starts | the phone's `PlayRDR2.exe` and `title.rgl` under Proton: with no `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Launcher\InstallFolder`, it runs `Redistributables\Rockstar-Games-Launcher.exe /s /t` from the working directory, and shell32's box says "File not found." when that file is missing. Desktop Steam ships the file in depot 1899671, which the phone's installer skipped (PLA-365) ([evidence](evidence/2026-10-15-rockstar-launcher-recon.md)) |
| 2026-10-18 | Red Dead Redemption 2 (Steam), PLA-401 | `Launcher.exe` executes a HLT (`c0000096`) about 0.2 s after its signed-in main window is `Active` | the owner's desktop play (real Steam) logs the same sequence and reaches `Begin game launch` 0.46 s after Auth → MainWindow; under Proton 10 with Playport's Steam client and no host, title setup fails before any sign-in (error 133, offline profile), and the phone's remembered Social Club profile does not import on another machine: not reproduced, inputs not separated ([evidence](evidence/2026-10-18-rockstar-desktop-comparison.md)) |

Add a row for each new case, and file or update the game's Linear issue (AGENTS.md, "The phone").

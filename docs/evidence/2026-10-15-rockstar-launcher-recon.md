# Rockstar Games Launcher on the workstation: Stage R reconnaissance

**Date:** 2026-10-15 (21:10–22:30). **Branch:** `dev/pla-291-rockstar-launcher`.
**Linear:** [PLA-291](https://linear.app/playportdev/issue/PLA-291) (Stage R, Rockstar only),
[PLA-254](https://linear.app/playportdev/issue/PLA-254), [PLA-364](https://linear.app/playportdev/issue/PLA-364)
(Red Dead Redemption 2 on the phone), [PLA-365](https://linear.app/playportdev/issue/PLA-365) (the
skipped Steam depot). **Plan:** [publisher launchers](../plans/2026-10-12-launchers.md).

Host only: no phone, no build, no sign-in, no game run. Sources are marked **[M]** measured here,
**[S]** read from the binaries here (strings, imports, PE headers), **[P]** public, with a link,
**[I]** inference.

## Setup

- Proton 10.0-4b (`proton run`) in a scratch prefix under `$PLAYPORT_BUILD/agent-notes/pla254-rockstar/`,
  windows on the sway session (`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`, set per command); the
  installer's clicks on an owned Xvfb display (sway's seat takes no synthetic input). URL opens
  blocked. Process snapshots every 5 s: Linux RSS and PSS (`smaps_rollup`), threads, full command
  line, sockets.
- The game folder is a stand-in: `C:\Games\Red Dead Redemption 2\` with the phone's
  `PlayRDR2.exe` and `title.rgl` (byte-identical to desktop Steam's, buildid 13773296), and the
  install script's `InstallFolderSteam` value, as on the phone. RDR2 itself was not run.
- The launcher's `steam_api64.dll` reached the workstation's running desktop Steam client through
  Proton's `lsteamclient` in one early run (about a minute). Every later run disabled
  `lsteamclient`/`steamclient` and stopped itself if a prefix process connected to that client.
- Measurement-only changes inside the scratch prefix, all undone: a wrapper in place of
  `SocialClubHelper.exe` that adds switches to the CEF browser's command line (R1), and a DLL
  override that keeps `RockstarService.exe` from loading (R4).
- Scaling: PSS is Linux memory under desktop Wine, not the phone's footprint. It shows relative
  cost and process count.

## Summary

| Item | Finding |
| --- | --- |
| Phone's "File not found." | `PlayRDR2.exe` reads `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Launcher\InstallFolder`. When that value is missing it runs `Redistributables\Rockstar-Games-Launcher.exe /s /t` (`runas`), relative to the working directory. That file is absent, so shell32's own error box appears. Reproduced exactly [M]. Desktop Steam ships that file in depot 1899671, which the phone's installer skipped (PLA-365) [M] |
| Installer | `Rockstar-Games-Launcher.exe` 1.0.109.3031, 111,419,512 B, sha256 `321886457b7e4ab727a27671c17a815684a3943579eedf7e2248a3b9f0973746`, from `https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe`. Authenticode valid: "Rockstar Games, Inc.", DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, timestamped 2026-09-01 [M]. Steam's copy is byte-identical [M] |
| Installer type | Rockstar's own x86-64 installer with its payload in PE resources. Not NSIS or MSI. It runs the VC++ 14.44 redistributables (WiX Burn, Windows Installer). Manifest `requireAdministrator` [S]. **`/s /t` is not silent:** language, Terms of Service checkbox, location, then Finished (about 15 s) [M] |
| Writes | `C:\Program Files\Rockstar Games\Launcher` (240 MB after the first self-update), `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Launcher` (InstallFolder, Version, Language…), an Uninstall key, the `rockstar://` protocol, shortcuts, and the service [M] |
| Service | "Rockstar Service" ("Rockstar Game Library Service"): own process, LocalSystem, **demand start**. `Launcher.exe` starts it through a `RockstarService.exe start` helper and the SCM. It repairs a disabled start type. Without it: three tries, then "Failed to connect to the Rockstar Games Library Service" (code 135), and **no sign-in page** [M]. No scheduled task seen [M] |
| Social Club | Installed by the launcher on first run, not by the installer: `Social-Club-Setup.exe /silent /forceinstall` (`runas`, 3 s) [M]. 2.4.0.240 in `Program Files\Rockstar Games\Social Club` (383 MB), plus a 32-bit `socialclub.dll` under `Program Files (x86)` [M] |
| CEF | `libcef.dll` 249 MB, **CEF 143.0.14, Chromium 143.0.7499.193** [S]. Loaded only by `SocialClubHelper.exe` processes, not by `Launcher.exe`, and not WebView2 [M] |
| Rendering | Off-screen rendering (`--off-screen-rendering-enabled`): `socialclub.dll` in `Launcher.exe` draws the UI into the launcher's own window with **D3D11** (DXVK swap chain 700×800 = the sign-in window) [M/I] |
| Process tree at the sign-in page | `Launcher.exe` (64 threads), service (9), crash handler (8), `LauncherPatcher.exe` (standalone start only), and 9 CEF processes: browser, GPU, network, storage, audio, video capture, and **3 renderers**. **About 4.4 GiB PSS and 330 threads on the Rockstar side**, flat over 5 minutes [M] |
| R1 | `--single-process` is accepted by CEF but the UI fails ("timed out loading both its online and offline content"). `--in-process-gpu`, `--disable-gpu --disable-gpu-compositing` (or the official `-scDisableGpu`) and `--js-flags=--jitless` work. One renderer (`--disable-site-isolation-trials`) breaks Rockstar's per-renderer IPC (code 161) [M] |
| Steam copies | In Steam mode the launcher calls `SteamAPI_Init` before the sign-in page. Without a Steam client: "Steam failed to initialize", no sign-in [M] |
| Offline | Never signed in and no network: no sign-in page, "timed out loading both its online and offline content" [M] |

## 1. How `PlayRDR2.exe` finds and starts the launcher

`PlayRDR2.exe` is "Rockstar Games Launcher Redirector" 1.0.0.69 (`RockstarRedirector.exe`), x64,
`asInvoker`, Authenticode valid [S].

1. It reads `title.rgl` (1,536 B, an `RGLM` header and encrypted metadata) from its folder [M].
   The metadata fields are `titleId`, `rosTitleId`, `minRglVersion`, `steamInstallerPath`,
   `steamAppIds` and `epic*` [S].
2. `RegGetValueW(HKEY_LOCAL_MACHINE, "SOFTWARE\WOW6432Node\Rockstar Games\Launcher",
   "InstallFolder")` [M]. It names the 32-bit view explicitly and reads no other launcher value.
3. When the value is missing, it calls `ShellExecuteExW("runas",
   "Redistributables\Rockstar-Games-Launcher.exe", "/s /t")` and waits [M]. The path is relative
   to the **current directory**. When the file is missing, shell32's own message box follows:
   "File not found." when the working directory is the game folder (as on the phone), "Path not
   found." otherwise [M].
4. When the value is found, it calls `ShellExecuteExW("open", "<InstallFolder>\Launcher.exe",
   "-skipPatcherCheck -steamAppId=1174180 -steamLocation \"<game folder>\" <its own arguments>
   @args.txt")` [M]. The app id comes from the `SteamAppId` environment variable when it is set,
   otherwise from `title.rgl` [S].

Flags [M/S]:

- `-forceLauncherPath <path>`: the path of the launcher **executable**, opened as given. It
  also re-runs the `Redistributables` installer first.
- `-skipInstallers`: skips that installer step. With the launcher registered, no installer runs
  anyway.
- `-launchDirectly`: opens `<game folder>\RDR2.exe` with the same arguments, without the
  launcher.
- Others: `-forceTargetPath`, `-stub_log`, `-skipPrereleaseCheck`, `-rlrosDomainEnv=`,
  `-uninstall`, test flags.

It also knows `Redistributables\Rockstar-Games-Epic.exe` and `-epicAppId=` for Epic copies [S].

**Does a Steam copy ship the installer?** Yes [M]. Desktop Steam installs depot 1899671 (a
shared install from app 1899670) into the game folder:

- `Redistributables/Rockstar-Games-Launcher.exe`, identical to the publisher download;
- `Redistributables/Social-Club-Setup.exe` (sha256 `082a5034…0293db0ee`, Authenticode valid,
  identical to the launcher's bundled copy);
- `installscript_sdk.vdf`, which runs `Social-Club-Setup.exe /silent` and
  `Rockstar-Games-Launcher.exe /s /t`.

Playport's Steam installer skipped that depot (PLA-365). So a Steam copy gets the genuine
installers from Steam, and nothing has to be downloaded from Rockstar. Because `/s /t` shows
pages, the first install still needs a person to accept the Terms of Service and press Continue.

## 2. Install

Registry written [M]:

- `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Launcher`: `InstallFolder`, `Language`, `RGL`,
  `Shortcut`, `Silent`, `Version`;
- `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Rockstar Games Launcher`,
  with `QuietUninstallString` `uninstall.exe /S`;
- `HKCR\rockstar\shell\open\command`: `Launcher.exe "%1"`;
- `HKCU\Software\Rockstar Games\Launcher\ConfigGuid`;
- `HKLM\System\CurrentControlSet\Services\Rockstar Service`;
- from the Social Club setup: `HKLM\SOFTWARE\WOW6432Node\Rockstar Games\Rockstar Games Social
  Club` and a Vulkan explicit layer entry (`SocialClubVulkanLayer.json`, value 0).

Files written [M]:

- `Launcher\`: `Launcher.exe` (29.9 MB), `LauncherPatcher.exe`, `RockstarService.exe`,
  `RockstarSteamHelper.exe`, `uninstall.exe`, `Launcher.rpf`, `offline.pak`;
- `ThirdParty\`: Steam `steam_api64.dll`, Epic EOS SDK, Crashpad `RockstarErrorHandler.exe`,
  D3D12 Agility SDK;
- `Redistributables\`: VC++ redistributables and the Social Club setup;
- a private ucrt.

Elevation: the installer's `requireAdministrator`, PlayRDR2's `runas` and the Social Club setup's
`runas` all complete with no prompt under Wine [M] (R8).

## 3. The running launcher

Process tree at the sign-in page (standalone start, idle 5 minutes) [M]:

| Process | Role | Threads | PSS (MiB) |
| --- | --- | --- | --- |
| `LauncherPatcher.exe` | self-update gate (standalone start only; stays alive) | 1 | 15 |
| `Launcher.exe` | UI host: `socialclub.dll`, D3D11/D2D/DWrite, `steam_api64` | 64 | 185 |
| `RockstarErrorHandler.exe` | crashpad | 8 | 16 |
| `RockstarService.exe` | service (through the SCM) | 9 | 20 |
| `SocialClubHelper.exe` | CEF browser | 52 | 381 |
| ` --type=gpu-process` | | 54 | 464 |
| ` --type=utility` network, storage, audio, video_capture | | 19, 10, 11, 10 | 301, 288, 286, 286 |
| ` --type=renderer` ×3 | one per off-screen page | 30, 30, 34 | 726, 725, 698 |
| **Rockstar side** | 13 processes | **332** | **4,399** |

The Steam-mode chain (`PlayRDR2.exe` → `Launcher.exe` with `-steamAppId`) has the same tree
without `LauncherPatcher.exe` (4,413 MiB, 334 threads) [M].

`libcef.dll` (FileAlignment 0x200) is loaded as private anonymous memory in each CEF process
under Wine. That is why even a utility process costs about 285 MiB [M]. On the phone a pure
x86-64 image gets no JIT-pool copy (ARCHITECTURE, "JIT pool use"), so the cost there is memory
footprint and FEX translation per process, not pool head [I].

The browser's command line is built by `socialclub.dll` [M]:
`--off-screen-rendering-enabled --do-not-de-elevate --disable-extensions … --rgsc-ipc-channel-name=rgsc_ipc_<pid>_channel_0`.
Its children carry `--no-sandbox` (set by Rockstar) and the user agent
`Chrome/143.0.7499.193 RockstarGames/2.4.0.240/1.0.109.3031/launcher[/Steam]`.

IPC (R5) [M]:

- named pipes `MTLLauncher_Pipe`/`MTLService_Pipe` (launcher ↔ service);
- `chrome.rgsc_ipc_<pid>_channel_N` (one per CEF page/renderer);
- `chrome.rgsc_gameinst_0` (a game-instance channel the launcher serves), and a client attempt on
  `rgsc_launcher_0`;
- Chromium's mojo pipes, crashpad pipes, `svcctl`, and COM over rpcss (`lrpc\OLE_*`, epmapper);
- shared memory: the service hands the launcher a 2 MiB and a 400 MiB section (download buffers);
- no loopback TCP of its own (the only loopback connection was `steam_api64` to a Steam client).

Network (R6) [M]:

- `Launcher.exe` uses its own HTTP over ws2_32 with crypt32/bcrypt [S]:
  - `gamedownloads.rockstargames.com` and its Akamai host (`launcher_online_config.xml`,
    `prelauncher2.ini`);
  - `rgl-prod.ros.rockstargames.com/launcher/11/LauncherServices/App.asmx/…` (`GetDefaultApps`,
    `GetBuildManifestFullNoAuth`, `RetrieveFileChunkNoAuthMulti`).
- CEF's network service: `rgl.rockstargames.com/launcher` (the UI), plus Rockstar, Akamai,
  Cloudflare and Google hosts, including Google's port 5228 push service [M] (hosts named by
  reverse DNS; their roles are [I]).
- `LauncherPatcher.exe` uses WinHTTP [S].
- TLS completed everywhere under Proton.

Updates (R7) [M]:

1. The first run found 148 MB of launcher chunks to fetch.
2. The **service** wrote them into `Launcher\swap\` and moved them into place.
3. The launcher restarted itself as a new process with `-upgrade` (a second launcher generation),
   then installed Social Club as a prerequisite.

A standalone start passes through `LauncherPatcher.exe`, which checks minimum versions in
`prelauncher2.ini`. The service stops 30 s after the launcher's pipe closes.

Log tokens for the Redactor (PLA-272): the launcher log carries a per-run
`BRANCHACCESS token="…",signature="…"`, and the crash handler's command line carries an upload
token [M]. No account was used.

## 4. R1 switches

The only official switch is `-scDisableGpu` on `Launcher.exe` (or in
`commandline_launcher.txt`), which `socialclub.dll` turns into `--disable-gpu
--disable-gpu-compositing` [M/S]. Every other switch needs the browser's command line changed at
process creation, which is R1's runtime policy. A wrapper did that here [M]:

| Browser switches added | CEF processes | Rockstar PSS (MiB) | Threads | Sign-in page |
| --- | --- | --- | --- | --- |
| none | 9 | 4,392 | 326 | yes |
| `--single-process` | 1 | 1,110 | 171 | **no**: SC_INIT_ERR_WEBSITE_FAILED_LOAD (17) |
| `--in-process-gpu` | 8 | 4,076 | 314 | yes |
| `--disable-gpu --disable-gpu-compositing` | 9 (GPU process with 19 threads) | 4,339 | 295 | yes |
| `--js-flags=--jitless` | 9 (passed to the renderers) | 4,380 | 325 | yes |
| `--renderer-process-limit=1` | 9 (still 3 renderers) | 4,399 | 325 | yes, no effect |
| R1's full set with `--single-process` | 1 | 1,075 | 153 | no (same error) |
| R1 fallback with `--disable-site-isolation-trials` | 6 (1 renderer) | 2,738 | 225 | **no**: "Connection to UI renderer lost", code 161 |
| `--in-process-gpu --disable-gpu --disable-gpu-compositing --js-flags=--jitless` (+ `NetworkServiceInProcess`, `--disable-breakpad`) | 8 | 3,983 | 284 | **yes**, stable for 5 min |

`--no-sandbox` is already on. `--enable-features=NetworkServiceInProcess` did not remove the
network process. Rockstar's IPC needs one renderer process per off-screen page, so this launcher
cannot be brought below about 8 CEF processes with switches that keep it working [M].

## 5. Offline and the hand-off

- **Steam mode needs a Steam client before anything else** [M/S]. `Launcher.exe` calls
  `SteamAPI_Init` (`SteamUser022`, `STEAMAPPS_INTERFACE_VERSION008`, `SteamAPI_RestartAppIfNecessary`)
  through its own `ThirdParty\Steam\steam_api64.dll`. With no client it shows "Steam failed to
  initialize. Please verify that the Steam Client is running and try again."
  (LAUNCHER_ERR_STEAM_FAILED, 113), and no sign-in page.
- **Offline before any sign-in** shows no sign-in page: "The Rockstar Games Launcher timed out
  loading both its online and offline content" within about a second [M].
- The launcher's arguments include `-scOfflineOnly`, `-steamAppId`, `-steamLocation`, `-useSteam`,
  `-useEpic`, `-epicAppId`, `-fromRGL`, `-minmodeApp`, `-upgrade`, `-netDisableServiceUrls`,
  `-scEnableGameIpcVerification` [S]. Its strings include "Game launch is in offline mode",
  "Aborting launch due to being unable to auto sign in to offline profile!", "Restarting
  automatically in offline mode due to no internet", `autosignin.dat` and `OfflinePlayTime` [S].
- **Not determinable without the owner's sign-in and the game:**
  - the arguments the launcher gives `RDR2.exe`;
  - how the Steam entitlement is checked;
  - `-scOfflineOnly` in practice and how long offline lasts;
  - which processes stay alive during play, and their traffic with the game.
- **"Hibernate while game is running"** is not a user-setting string in `Launcher.exe`,
  `socialclub.dll` or the UI script cached so far [S]. `socialclub.dll` does have internal UI
  hibernation ("Hibernating the user interface", "Waking the user interface from hibernation",
  `HibernationData` in the UI's script) [S]. What it does during play is for the in-game phase.

## 6. Proton

Proton 10's Rockstar-specific handling [S]:

- `noopwr` for RDR2, GTA V and other Rockstar app ids, because of login text-input delays on
  Wayland;
- an unmanaged-popup rule for `SocialClubHelper.exe` in winex11, which Playport does not use;
- `sigsys_handler_rdr2` in its ntdll, on the game side;
- no command-line rule for `SocialClubHelper.exe` or `Launcher.exe` in kernelbase's
  `hack_append_command_line`.

`patches/wine-valve` carries nothing Rockstar-specific.

## Answers to the plan's *(verify)* items

- `RockstarService.exe` is the Rockstar Game Library Service: demand start, LocalSystem. It
  installs, updates (it writes the update files), fixes folder permissions, and is **required**
  for the UI [M].
- Social Club's CEF host is `SocialClubHelper.exe`. It is started by `socialclub.dll` inside
  `Launcher.exe` (and, per the plan, inside the game). There is no separate `subprocess.exe` [M].
- Offline needs a prior online sign-in: no sign-in page at all offline without one [M]. The time
  limit was not determined.
- Steam copies start the launcher (measured); Epic copies use `-epicAppId` and an Epic installer
  name [S]. Epic account linking was not determined.

## Not determined, and why

- The launcher in Steam mode beyond the Steam check, the hand-off to `RDR2.exe`, the game's
  `socialclub.dll` CEF instance, and processes alive during play. These need the owner's online
  sign-in in person, and a Steam client for the launcher's `steam_api64`. On the workstation the
  only Steam client is the owner's running desktop Steam, which this run did not use.
- A non-interactive install switch for the installer: "Silent install mode" exists in its strings,
  but the switch was not found.
- The phone's figures: everything above is desktop Linux memory.

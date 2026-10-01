# Kingdom Come: Deliverance starts: the system environment, and avifil32

**Date:** 2026-10-01. **Phone:** iPhone18,4, iOS 27.0. **Branch:** `kcd`.
**Title:** Kingdom Come: Deliverance (Steam app 379430), CryEngine, DXMT
(Direct3D 11, feature level 11_0), the Steam API emulator in place of its
`steam_api64.dll`. Installed from Steam through the app: depots 379432 and
379433, 121 files, 64.2 GB.

**IPA** (dev): `Playport-26.5-dae42043.ipa`, sha256
`dae42043833cd61c3ddbeab2f3245a7d0c675994b10538705985076c75815617`.

## Where it stood

On `main` (IPA `1632e70a…`) the game ended 0.4 s after Play with exit code
`0x12f`. Its launcher log (`Bin\Win64\kcd_launcher.log`):

```
Adding 'C:\Games\KingdomComeDeliverance\Bin\Win64Shared' to path...
ERROR: GetEnvironmentVariableW() failed
ERROR: The path to shared DLLs can't be set
Loading 'fmod64.dll' ...
Error: The library 'fmod64.dll' can't be loaded
...
ERROR: Failed to load the Game DLL WHGame
```

`KingdomCome.exe` keeps its third-party DLLs (fmod, steam_api64, amd_ags and
others) in `Bin\Win64Shared` and puts that folder in front of `PATH` before
it loads `WHGame.dll`. The guest had no `PATH` at all. The app never runs
wineboot, so the prefix's `system.reg` had no
`System\CurrentControlSet\Control\Session Manager\Environment` key. wine.inf
writes that key (`PATH`, `ComSpec`, `PATHEXT`, `TEMP`, `TMP`, `windir`,
`winsysdir`, `OS`), and ntdll's `add_registry_environment` reads it into
every process's environment.

## 1. The system environment in the registry seed

`app/tools/prefix-registry.py` now seeds that key with wine.inf's values
(`loader/wine.inf.in` at the wine pin). The key is marked for top-up, so a
prefix that already exists gets it at its next launch
(`registry system.reg: 1 of 1624 seed keys added`). `wine_host.c` creates
`C:\windows\temp`, which `TEMP` and `TMP` name. Next run:

```
New path is 'C:\Games\KingdomComeDeliverance\Bin\Win64Shared;C:\windows\system32;C:\windows;...'
Loading 'fmod64.dll' ...            (all 13 load)
ERROR: Failed to load the Game DLL WHGame
```

## 2. avifil32 and msvfw32

`WHGame.dll` imports `AVIFIL32.dll`, which the runtime did not ship
(`import_dll Library AVIFIL32.dll ... not found`). `build/stages/stage-artifacts.py`
now stages `avifil32.dll` and its one import that was missing,
`msvfw32.dll`, from the arm64ec Wine build, and `pp registry` adds their COM
registrations. After that no import is missing: every import of
`KingdomCome.exe`, `WHGame.dll` and the `Win64Shared` DLLs is either
staged or shipped with the game.

## Result

`pp ui --play app-379430 --until first-frame+30`: the first frame came at
+26 s (the CryEngine loading emblem) and the game ran on. In a second run,
at about 2 min, a loading screen showed at 58.5 fps (Metal HUD:
1564x720, GPU 3.55 ms, app footprint 7.59 GB, 995 MB available). The game
reached its menus. A person played it at the phone and quit from its menu at
236 s (`Quit requested by CUIGameEvents::OnExitGame()`, exit code 0).

Still open: loading takes long, and in-game performance is poor (the
person's report; not yet measured). The game's online service (`PROS`)
fails Steam token validation under the emulator and retries without end.
The game plays without it.

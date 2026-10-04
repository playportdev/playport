# Portal 2 milestone 3: the default backend, the pad and gameplay

## Result

- **Default backend** ([decision 0047](../decisions/0047-i386-titles-on-vulkan.md)).
  An i386 executable now defaults to Vulkan. Portal 2 reaches its main menu with no
  `--settings`, and its Game options show `Direct3D: Default · Vulkan`.
- **The pad reaches Portal 2.** The scripted pad drives the menus and the game. A
  chapter 1 start and a chapter 2 test chamber with the portal gun were played with it.
- **QUIT** from the main menu with 11 secondary threads still alive: the child exits
  with code 0, the window is retired, the app restarts (decision 0029), and there is no
  crash.
- **Gameplay frame time**, in Chapter 2's first test chamber at 1564x720 capped at 60:
  59.6 FPS, 16.78 ms per frame and 13.0 ms of GPU time. The GPU time rises to 15.2 ms
  in the last 70 s. 8 window faults were serviced.

IPA: `.work/out/20261004-095835-b455cb03/Playport-26.5-b455cb03.ipa` (dev). SHA256:
`b455cb03bcb6ff7e3aaaad7c503388951fe5929fc7487f2579cdff5b50877eba`. `pp build` passes
its 79 IPA checks. Battery was 83 to 80%, not charging.

## Default backend

`Adoption.scan` records the selected executable's COFF machine
(`InstalledTitle.executableMachine`, read with `SteamAPISwap.peMachine`). With no game
or global choice, `LaunchSettings.resolve` gives Vulkan when that machine is `0x14c`,
whatever the launch arguments say. The Direct3D picker's note says why. The machine is
used rather than Direct3D 9 evidence because 0046's scan of `portal2.exe` finds none:
the launch log has `Direct3D evidence for app-620: Unknown, modules=1`, since the
engine loads `shaderapidx9.dll` by path. Tests: `Direct3D12Tests.testI386DefaultAndExplicitOverrides`
and `CatalogTests.testAdoptionRecordsTheExecutableMachine`.

On the phone:

- `.work/ui-runs/p2m3-page2`: `open:app-620`, then `pad:x` and `pad:down` to the
  Direct3D row. The row reads `Default · Vulkan`, and the game has no settings of its own
  (`settings app-620 {}`).
- `.work/ui-runs/p2m3-1`: `pp ui --play app-620 --pad` with no `--settings`. The log has
  `library: play Portal 2 (app-620) on vulkan`. A screenshot at about 40 s shows the
  main menu, with PLAY SINGLE PLAYER selected.

## Why the pad did not reach an i386 title

The milestone-2 logs map two copies of XInput:

```text
i386 image C:\windows\system32\XINPUT1_3.dll at 7a0b0000      (steam_api's import)
i386 image c:\games\portal 2\bin\XInput1_3.dll at 77ff0000    (inputsystem.dll)
```

Portal 2's `inputsystem.dll` loads `bin\XInput1_3.dll` by its full path. That is
Microsoft's XInput, which looks for pads through SetupAPI and HID, and there is no
winebus in this process. wine-pe 0007 sends XInput DLLs to system32, whose builtin reads
the host snapshot through `NtUserGetGamepadState`, but it did so only for a load by
base name. **wine-pe 0026** adds loads by path: when the file name is one of the five
XInput DLLs, the system32 copy is opened. `open_dll_file` then returns the module
already loaded from system32. The thunk path (`wow64win`'s `GetGamepadState`, converted
in wine-pe 0018) was already correct.

With 0026 only the system32 copy is mapped. A DOWN press on the menu moves the
selection, and the game shows its controller glyphs ("A Select", "B Back"). Wine's
builtin still starts its idle `wine_xinput_hid_update` thread once. It waits in the
server, and the host path answers the pad queries.

## Gameplay, by pad

All of these were in one session after `p2m3-1`, with `pp pad send … --shot`
(screenshots in `.work/p2m3/`):

1. DOWN, then UP: the main-menu selection moves. A opens SINGLE PLAYER (CONTINUE GAME,
   NEW GAME, LOAD GAME, CHALLENGE MODE, DEVELOPER COMMENTARY). DOWN and A open NEW
   GAME's chapter list on "The Courtesy Call".
2. A: a white load screen, then the relaxation vault (bed, desk, the window blinds)
   with the "LOOK UP" hint.
3. `RY=1`, `RY=-1` and `LY=1`: the view turns to the ceiling, and the hint advances to
   "LOOK DOWN".
4. START: the pause menu (RETURN TO GAME, SAVE GAME greyed out, LOAD LAST SAVE, OPTIONS,
   EXIT TO MAIN MENU). DOWN x3, A, then A on "Exit To Main Menu?" returns to the main
   menu with a different background scene.
5. `tools/pad/p2-quit` steps: DOWN x5 to QUIT, A ("Are you sure you want to quit?"), A.

Scripts added in `tools/pad/`: `p2-new-game` (to chapter 1 and the vault tutorial),
`p2-cold-boot` (to chapter 2), `p2-walk` (turn and walk on a loop) and `p2-quit`.

## QUIT with live threads

From the session's log (`.work/phone/20261004T101150/s1-host.log`; the game ran for
573 s):

```text
i386 NtTerminateProcess( 00000000, 00000000 )
i386 NtTerminateProcess( ffffffff, 00000000 )
[wow64-window] release peb=0x125198000 base=0x7038010000 serviced_low_faults=191 live_threads=11
[wow64-pair] restored owner=0x125198000 native=0x124e87000 tls_match=1
[wow64-window] retired base=0x7038010000: 11 secondary thread(s) left; the last one's reclamation tears it down
[jit-pool] RECLAIM peb=0x125198000: 5 ranges 0x674000 bytes freed (grace 3s), ...
[Wine child thread] child exited with code 0
session: title 1: ended, exit code 0 after 573423 ms
restart: new process pid 25821, 403 ms after pid 25759 asked
```

The child created 31 secondary threads and 8 were reclaimed. No i386 exception was
logged, and `pp phone crashes` lists none. This is madeira-unix 0073's retire path,
seen on the phone for the first time. The app restarted before any of the 11 threads
was reclaimed, so the retired window's final teardown did not run on the phone. The
restart ends the process anyway.

## Measured

`pp perf --title app-620 --secs 180 --pad first-frame+30:p2-cold-boot --pad
first-frame+75:p2-walk` (`.work/perf-runs/p2m3-cold-boot`), default settings (720p, 60
FPS limit, Vulkan by default), thermal nominal:

| Window (s after first frame) | FPS mean | Frame ms | GPU ms | Note |
| --- | --- | --- | --- | --- |
| 0–35, menu | 60.0 | 16.7 | 3.6–4.9 | as milestone 2 |
| 40–60, chapter load | 22–52 | — | — | loading hitches up to 713 ms |
| 65–180, test chamber | 59.6 | 16.78 | 13.0 (15.2 from 110 s) | hitches 596 ms at 87 s, 200 ms at 78 s |

In play, the process uses about 115% CPU (P cores about 70%, E cores about 45%), and
GPU utilisation is 95% from 110 s on. At 15 ms of a 16.7 ms frame, the GPU is the
nearer limit at 720p. Screenshots at first-frame+70, +120 and +170 show the chamber,
the portal gun and the "Create Blue Portal" hint. The Metal HUD reads 58.8–60.0 FPS. The
hint shows a mouse glyph, not a pad button.

Faults: 8 serviced window accesses (the known native reads of the i386 ntdll image), and
one refused native read of guest `0x370` (open since milestone 2). There is no guest
exception and no unaudited win32u call.

## Open

- No audio: the null driver has no WoW64 table (madeira-unix 0072 gives an i386 child
  none).
- The in-game hints show keyboard and mouse glyphs while the menus show pad glyphs.
- GPU time in a chamber is 13–15 ms at 720p, 60 FPS capped. Native resolution or an
  uncapped rate would be GPU-bound.
- Save and reload, and a full chamber solved with portals, have not been tried.
- A retired window's final teardown on the phone has not been seen (see QUIT).

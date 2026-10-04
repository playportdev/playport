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

## On the committed IPA

Commit `479647c` builds IPA `.work/out/20261004-102212-f817a530/Playport-26.5-f817a530.ipa`
(SHA256 `f817a5307352269de45151125a2d48879d3401837098492f9d7111fbad708ac4`). Its
artifacts are the same as `b455cb03`'s; only the app's provenance differs. It was
installed and run in one session (battery 76%):

- **Hollow Knight** (`.work/ui-runs/p2m3-hk`, on DXMT) passes `first-frame+10`, with
  the first frame at 8.67 s. The screenshot shows the main menu.
- **Portal 2** (`.work/ui-runs/p2m3-2`, no settings) logs `on vulkan` and reaches the
  menu. DOWN moves the selection to PLAY COOPERATIVE GAME. UP, then `pp pad push
  p2-quit`, quits. The game exits with code 0 after 295 s. This time every secondary
  thread had exited first (`release … serviced_low_faults=188 live_threads=0`), so the
  window was released at once rather than retired. The app restarts, and there are no
  crashes (`.work/phone/20261004T102907/s1-host.log`).

## Audio, resolvers and fonts

Commits `9f2105b` (madeira-unix 0074, wine-unix 0013, their host tests in
`build/wow64/test.py`) and `abd0b38` (the Tahoma fallback faces) build IPA
`.work/out/20261004-111031-ba34b2e0/Playport-26.5-ba34b2e0.ipa` (dev, SHA256
`ba34b2e01381c3980ce61135a6c74e6cd1ac405ec556b8ad73d90823650ce82c`, 78 IPA checks;
the notices are `unreviewed-app-selection`, see below). Installed in place, battery
59–76%:

- **Audio.** Portal 2's i386 mmdevapi gets the iOS driver's WoW64 table
  (`MemoryWineLoadUnixLibByNameWow64 winepulse.drv -> iOS audio table`), and
  `create_stream by 'portal2.exe'` (0xfffe, 2 ch, 48000 Hz, 32-bit float) is followed by
  `RemoteIO ENDPOINT ready`, `start`, and `ml1065` level lines with sound in them (about
  870,000 samples a period, mean |x| 0.02–0.07, peak up to 0.75, no clipping;
  `.work/p2m3c/s1-host.log`). The MMDevices Render key was written during that run
  (no other process loads mmdevapi), so the i386 view sees it; the prefix has no
  `Software\Wow6432Node` to redirect it.
- **Fonts.** `fonts: 2 links` before each session; `select_font can't find a single
  appropriate font` occurs 0 times (311 in `.work/phone/20261004T102907`). The faces are
  Wine's tracked prebuilts under the Bitstream Vera licence with their SFD attribution.
  They came after the owner's licensing review, so `build/app-notices.json` is
  `unreviewed` with them as its open question: **they need review under
  [DISTRIBUTION.md](../DISTRIBUTION.md) before an IPA is given to anyone.**
- **Resolvers.** wine-unix 0013 is checked by its host test (packed addrinfo and hostent
  round trips, bounds, NULL, sizing, all five thunks); Portal 2's single-player play did
  not exercise it on the phone.
- **Hollow Knight** (`.work/ui-runs/20261004T111132`, this IPA) passes `first-frame+10`,
  first frame at 10.92 s, main menu on the screenshot, and its stream still carries sound
  (`create_stream by 'hollow_knight.exe'`, mean |x| 0.044, peak 0.51).

## Save, reload and the portal gun

- **Save and reload** by pad: START, SAVE GAME, New Saved Game Slot writes
  `portal2/SAVE/<account>/1791103990.sav` (LOAD GAME lists it first as "Sunday, Oct 4
  8:53 AM", Chapter 2 – The Cold Boot, with its thumbnail). EXIT TO MAIN MENU, then PLAY
  SINGLE PLAYER, LOAD GAME and A load it back into the chamber. `tools/pad/p2-save-load`
  does the whole sequence; run once after `p2-cold-boot` (`.work/p2m3d`), it wrote
  `1791105527.sav` and ended back in the level.
- **Firing a portal: not confirmed.** RT (bound `R_TRIGGER +attack`; `joystick 1`,
  `joy_name "Xbox360 controller"`) held at the arrival room's walls and floor left both
  halves of the crosshair empty and the hint up. The surfaces aimed at may not be
  portalable, and no shot shows a projectile, so whether the trigger reaches `+attack`
  is still open. XInput's host path (wine-port 0055) copies both triggers.
- **Hint glyphs** follow the last device the engine saw: the chapter start shows the
  mouse glyph, and after one load from the menu by pad the hint showed `RT`. No cvar was
  changed.

## Open

- Whether RT fires the portal gun (see above): aim at a known portalable panel in the
  chamber past the arrival room, or watch `+attack` with a bind that logs.
- The in-game hints' glyph depends on the last device used, not on a setting.
- GPU time in a chamber is 13–15 ms at 720p, 60 FPS capped. Native resolution or an
  uncapped rate would be GPU-bound.
- The fallback fonts' distribution review (above).
- A retired window's final teardown on the phone has not been seen (see QUIT).

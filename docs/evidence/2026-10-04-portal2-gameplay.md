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
- **Firing a portal: confirmed below** (RT and LT, in the chamber past the stairs).
- **Hint glyphs** follow the last device the engine saw: the chapter start shows the
  mouse glyph, and after one load from the menu by pad the hint showed `RT`. No cvar was
  changed.

## Portals, loose ends and settings

The loose ends are fixed by wine-pe 0027 and madeira-unix 0075 and 0076. They build
IPA `.work/out/20261004-122618-05dcdeb7/Playport-26.5-05dcdeb7.ipa` (dev, SHA256
`05dcdeb7d8be116028d747b914b18aaaa5e0c6da0ac2d48581f2e49b699015b5`, 78 IPA checks).
Battery was 41 to 33%, not charging.

- **The portal gun fires** on `ba34b2e0`, in `sp_a2_laser_intro` (the map
  `p2-cold-boot` loads). Screenshots are in `.work/p2m3e/`.
  - RT puts a blue portal on the white panel under the laser emitter (`portal-blue.png`).
  - LT puts an orange portal on the lit panel above the exit (`portal-both.png`).
  - The bindings work as shipped: `config.cfg` has `R_TRIGGER +attack` and
    `L_TRIGGER +attack2` after its `unbindall`. No joystick change was needed.
  - The earlier misses were at walls that cannot take a portal.
  - **The chamber was not solved by script.** A replay script of the walk and turns
    was tried from a fresh launch, but dead-reckoned turns land differently each run.
    It was not kept.
- **wine-pe 0027** keeps win32u's inline-string marker (`0xffffffff`) in
  `lpszName`/`lpszClass` when `packed_message_64to32` converts a WM_CREATE or
  WM_NCCREATE. `wow64_to_guest` still rejects it everywhere else. Its host test is
  `build/wow64/packed_createstruct_test.c` ("packed CREATESTRUCT: ok"). It covers:
  - the marker;
  - atoms and NULL;
  - pointers inside and outside the window;
  - conversion in place.
- **madeira-unix 0075** sends a native `[x18, #imm]` TEB read straight to the x18
  emulation instead of the window's low-fault lookup. The read is a data fault below
  0x10000 with x18 == 0, whose base register is x18. Any other low fault is still
  routed and refused.
  - On the phone, the `subfloor ... REFUSED read of 8 byte(s): guest 0x370` line went
    from 1 to 0 per launch.
  - `x18-emul3` stays at 20.
  - Not host-tested: the check is inline in the Mach handler.
- **madeira-unix 0076** runs the pool warmer's slot, window and physical-map
  censuses at cycles 1 and 2, then every 150th cycle (about 5 min). Before, they ran
  every 15th and 5th. Page warming is unchanged.
  - Same `pp perf` as above, 180 s: `.work/perf-runs/p2m3e-before` on `ba34b2e0`,
    `p2m3e-after` on `05dcdeb7`.
  - `[phys-map]` walks fell from 19 to 1.
  - In the chamber (55–180 s), both runs had 16.67 ms per frame and 14.3/14.4 ms of
    GPU time. Each had one frame of 30 ms or more: 42 ms before, 54 ms after.
  - The 596 ms hitch of `p2m3-cold-boot` did not recur in either run, so the fix
    removes the census's cost but cannot be shown to remove that hitch.
- **Hollow Knight first frame.** 10.92 s (`20261004T111132`) was an outlier, not a
  regression.
  - The same IPA gave 9.75 and 9.98 s (`.work/p2m3e/hk-before-*`).
  - `05dcdeb7` gave 9.61, 9.67 and 8.46 s (`hk-after-*`), each with the main menu on
    its screenshot.
  - The last 24 recorded plays range from 8.26 to 10.11 s.
  - The font links and the audio table add no gap. The only pause over 0.35 s
    before the game is the JIT pool's 0.9 s prepare, the same in every run.
- **Game page.** `open:app-620#graphics` shows Resolution, Frame rate limit,
  Direct3D (`Default · Vulkan`) and Launch arguments (`.work/p2m3e/page2`).
  - A play with `{"frameLimit":30,"screen":"540","arguments":"-condebug"}`
    (`.work/p2m3e/set1`) logs `screen 1172x540 ... frames limited to 30 FPS`. The
    swap chain is 1172x540, and the command line ends with `"-condebug"`. The
    loading screen draws.
  - With `"graphics":"dxmt"` added, the page marks all four as changed
    (`.work/p2m3e/page3`).
  - DXMT for an i386 title is kept as a choice, by decision 0047, though it cannot
    draw one. It was not launched. Nothing needed fixing.
- **Portal 2 on `05dcdeb7`** (`.work/p2m3e/final`): `p2-cold-boot` loads the
  chamber, and RT plays with the gun and the "Create Blue Portal" hint up.
- **On the committed IPA.** Commit `bd2512f` builds
  `.work/out/20261004-124027-08e0a09a/Playport-26.5-08e0a09a.ipa` (SHA256
  `08e0a09a49b072d614a4e3029ab297ff2db3a15e960ffad612bae58f826e7ba4`, 78 IPA checks).
  Its artifacts are `05dcdeb7`'s; only the provenance differs. In one session, battery
  31%:
  - Hollow Knight (`.work/p2m3e/hk-commit`) passes `first-frame+10`, first frame at
    8.92 s, main menu on the screenshot.
  - Portal 2 (`.work/p2m3e/commit-p2`): `p2-cold-boot`, then RT, in the chamber with
    the gun.

## The laser chamber solved by pad

One session on the committed IPA `08e0a09a` (commit `bd2512f`, SHA256
`08e0a09a49b072d614a4e3029ab297ff2db3a15e960ffad612bae58f826e7ba4`):
`pp ui --play app-620 --pad --until first-frame+20 --leave-running`
(`.work/ui-runs/20261004T124533`, first frame at 5.62 s), then `pp pad push
p2-cold-boot` and about 90 `pp pad send … --shot` steps, aimed by reading each
screenshot. Screenshots are in `.work/p2m3s/` and are described here, not published.
Battery went from 30% (not charging) to 38% (external power was connected partway).

- **Solution** in `sp_a2_laser_intro`:
  - blue (RT) on the white floor panel that the emitter's beam falls onto;
  - orange (LT) on the white ceiling directly above the laser catcher, which is next to
    the player's start spot.

  The beam enters the floor portal, comes down from the ceiling into the catcher, and
  the catcher lights. Following the indicator dots led to the catcher, after the
  orange portal was first placed on the panel by the exit (shot 32), where the beam
  hit a plain wall.
- **Key screenshots:**
  - `21`: blue on the panel, the beam leaving orange (the state of milestone 3's
    earlier `portal-both.png`, which never reached the catcher).
  - `56`: orange on the ceiling; the catcher's rim turns from blue to yellow and
    the beam glows in its lens.
  - `58`: the indicator dots turn yellow and the plate in the water below the exit
    rises on an arm, making a platform up to the exit door.
  - `74`–`78`: to reach the ledge, orange is moved to the panel facing the exit
    ledge, and walking into the blue floor portal puts the player up by the exit (the
    exit sign and the running-man door are ahead in `78`). Moving orange un-powers
    the catcher (dots blue again).
  - `89`–`90`: back at the catcher, orange is fired onto the ceiling again; the dots
    are yellow and the catcher's rim yellow, so the chamber is powered again.
- **Not done:** walking through the exit door into the next area. The session ended
  there because the phone was needed for something else.
- **Save:** a final START opened the pause menu (RETURN TO GAME, SAVE GAME selected,
  LOAD LAST SAVE, OPTIONS, EXIT TO MAIN MENU; shot `93-save`). The two A presses after
  it did not visibly open the slot list, so no save from this session is confirmed.
  The save path itself was shown earlier (`p2-save-load`). The app was then ended with
  `pp phone kill`.
- **Trigger misses** (shots 17–20, 29–30) were aims at surfaces that do not take
  portals. `VirtualPad`'s LT and RT map to the triggers, and with the crosshair on a
  white panel every fire landed. Explicit `LT=1`/`RT=1` were used.
- **Runtime:** no i386 exception, no crash, no unaudited win32u call
  (`.work/p2m3s/log2/s1-host.log`). The JIT pool's band went from 1653 to 2247 MB of
  16384, with nothing refused and `exhausted=none`. **Thermal went nominal → fair →
  serious** over about an hour in the chamber with the screen and GPU busy; frame
  time was not measured at the serious state.

## A 95-minute session with save and load

The setup:

- One session on the same IPA (`08e0a09a`, commit `bd2512f`), launched with
  `pp ui --play app-620 --pad --until first-frame+20 --leave-running`. The run
  directory is `.work/ui-runs/20261004T180821`, and the first frame came at 5.68 s.
- The Metal HUD was on (`hud:on --keep-settings`, turned off afterwards).
- `p2-cold-boot` was pushed, then 165 `pp pad send … --shot` steps followed, with
  screenshots in `.work/p2m4/`.
- The app ran from 18:08 to 19:43 (5635 s by the last `[xp]` sample) and was
  ended with `pp phone kill`. `pp phone crashes` found no report.
- Battery read 18% at 19:20 and 24% at 19:42, both on external power and charging.

### What was played

The chamber was solved again: shot `37` shows the dots yellow, and in `50` the
player is on the exit ledge through the portals. Orange was then moved back to the
ceiling to re-power the catcher. In `99`–`100`, GLaDOS says "Not bad" and the
player rides the rising arm platform. In `102` the player walks off it through the
exit door, with the elevator tube ahead.

**The map change into the next chamber was not confirmed.** The steps after `102`
(`103`–`111`) leave the player back in the chamber, which is consistent with falling
off the walkway. A second ride, `118`–`124`, ended in the water too (`125`). After the
save and load below, two more tries also failed:

- The ledge route dropped the player into the water (`144`).
- The plate route lit the floor but not the catcher (`152`): orange was placed at a
  slightly different ceiling spot, the beam came down beside the catcher, and the
  dots stayed blue.

The session stopped there after 95 minutes. None of the misses was a runtime fault.
All of them were pad aim and movement, steered through screenshots taken about 20 s
apart.

### Save and load

- **Save, confirmed** (`126`–`128`): START, then SAVE GAME, then New Saved Game
  Slot. When SAVE GAME is reopened, the new slot is listed with the session's time.
  The game shows UTC.
- **Load from the menu** (`129`–`131`): EXIT TO MAIN MENU took about 15 s, then
  PLAY SINGLE PLAYER, then LOAD GAME. The new save is first in the list (Chapter 2,
  The Cold Boot, with a thumbnail of the laser chamber). Loading it took about 30 s
  and restored the saved position and the powered catcher exactly.

### Frame time against thermal state

Frame times come from the HUD's per-frame (interval, GPU) pairs in `s1-host.log`.
The game ran at 1564x720, capped at 60. The table uses 5-minute buckets.

| Clock | Thermal | FPS | Interval median / p95 / p99 ms | GPU median / p95 ms | Frames >50 ms |
| --- | --- | --- | --- | --- | --- |
| 18:10–18:20 | nominal → fair (18:15:51) | 59.9–60.0 | 16.67 / 20.84 / 25.01 | 15.1 / 17.3 | 0–7 |
| 18:20–18:55 | serious from 18:22:26 | 54.1–58.3 | 16.67 / 25–29 / 29–33 | 15.1–16.1 / 17.6–19.8 | 0–26 |
| 19:00–19:15 | serious | 50.2–53.9 | 16.67 / 25–29 / 33.35 | 14.4–17.2 / 20.0–21.5 | 2–25 |
| 19:20 | serious; save, menu and load | 39.6 | 25.01 / 37.51 / 45.85 | 22.4 / 28.8 | 97 |
| 19:25–19:42 | serious | 49.6–50.2 | 16.67–20.84 / 29.18 / 33–37.5 | 17.1–17.9 / 20.3–23.3 | 1–7 |

The state never went past "serious". Over the hour at "serious", the mean rate fell
from 60 to about 50 FPS, and GPU time per frame rose from 15 to about 18 ms. That
is more than the 16.7 ms a 60 FPS frame allows, so the cap is no longer met. The
median interval stayed at 16.67 ms until the last 15 minutes.

CPU, from the `[xp]` samples:

- At 18:15 (fair), the process used about 490% of a core at P 1.6 GHz and E 2.0 GHz.
- At "serious", the samples show P cores at 0 GHz and the threads on E cores at
  about 1.3–1.4 GHz. At the end that was 695% of one core.

Hitches of 100 ms or more: 38 in the session.

- Most fall in loads, the save, and the menu: 18:09, 19:16–19:20.
- The longest in play were:
  - 996 ms at 18:25:24, in the chamber;
  - 550 ms and 417 ms at 18:22:39, 13 s after the state became "serious";
  - 578 ms and 596 ms at 19:04:16–17, at the elevator.
- No log line explains any of them. The wineserver's per-second counts show nothing
  unusual around them.

### Stability

All figures are from `.work/p2m4/log-final/s1-host.log`, 167473 lines.

- **Faults:** no i386 exception, no crash, no `RECLAIM`, no page fault, and no
  unaudited win32u call.
  - The 39 "exception" lines are the Mach handler registering threads and the task
    port.
  - The 14 `REFUSED` lines are the 12 image preferred-base relocations of every run
    and two startup `[va-scan]` lines.
  - The guest `0x370` refused read of milestone 2 did not occur.
  - The subfloor window serviced 106497 accesses (0 unhandled, 0 refused).
- **JIT pool:** 512 MB.
  - Head 26 MB, tail 161 MB, 326 MB of room, 19 images.
  - `tail_refused=0`, `tail_fatal=0`, `exhausted=none`.
  - `limits: wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0`.
  - FEX compiled 60259 blocks in total, flat at about 57–60k after the first
    10 minutes, with a 99% lookup hit rate.
- **Band:** used 1637 → 1839 → 2181 MB of 16384, with threads 22 → 26 → 29 and
  `refused=0`.
- **Footprint** (`fpMB`): 800 at launch, 2830 at 18:20, 2931 at 18:44, 3015 at
  19:08, 3028 at 19:20 (after the load), and 3101 at 19:31; the last sample read
  3119. After the chamber loaded it grew about 4 MB a minute. The cause is not
  established, and over 95 minutes it stayed far from the limit.

## Open

- The map change out of `sp_a2_laser_intro` into the next chamber, and a save there.
  The exit door was walked through, but the move into the elevator was not completed
  (above).
- A long session at "serious" holds about 50 FPS at 720p, with GPU time of 17–18 ms
  per frame, so the 60 FPS cap is not met.
- Unexplained 0.4–1 s hitches in play (18:22, 18:25, 19:04).
- Footprint growth of about 4 MB a minute after the chamber loads.
- The in-game hints' glyph depends on the last device used, not on a setting.
- GPU time in a chamber is 13–15 ms at 720p, 60 FPS capped. Native resolution or an
  uncapped rate would be GPU-bound.
- The 596 ms and 200 ms chamber hitches of `p2m3-cold-boot` did not recur; their
  cause is not established.
- The fallback fonts' distribution review (above).
- A retired window's final teardown on the phone has not been seen (see QUIT).

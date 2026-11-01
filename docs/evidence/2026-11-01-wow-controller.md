# WoW's controller: GamePadEnable and SDL's raw input driver (2026-11-01)

**Linear:** [PLA-522](https://linear.app/playportdev/issue/PLA-522) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516)). Desktop Wine on the workstation
plus reading the game and the app; the phone gate is not run yet (side worktree `wowpad`,
decision 0117).

**Status:** WoW reads controllers through SDL 2 and only with its `GamePadEnable` CVar on, which
is off by default. On the phone it saw no pad for two reasons: Play wrote no `GamePadEnable`, and
SDL's raw input driver, on by default, takes XInput pads only as raw input HID devices, which
this runtime has none of, while keeping SDL's XInput driver from loading XInput. Play now writes
`GamePadEnable "1"` where `Config.wtf` names none, and the app's guest environment sets
`SDL_JOYSTICK_RAWINPUT=0`; under desktop Wine that makes WoW load XInput, open the pad through
SDL's XInput driver and read its state every frame.

## What the app saw

The owner's toast was the suggested starting layout (`LayoutSuggestionToast.swift`, PlayportKit
`LayoutSuggestion`): a game on the Gamepad layout that makes no XInput state request in 20 s of
play after its first frame is offered Keyboard & mouse ("This game doesn't seem to read a
controller."). The count is win32u's `ios_gamepad_query` calling the app's
`playport_gamepad_state_read` for each state request (`patches/madeira-unix` 0247), which every
`XInputGetState` and `XInputGetStateEx` of Wine's `xinput1_*` makes (`patches/wine-port` 0055).

Main's run `20261101T110435` (IPA `fce8b0f4`) logs `controls: start: 0 controller(s) connected;
Gamepad · 60%, player 1 is the controls' pad` before the title starts, so slot 0 held the
on-screen controls' pad from launch, and `controls: suggested layout not offered for bnet-wow:
offered before`: the offer had been made in an earlier run. No XInput DLL load is logged.

## What WoW uses

`Wow-ARM64.exe` (12.1.5.70575, sha256 `8273c34d…8e8e`) imports no controller DLL; its strings
hold SDL 2's joystick code (the SDL2 game controller database, `SDL_JOYSTICK_RAWINPUT`,
`SDL_JOYSTICK_RAWINPUT_CORRELATE_XINPUT`, `SDL_JOYSTICK_HIDAPI_*`, `SDL_XINPUT_ENABLED`,
`SDL_DIRECTINPUT_ENABLED`, "Controller isn't correlated yet, try hitting a button first"), the
names it loads at run time (`XInput1_4.dll`, `XInput1_3.dll`, `XInput9_1_0.dll`, `hid.dll`,
`Windows.Gaming.Input.Gamepad` and its siblings for `RoGetActivationFactory`, `HidD_*`,
`SetupDiGetClassDevs*`, `CM_Register_Notification`), and `GameInput.dll` / `GameInputCreate`.
The x64 `Wow.exe` (sha256 `14b70997…6a29`, the [desktop baseline](2026-10-30-wow-desktop-baseline.md)'s)
has the same strings.

Under desktop Wine 11.20 (the baseline's headless sway, prefix and DXVK/vkd3d-proton setup,
copied by reflink into the side worktree's build area), `Wow.exe` to its login screen with
`WINEDEBUG=+loaddll,+xinput,+dinput`, a virtual Xbox 360 pad from `/dev/uinput` (045e:028e,
python-evdev; Wine's `winebus` and `winexinput` expose it as HID) and these counts over 70–110 s:

| run | `GamePadEnable` | pad | environment | DLLs loaded | `XInputGetCapabilitiesEx` | `XInputGetStateEx` | `XInputSetState` |
|---|---|---|---|---|---|---|---|
| `default-pad` | (none) | from start | | none of them | 0 | 0 | 0 |
| `pad1-nopad` | 1 | none | | hid, dinput8, windows.gaming.input | 0 | 0 | 0 |
| `pad1-start` | 1 | from start | | + xinput1_4 | 4 | 5,276 | 0 |
| `pad1-hotplug` | 1 | at 50 s | | + xinput1_4 (after the pad came) | 8 | 3,544 | 0 |
| `pad1-nowgi` | 1 | from start | `windows.gaming.input=d` | hid, dinput8, xinput1_4 | 4 | 4,524 | 0 |
| `raw0-nopad` | 1 | none | `SDL_JOYSTICK_RAWINPUT=0` | all four | 4 | 0 | 0 |
| `env-nopad` | 1 | none | `SDL_JOYSTICK_RAWINPUT=0 SDL_XINPUT_ENABLED=1` | all four | 20 | 0 | 0 |
| `env-pad` | 1 | from start | `SDL_JOYSTICK_RAWINPUT=0 SDL_XINPUT_ENABLED=1` | all four | 9 | 4,394 | 1 |

- **`GamePadEnable` decides everything.** Without it WoW loads no controller DLL and calls
  nothing; with it, right after creating its Direct3D 12 device, it starts SDL's joystick
  drivers: DirectInput 8's `EnumDevices` of game controllers, the Windows.Gaming.Input
  factories in SDL 2's order (RawGameController, ArcadeStick, FlightStick, Gamepad,
  RacingWheel).
- **By default the pad goes through SDL's raw input driver.** XInput is loaded only once a pad
  is there, as SDL's raw input driver does when it opens an XInput pad (a raw input HID device
  with `IG_` in its name), which then reads `XInputGetStateEx` every frame to correlate it, and
  never `XInputSetState`. With no pad XInput stays unloaded: SDL's XInput driver is off while
  the raw input driver runs (`raw0-nopad` loads it once that driver is off; inference: the SDL 2
  release in WoW turns its XInput driver off when raw input is on, as later SDL 2 releases do).
  Windows.Gaming.Input is not needed (`pad1-nowgi`).
- **With `SDL_JOYSTICK_RAWINPUT=0` SDL's XInput driver takes over.** XInput loads at start with
  or without a pad and `XInputGetCapabilitiesEx` scans the four users (`raw0-nopad`); with a pad,
  SDL opens it as an XInput controller (`XInputSetState` once, SDL's open) and reads it every
  frame (`env-pad`). The variable alone is enough: `SDL_XINPUT_ENABLED` is SDL's default, and
  `raw0-nopad` loads XInput without it. SDL reads the environment over a game's own
  `SDL_SetHint` unless the game uses override priority.
- **A pad that comes later** is found on a device notification (`pad1-hotplug`: XInput loaded
  and the users scanned again once Wine announced the HID device). SDL's XInput driver rescans
  only on those (`CM_Register_Notification`, `WM_DEVICECHANGE`); nothing in this runtime sends
  one for the controller snapshot.

## What the phone has

- The aarch64-windows set the native ARM64 child loads ships `xinput1_1`…`xinput1_4`,
  `xinput9_1_0`, `xinputuap`, `dinput8`, `hid`, `windows.gaming.input`, `gameinput` (IPA
  `fce8b0f4`). Wine's xinput reads the controller snapshot first (`patches/wine-port` 0055, one
  source for every PE architecture), so `XInputGetCapabilitiesEx` and `XInputGetStateEx` from
  WoW reach the pads, and each state read is counted for the toast.
- Nothing lists a pad as HID: no `winebus.sys` runs, so DirectInput, SDL's HIDAPI and raw input
  drivers and Windows.Gaming.Input (off anyway, `windows.gaming.input=d`) find none. With the
  raw input driver on, SDL therefore neither loaded XInput nor added a pad, whatever the
  snapshot held: WoW could not see a controller even with `GamePadEnable` on.
- Slot 0 is connected from Play's start while the on-screen controls are on the Gamepad layout
  (`controls: start: … player 1 is the controls' pad`), and a controller that connects during
  play takes slot 0 from them, so SDL's one scan at start finds slot 0 in both cases. A
  controller that connects while slot 0 is empty (the Keyboard & mouse layout, or the controls
  off) is not seen until the next Play: the hot-plug gap Unity games have too
  ([PLA-149](https://linear.app/playportdev/issue/PLA-149)).

## The change

- `WoWConfig.prepareForPlay` (BattleNetClientKit) writes `SET GamePadEnable "1"` where
  `Config.wtf` names none; a line already there keeps its value. Test:
  `testPlayWritesTheMissingLocaleRegionAndControllerAndPinsDirect3D12`.
- `HostIO.start` sets `SDL_JOYSTICK_RAWINPUT=0` (unless set already) beside
  `WINEDLLOVERRIDES=windows.gaming.input=d`, for every game: SDL's raw input driver can find no
  pad here. The runtime log's `hostio:` line names both.
- The toast's count needs nothing new: SDL's XInput driver reads `XInputGetStateEx` every frame
  for the pad it opened, which 0247 counts. A dev build now logs `controls: the game read
  XInput state (N reads by now)` at a game's first read, also when the offer was made before
  (as for `bnet-wow` on the phone), so a pad check can see it.

## Not run

The phone: WoW on the Gamepad layout and with the scripted pad (`pp ui --pad`), checking for
`hostio: … SDL_JOYSTICK_RAWINPUT=0`, a `Config.wtf` with `GamePadEnable "1"`, the dev log's
`controls: the game read XInput state (N reads by now)`, and WoW reacting to the pad.
The desktop runs' scripts, logs and screenshots (Blizzard's artwork and an account name; not
committed) stay in the side worktree's `$PLAYPORT_BUILD/wow509/`.

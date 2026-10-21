# 2026-10-21: host pads for games that look for them (raw input HID, Windows.Gaming.Input)

**Date:** 2026-10-21. **Kind:** play on a phone, the app log (`playport.log`) and the game's
`Player.log`, a read of the game's managed code and Rewired's data. **Game:** Anger Foot (Steam
1978590, build 15756309): x86-64 Unity 2019.4.35f1, Direct3D 11, input through Rewired. **Phone:**
iPhone 17 Pro Max (iPhone18,2), iOS 27.0.1. **Pads:** a DualSense and an MFi pad, both XInput slot 0.

**Build:** Playport 0.4.0 (the release IPA, re-signed) with its arm64ec `user32.dll`,
`kernelbase.dll` and `windows.gaming.input.dll` replaced by builds of these changes on the 0.4.0
wine-pe series, with the `[hostpad]` diagnostic logging below; the patches leave the logging out
(the build without it is installed but not yet played). The patches here are the same changes rebased onto `main` (wine-pe 0045, 0046,
0047): they apply cleanly and build without warnings. The DLLs were built on macOS with
llvm-mingw 20260922 and the configure flags of `build/stages/wine-pe.sh`; unpatched, `user32`,
`kernelbase` and `windows.gaming.input` from `main`'s tree reproduce the hashes in
`build/generated/wine-pe-arm64ec-windows.tsv` byte for byte. Not built with `pp build` (no Linux
workstation): `app/artifacts.tsv` and the generated manifests are not updated here.

## The problem

The app gives a pad to Windows only as XInput: `hostio: controller "DualSense Wireless Controller"
is XInput slot 0`, then Wine's `xinput1_3` reads the host snapshot. With no winebus, no HID device
exists for it, and a game that looks for pads anywhere else finds none:

- **Unity's raw input layer.** `<RI> Initializing input.` lists the raw input devices, opens each HID
  one and reads it through XInput when its path holds `IG_` (`UnityPlayer.dll` imports
  `HidD_GetAttributes`, `HidD_GetPreparsedData`, `HidD_GetProductString`, `HidP_GetCaps`, ...). The
  list had no HID device, so Unity had no joystick and never called `XInputGetState`.
- **Rewired with its Windows.Gaming.Input source.** Anger Foot's Rewired loads
  `Rewired_WindowsGamingInput.dll`, which activates `Windows.Gaming.Input.Gamepad` through combase.
  `HostIO.swift` disables `windows.gaming.input` (`WINEDLLOVERRIDES=windows.gaming.input=d`), and
  with it enabled, Wine's providers come only from SetupAPI's HID and WINEXINPUT lists, both
  empty. The game's menus and play read only Rewired.
- **Rewired's controller database** (the game's `resources.assets`) matches an Xbox One controller
  by `Controller (XBOX One For Windows)` / `XBOX One For Windows (Controller)` and VID/PID
  `02ff045e` among others, with `[CombinedTriggers]`; its Xbox 360 entry is matched only through
  its own XInput (`xinput`). So the virtual pad is an Xbox One controller, 045E:02FF.

## What changed

- wine-pe 0045 (`user32`): `GetRawInputDeviceList` adds one HID device per host slot that holds a
  pad, and `GetRawInputDeviceInfo` names it `\\?\HID#VID_045E&PID_02FF&IG_00#3&5ead0000&0&0000#{4d1e55b2-...}`.
- wine-pe 0046 (`kernelbase`, `hostpad.c`): `CreateFileW` of that path opens a message pipe whose
  writer thread sends the slot's state as HID input reports; `DeviceIoControl` answers the HID
  class IOCTLs (`HidD_*`), with the preparsed data of the descriptor in `hostpad_blob.h`.
- wine-pe 0047 (`windows.gaming.input`): a Gamepad provider for each host slot that holds a pad,
  made before the monitor thread signals its start event.
- `HostIO.swift`: `windows.gaming.input` is no longer disabled.

## Runs

Each step is a launch of the game with the pad connected; the `[hostpad]` lines are from
diagnostic builds of the same changes (`__wine_dbg_output`, past `WINEDEBUG=-all`), left out of the
patches.

| Step | Log | On the screen |
| --- | --- | --- |
| 0.4.0 | `<RI> Input initialized.`; no `XInputGetState` call | no pad anywhere |
| user32 only | `<RI.Hid> Failed to create device file: 2` | no pad |
| + kernelbase | `open pad 0 -> 2B0 (synchronous)`, the three `ioctl` reads, `open pad 0 -> 2B4 (overlapped)`; `XInputGetState(0)` every frame with every button the player pressed | the splash takes a press; the menu does not (no Rewired, below) |
| + windows.gaming.input, providers made after the start event | `Gamepad.GamepadAdded += ...`, then `Gamepad.Gamepads -> 0` gamepads; one later run hung at start with two threads alerting each other | no pad in the menu; a hang |
| + providers made before the start event | `Gamepad.Gamepads -> 1 gamepad(s)`; `Gamepad.GetCurrentReading` every frame (1,800 in 30 s) | the pad works in the menus and in play |

The hang: Wine runs a `GamepadAdded` handler on the monitor thread under `manager_cs`; Rewired's
handler is managed code, while the main thread waited for `manager_cs` in `Gamepads`. With the
providers made before the activation returns, no handler is registered yet.

## Not covered, and side findings

- **Hollow Knight is not re-checked.** The change to `HostIO.swift` was tested as an equivalent:
  the Windows.Gaming.Input classes' `DllPath` pointed at a copy of the DLL under another name, so
  `windows.gaming.input=d` still stopped direct loads. Unity 2019.4 (Anger Foot) did not load the
  DLL directly; the comment's reason for disabling it (Unity picking it over XInput) is for a
  Unity version not seen here, which now finds the same pad through the provider, axes in
  `gamepad.c`'s order. A Hollow Knight play should confirm it.
- **SMC tracking and Mono, on 0.4.0.** With `[smc-off] Mono backpatcher detected: SMC detection
  disabled`, Anger Foot's `String.Replace(char, char)` read at the character's value (`[exc-disp]
  ... c0000005 ... p1=5c`, then `p1=2f`, from `Replace('\\', '/')` and `Replace('/', '\\')`), so
  `GameSettings.Initialize` threw `NullReferenceException` before it instantiates the
  `Rewired Input Manager`, and Rewired never started. `MADEIRA_KEEP_SMC=1` fixed it. This looks like
  Duck Paradox's case in [2026-10-13-smc-host-page](2026-10-13-smc-host-page.md); fex 0033/0038 on
  `main` were not tried. If they do not cover it, a `compat-defaults.json` entry with
  `runtime: env.MADEIRA_KEEP_SMC=1` for Anger Foot would.
- **0.4.0 lacked arm64ec `wintypes.dll`** and the `ApiInformation` registration, which
  `Rewired_WindowsGamingInput.dll` asks first (`IsApiContractPresent(UniversalApiContract, 7)`);
  without them the game ended with `e06d7363`. `main` ships both.
- **The game's saved High settings** crashed `UnityPlayer.dll` + `0xdc2108` (a read at `0x8`) on
  0.4.0 once `GameSettings.Apply` ran them; shadows, lighting and effects at Low, anti-aliasing
  off and `FullScreenWindow` avoided it. Not bisected.
- **Quit** from the game's menu leaves the game's surface up; not looked at.

## The preparsed data

`hostpad_blob.h` was made by this program, built for the host against the tree's headers with
`dlls/hidparse.sys/main.c` (`ExAllocatePool`/`ExFreePool` mapped to `calloc`/`free` after its
includes, Wine's debug functions stubbed):

```c
#define WINE_NO_TRACE_MSGS
#define WINE_NO_DEBUG_MSGS
#include "main_patched.c"   /* dlls/hidparse.sys/main.c */

static const unsigned char desc[] = { /* hostpad_report_desc */ };

int main(void)
{
    HIDP_DEVICE_DESC dd = {0};
    unsigned int i;

    if (HidP_GetCollectionDescription( (PHIDP_REPORT_DESCRIPTOR)desc, sizeof(desc), 0, &dd )) return 1;
    for (i = 0; i < dd.CollectionDesc[0].PreparsedDataLength; i++)
        printf( "0x%02x,", ((unsigned char *)dd.CollectionDesc[0].PreparsedData)[i] );
    return 0;
}
```

`clang -DWINE_UNIX_LIB -D__WINESRC__ -Iinclude -Ibuild-arm64ec/include`. The result: one
collection, Generic Desktop / Game Pad, input report 13 bytes, preparsed data 924 bytes.
`struct hid_value_caps` (104), `struct hid_preparsed_data` (148) and `struct hid_collection_node`
(16) have the same size on the host and for arm64ec (checked with `_Static_assert` under
llvm-mingw).

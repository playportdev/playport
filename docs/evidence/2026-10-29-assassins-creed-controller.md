# Evidence: Assassin's Creed (15100) controller path (PLA-347)

**Date:** 2026-10-29. **Kind:** phone sessions (killed at the owner's request), host-side
binary reading of the game's own code, upstream PC reports.
**Linear:** [PLA-347](https://linear.app/playportdev/issue/PLA-347).
**Branch:** main checkout, HEAD `55099f9`.
**IPA (dev):** `defe3d01ee144147ffcb11e8d11ea5c640a15493ddb0fa361bb8acae374ec33e`.
iPhone18,4, iOS 27.2. Run directories are under `$PLAYPORT_BUILD/ui-runs/`.

## The symptom

The owner's AC play: the game's own **Options › Controls** screen lists keyboard layouts
only — no gamepad layout — and with a controller connected before the play the game stays
on its intro videos. Our app side looked healthy in the same session, so the question was
whether the game ever asks for a pad.

## The phone sessions

| Run | What happened |
| --- | --- |
| `ac-xinput` | scripted pad, mode `controller` (XInput): first frame +7.23 s, then the intro video kept playing; `pp pad wait-text "continue"` read no title text in 150 s, and the screen "kept changing for 40 s" |
| `ac-xinput2` | the same test with a longer wait; killed at 6 m 51 s when the owner took the phone back; input stopped there, nothing relaunched |

The owner's own session in the app's rotated log shows the physical pad reaching the
snapshot: `hostio: controller connected "DUALSHOCK 4 Wireless Controller"`, `hostio:
controller "DUALSHOCK 4 Wireless Controller" is XInput slot 0`, `controls: controller map
controller for DUALSHOCK 4 Wireless Controller (slot 0)`, and `hostio: pad0 buttons=0x…`
lines with non-zero buttons while `AssassinsCreed_Game.exe` ran. So the pad was connected
before the play, mapped as XInput slot 0, and its presses were written; `hostio: input …
calls=` counts the app's writes, not the game's reads.

## The game's own pad code (host-side, no phone)

Pulled from the phone: `AssassinsCreed_Dx10.exe`, 24,183,432 bytes, CRC32 `3AF8F9D0`,
MD5 `ca87753255e2d14b1f18bb737c643792`. That is byte-for-byte the build the community
fix below names as supported.

- Imports `DINPUT8.dll!DirectInput8Create` and `XINPUT1_3.dll` by ordinals 2, 3 and 4
  (`XInputGetState`, `XInputSetState`, `XInputGetCapabilities`); the linker's jump thunks
  are at `0x9e9c10`, `0x9e9c16` and `0x9e9c1c`.
- Per frame, the game's XInput pad object calls `XInputGetState` at `0x96d6a2`, stores the
  `S_OK` test into its `Connected` field (`+0x518`) and derives `Inserted` (`+0x519`) and
  `Removed` (`+0x51a`) from the previous value. A pad object that exists does track
  connection changes.
- Creating that object is guarded: at `0x8f657e` the code branches on a call at
  `0x8e9870` (`test eax,eax; jge 0x8f65ae`), and the pad-add block at `0x8f6606`..`0x8f661d`
  is skipped by `cmp 0x4(%eax),%ebx; je 0x8f6620` at `0x8f6604`. The community ASI fix for
  this title replaces exactly `0x8f6609`..`0x8f6620` with an unconditional "add the XInput
  pad" call, and states the effect: "Added support of all XInput controllers", "Added
  detection of hotplugged controllers", "Removed support of DInput controllers".

So the shipped DX10 exe builds its Options list from a pad object it fails to create for a
pad that is not what its own check wants. That is the keyboard-only Options screen, on real
PC too.

## Upstream PC reports

- Steam's own discussions for app 15100: "Assassin's Creed Controller Fix" and "How to use
  Xbox One Controller for AC1" (drop the DirectInput-shim `xinput1_3.dll` and its ini into
  the game folder), "Xbox One Controller Issue" ("doesn't recognize it or triggers not
  working properly"), "No Controler Support?" ("once in options it showed only keyboard
  settings, then it showed Xbox controller, that option later disappeared").
- The ASI-plugin fix's README and source (github Sergeanur/EaglePatch), PCGamingWiki's
  linked fix for this title; its ini also carries `KeyboardLayout` (KeyboardMouse2,
  KeyboardMouse5, Keyboard, KeyboardAlt) and `SkipIntroVideos`.
- Steam's manual for 15100: "THE DEFAULT CONTROLS CAN BE RE-MAPPED IN THE OPTIONS MENU FOR
  PLAY WITH A 5 BUTTON MOUSE, A GAME-PAD, OR ONLY THE KEYBOARD", with the keyboard defaults
  `Forward w / Backward s / Left a / Right d`, weapon hand = Left Mouse Button, high
  profile = Right Mouse Button, empty hand = Left Shift, head = e, legs = Z, target lock =
  f, centre camera = c, map = T, pause = G.

## What this means

This is **not a Playport-side fault**: the game does not take an XInput pad on PC at all
without a third-party fix, so Options › Controls offers only its keyboard layouts. Playport
answers it with the per-game **ControllerMap**: `keyboardMouse` (or `custom`) makes the pad
press keys and a mouse, which is the path the game documents. Playport's preset
(`app/PlayportKit/Sources/PlayportKit/ControllerMap.swift`) already lands close to the
manual's defaults — left stick W A S D, right stick mouse look, RT left mouse, LT right
mouse, A Space, B C, X R, Y F, LB Q, RB E, d-pad arrows, View Tab, Menu Esc — and the rest
(empty hand, legs, throws) fits by re-binding the game's own Options or with `custom`.

Playport does not take the community fix: it is a Windows ASI plugin that binary-patches
the game executable, and we change upstream code only as patches to our own dependency
trees ([ARCHITECTURE.md](../ARCHITECTURE.md#patch-series)).

## Not checked

No play with `keyboardMouse` on the phone yet: the mapped pad was not seen driving AC's
title screen, menus or gameplay. The release app gets no automated phone test; the owner
plays and signs off.

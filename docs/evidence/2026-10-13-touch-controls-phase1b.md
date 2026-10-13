# 2026-10-13: on-screen controls, phase 1b (the owner's phase 1 feedback)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), "Owner feedback on phase 1". **Commit:**
`8371fb1` on `dev/pla-13-touch-controls`. Phase 1: [evidence](2026-10-13-touch-controls-phase1.md).

**IPA (dev):** `.work/out/20261013-113710-4cfadad8/Playport-26.5-4cfadad8.ipa`, sha256
`4cfadad83283d093ecc30964949dad12b6751dfbcda993f75e96c566e8504baa`, built from `8371fb1`
(`pp build`, 86 verify checks passed; no build record changed), installed in place with
`pp install --no-build`. iPhone (iPhone18,4), iOS 27.0.1, built-in JIT.

## What changed, and why

1. **Safe area.** PlayportKit `ControlLayout` places each control in the view's safe area: the
   anchor is the safe area's corner or edge, then the offset and size, and a control that would
   reach outside is moved back in (`ControlInsets`, `Control.frame(width:height:insets:)`). A
   floating stick's zone is a corner of the safe area, in points (`ControlZone`), so the layout
   file format is now `version` 2; version 1 is refused (no build ever saved a layout: games save
   only Off or Gamepad), and a caller uses the preset. `TouchControlsView` reads its safe-area
   insets (the larger of its own and the window's) and lays out again when they change
   (`safeAreaInsetsDidChange`). On this iPhone the log shows
   `controls: placed in 912x420, safe area insets top=0 left=68 bottom=20 right=68`.
2. **Pink flicker.** The controls' `UIVisualEffectView` backdrop blur is gone: each shape is a
   flat translucent fill (the board's tint, alpha 0.38 rather than 0.30 to read as well without the
   blur), amber while held as before. A blur samples the layers behind it, here the game's
   `CAMetalLayer`, which is the likely source of the pink glitches; no cheaper fix was tried, so
   this is the plan's default. Whether the flicker is gone needs a person's eyes (below).
3. **Top and bottom edges.** The game view defers system gestures on the vertical edges while a
   game runs: `.defersSystemGestures(on: .vertical)` beside the existing
   `.persistentSystemOverlays(.hidden)` on the game in `RootView`, which is how SwiftUI sets the
   hosting controller's `preferredScreenEdgesDeferringSystemGestures` and asks for its update as
   the game view comes and goes (the hosting controller is SwiftUI's own, so it cannot be
   overridden directly). Every control is inside the safe area (1).
4. **No Playport button; a three-finger tap.** A `UITapGestureRecognizer` with three touches on
   `GameSurfaceView` (over the game and the controls alike) calls `HostIO.menuGesture`, which
   calls `InGameMenu.open()` (that calls `QuickMenuControl.opened()`), the same path the button
   took. It works with the layout Off and with a controller connected. The recognizer keeps
   UIKit's defaults `cancelsTouchesInView` and `delaysTouchesEnded`: when it is recognized, its
   fingers get `touchesCancelled`, and HostIOKit's new `TouchControls.cancelled` takes a finger
   back as if it never came down (what it held is let go, a toggle it flipped flips back, no
   double-tap is counted); the game gets a left-button up. `GameSurfaceView` is now multi-touch so
   the recognizer sees all three fingers, and passes only the first finger to the game, as before.
   `editingInteractionConfiguration` is `.none` on `GameSurfaceView`, the first responder.
   The first-time toast now says "Tap with three fingers for the menu. The controls hide when a
   controller connects." under a new key, so it shows once more. `ControlLayout.menuButton` and
   `ControlsState.menuButtonOnly` are gone: Off draws nothing. Settings › Controls' note names the
   tap. Driver (dev only): `gesture:three-finger-tap` calls `HostIO.menuGesture`, after the
   game's first frame; `tools/ui.py` help and its action regex, and `tools/tests/test_ui.py`.
5. **Zoned floating sticks, mirrored.** The Gamepad preset (placed for a 750 × 381 safe area):
   left and right floating sticks, each starting only in a 210 × 140 zone in its lower corner,
   drawn as a faint outline; the d-pad (hit 116 × 116, drawn 8 pt inside) above the left zone
   and inward of the corner, A B X Y (each hit 52 × 52, drawn 44) mirrored above the right zone;
   a 12 pt gap between every fixed control and either zone. Fixed controls are hit before zones
   (as before). Host tests check, on seven screens (667 × 375 with no insets up to 956 × 440, and
   insets on only one side): every control and zone inside the safe area, no two controls
   overlapping, the 12 pt gap, each stick resting in its zone; and at 874 × 402 the zones'
   ownership edge to edge, the d-pad's and A's nearest edges theirs, the gap and the middle the
   game's, and a face button, the d-pad and both sticks held at once.
6. **View and Menu** are small (44 × 30) beside LT and RT at the top, inside the safe area.

**Design board:** `docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html` still draws the
phase 1 layout (the Playport button, the left zone as a third of the screen, the fixed right
stick). It is stale; updating it was not cheap (generated boards), so the code and the screenshots
named below are the reference until it is redrawn.

## Host

`pp test` passed (HostIOKit 67 tests, among them `TouchControlsTests`
`testTwoFloatingSticksEachKeepToTheirOwnZone` and
`testACancelledFingerIsTakenBackAsIfItNeverCameDown`; PlayportKit 249, among them
`ControlLayoutTests` `testAControlIsPlacedInTheSafeArea`,
`testThePresetFitsEveryScreenWithZonesClearOfTheControls`,
`testTheZonesAreMirroredAndTheirOwnersHitThere`, `testANewerOlderOrBrokenLayoutIsRefused`;
`tools/tests/test_ui.py`). `pp check` and `pp check --variant release` compile.

## Phone

Three `pp phone lock` sessions on the IPA above (the first one's touch run found Hollow Knight's
own controls set to Off on the phone, the owner's setting; it was left as it is, and the touch
run was repeated with the Gamepad layout saved by `pp ui --controls` for that session only, which
the app undoes at its next launch outside it). Run directories, under the build area:

| Run | Directory | Result |
| --- | --- | --- |
| Hollow Knight smoke, `--until first-frame+10 --shot` (layout Off) | `.work/agent-notes/pla-13-v2/runs1b/smoke` | ok; first frame at +9.22 s |
| Touch run, first try (layout Off, so `touch:` was refused) | `.work/agent-notes/pla-13-v2/runs1b/touch`, `touch2` | refused: `the on-screen controls are not shown` |
| Three-finger tap with the scripted pad connected (`--pad`), Resume | `.work/agent-notes/pla-13-v2/runs1b/pad` | ok actions=5 |
| Three-finger tap with the layout Off, no controller, Resume | `.work/agent-notes/pla-13-v2/runs1b/off` | ok actions=5 |
| Gamepad saved for the session (`--controls`) | `.work/agent-notes/pla-13-v2/runs1b/save-gamepad` | ok |
| Touch run: menus by touch, the tap, the Controls panel, Resume, both sticks, d-pad + A | `.work/agent-notes/pla-13-v2/runs1b/touch3` | ok actions=15 |

What they show (the screenshots stay in the run directories):

- **The new layout over the game** (touch3, `action-03`, `action-13`): over Hollow Knight's main
  menu, LT over LB at the top left with the small View button beside LT, Menu beside RT and RB at
  the top right, all clear of the screen's left and right edges by the 68 pt insets; the d-pad
  above the left zone, A B X Y in a diamond above the right zone, and the two faint zone outlines
  in the lower corners, each with its stick resting in it. No Playport button. The centre of the
  screen (the game's menu) is clear of controls. Flat fills; no blur.
- **Presses** (touch3): `controls: driver holds dpad for 300 ms: buttons=0x0002` moved Hollow
  Knight's selection, `controls: driver holds b for 200 ms: buttons=0x2000` went back;
  `controls: driver holds leftStick+rightStick for 1500 ms: ... lx=32767 ly=0 rx=0 ry=32767` (both
  floating sticks at once, from their zones), `controls: driver holds a+dpad for 600 ms:
  buttons=0x1008`.
- **The three-finger tap opens the menu and Resume gives the controls back** (touch3,
  `action-09` to `action-12`): `hostio: three-finger tap`, `controls: hidden (menu)`,
  `menu: open over Hollow Knight`, `menu: pause -> 0, 56 threads in 50 ms`; the screenshot shows
  the menu (Resume ringed; Controls `Gamepad · 60%`). `menu:controls` opened the panel, `pad:b`
  closed it, `menu:resume`: `controls: shown (Gamepad, 60%)`, `menu: closed; back to Hollow Knight`.
- **With the layout Off** (off): no controls drawn; `hostio: three-finger tap`, `menu: open over
  Hollow Knight`, then Resume closed it.
- **With a controller connected** (pad): `controls: start: 1 controller(s) connected; Off, no
  controls' pad`, no controls in the screenshots, and the tap opened and Resume closed the menu.
  (This game's layout was Off here, so this run does not itself show Automatic hiding the
  controls for a controller; phase 1's pad run did.)
- **Frame rate:** in touch3, with the controls drawn, Hollow Knight held 60 fps in every ~4 s
  window of `[frames]` except the one with the menu's pause and one scene change.

**Not checked here (the owner's sign-off):** whether the pink flicker is gone; turning the phone
to the other landscape orientation (the driver cannot rotate the phone; the insets are symmetric
in landscape on this iPhone, and the layout follows `safeAreaInsetsDidChange`); a real
three-finger tap by hand (the driver calls the recognizer's handler, not UIKit's recognizer), and
that its fingers press nothing; that a quick single tap on a control still registers at once
with the recognizer attached (`delaysTouchesEnded` holds a release until the recognizer fails);
iOS's three-finger undo/copy/paste HUD not appearing; top-edge controls easy to hit with the
system gestures deferred; the toast on screen; the zones' size for real thumbs.

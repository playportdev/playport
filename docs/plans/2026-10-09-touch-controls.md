# Plan: on-screen controls, controller mapping and gyro aim

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Design:**
[`docs/design/2026-10-09-touch-controls/`](../design/2026-10-09-touch-controls/)
(boards and README).

**Date:** 2026-10-09. **Kind:** plan. **Status:** running (started over 2026-10-13
from `main` at `412de5f`; an earlier attempt is abandoned and not reused). Branch
`dev/pla-13-touch-controls`. The four items under [To confirm](#to-confirm) take the
proposed answer unless the owner says otherwise before the phase that needs them.

## Run state

- **Owner settings (2026-10-13):** this run covers phases 1–3 only. **Minimise phone
  testing:** host tests and `pp check` for each chunk; one batched phone session per
  phase (`pp phone lock -- …`: install, Hollow Knight `first-frame+10`, the phase's
  driven checks), and the overlay `pp perf` A/B only if the blur is suspected.
- **Decision number:** 0075 is taken; the record this plan calls "0075" takes the next
  free number, **0105** as of 2026-10-13 (0104 is the last), when phase 6 writes it.
- **Done:** phase 1 (`b784617`; [evidence](../evidence/2026-10-13-touch-controls-phase1.md),
  IPA `3911e0fa…`). Choices made there: Off for a game keeps the Playport button while no
  controller is connected, so the menu stays in reach by touch; Never makes Off every game's
  starting choice; the controls' pad is player 1 from the runtime's start and they are drawn
  from the first frame; the `pp perf` A/B was skipped (60 fps held with the overlay).
  **1b** (`8371fb1`; [evidence](../evidence/2026-10-13-touch-controls-phase1b.md), IPA
  `4cfadad8…`): owner feedback 1–6 below. The Playport button is gone (Off draws nothing);
  layout format version 2 (version 1 refused, the preset used); the design board
  `TouchGamepad.dc.html` is stale until redrawn.
  **1c** (`7f6cd07`; [evidence](../evidence/2026-10-13-touch-controls-phase1c.md), IPA
  `67d0938d…`): owner feedback on 1b below. The late controls were the game's: Hollow Knight took
  no press from a pad that connected mid-game in over two minutes; the controls' pad is now player
  1 from the runtime's start whenever no controller is connected, at rest while the layout is Off
  (risk: a game may show pad prompts while Off).
- **How the work is split (owner, 2026-10-13):** each phase runs as small writer chunks
  that use only the host (`pp test`, `pp check`, `pp build`), one writer at a time. The
  phase's one phone session is its own last chunk, and **every phase then waits for the
  owner's hands-on sign-off** before the next phase starts. The owner's feedback becomes
  a fix chunk.
- **Phase 1 signed off by the owner (2026-10-13)** on IPA `67d0938d…` (1c), with one tweak:
  A/B/X/Y a bit bigger. The tweak is a separate commit in 2a, checked on the host and seen
  on the phone in 2d.
- **Done: 2a** (host only; no phone run). `079dce7`: A/B/X/Y a bit bigger: both clusters
  120 → 126 pt (face hit 40 → 42 pt, drawn 1 pt inside rather than 2, so 36 → 40 pt; the
  d-pad's arms the same), the Above right-stick zone 210 × 120 → 210 × 114. The 5.4-inch
  safe height (354 pt) is the limit: larger faces would need smaller bumpers (an owner
  call). The next commit ("touch controls 2a: gyro aim on the host"): HostIOKit `GyroAim`
  (calibration, player space, smoothing, mouse and right-stick outputs, pause), its output
  into `InputMixer` (right stick added and clamped; mouse as `move(dx, dy)`), PlayportKit
  `GyroSettings` and `GameGyro`, with host tests; nothing reads a sensor yet.
- **Done: 2b** (host only; no phone run). `8391fdf`: a game's gyro aim is part of its
  `GameControls` record (`gyro`, PlayportKit `GameGyro`, over the `gyro.*` defaults; old JSON
  loads), and `pp ui --controls` takes `"gyro":{...}`. `d6bdf4a`: `GyroSensors` and `GyroFeed`:
  the iPhone's CoreMotion device motion at 100 Hz (bias-corrected `rotationRate` rather than the
  raw gyro, so GyroAim only trims a residual) mapped for landscape left and right as the screen
  rotates; a controller's `GCController.motion` (gravity, else acceleration, else none: player
  space is yaw); Automatic takes a controller's gyro when it reports rotation rate. The sensors
  run only while the output is not Off and the game is drawing, active, with no menu, web page or
  dialog (PlayportKit `GyroRun`); a restart keeps the bias, restarts the windows. Right stick into
  `InputMixer.gyro` under the pad lock; mouse moves coalesced to at most ~125 a second for
  Winios's 256-event ring. `cad0a0e`: the dev `gyro:STEP[/STEP...]` driver action (HostIOKit
  `GyroScript`; its samples replace the sensors' while it plays). Dev IPA `48dcb074…` built and
  verified, not installed. 2d checks on the phone: no motion permission prompt, the landscape
  signs, a DualSense's `hasRotationRate` and gravity, Portal 2 in both outputs.
- **Next:** 2c.
- **Owner feedback on phase 1 (2026-10-13), settled:**
  1. The overlay respects the safe area in both landscape orientations.
  2. Pink flicker over the game while the overlay shows: drop the blur for a flat
     translucent fill unless a cheaper fix is proven.
  3. The top controls are hard to hit, as if under the top-edge system gesture: keep them
     inside the safe area, and hold back system gestures on the top and bottom edges
     while a game runs.
  4. **No Playport button.** A **three-finger tap** anywhere opens the in-game menu.
     iOS's three-finger editing gestures are turned off, and the first-time toast teaches
     the tap. Home still opens it on a controller. This replaces "To confirm" 1 and amends
     decision 0034 in the controls decision record. With the layout Off, the gesture is
     the way back to the menu.
  5. **Zoned floating sticks, mirrored.** Each floating stick works only inside a marked
     zone in its lower corner. The d-pad (left) and A/B/X/Y (right) move up and inward,
     out of the zones, with a gap and larger hit areas, so a press on them never starts
     a stick.
  6. View and Menu become small buttons at the top by the bumpers, inside the safe area.
- **Owner feedback on 1b (2026-10-13), settled:**
  1. Controls switched on in-game, after the game started with them Off, respond only
     after a long delay. Find the cause first (Playport, or the game's XInput reconnect
     polling), then fix it.
  2. The d-pad and A/B/X/Y look and feel the same size: A/B/X/Y closer together.
  3. **The d-pad and the right stick are off by default.** Both are per-game options in
     the in-game Controls panel, with defaults in Settings › Controls:
     - D-pad: Off or On. When on, it is centred above the left stick's zone.
     - Right stick: Off, Below A/B/X/Y or Above A/B/X/Y, centred horizontally on
       A/B/X/Y in both cases.
  4. No outlines on the stick zones.
- **Queue:**
  1. **2a, done:** HostIOKit `GyroAim` and PlayportKit `GyroSettings`, with synthetic host
     tests; plus the A/B/X/Y size tweak as its own commit.
  2. **2b, done:** sources (CoreMotion, `GCController.motion`, auto), sensor lifecycle, the `gyro:`
     driver action.
  3. **2c, next:** UI: the Gyro aim page and its test area, the in-game panel's gyro switch and
     sensitivity, the overlay chip.
  4. **2d (phone):** the relative-mouse spike on Portal 2 (`app-620`) in mouse and
     right-stick modes, plus Hollow Knight `first-frame+10`. If the spike fails, a fix
     chunk follows.
  5. **Phase 2 sign-off (owner):** Portal 2 with the phone's gyro and a DualSense's.
  6. **3a:** `ControllerMap` with the `keyboardMouse` preset, and the mixer's translation,
     with host tests.
  7. **3b:** the Controller page and the ActionPicker.
  8. **3c (phone):** Portal 2 in `keyboardMouse` mode driven by the scripted pad, back to
     `controller` mode, plus Hollow Knight.
  9. **Phase 3 sign-off (owner):** a game that reads only keyboard and mouse, played with
     a controller. Then stop.
- **Phone:** dev IPA `67d0938d…` (1c) installed; unattended mode on; Hollow Knight's own
  on-screen controls are Off (the owner's setting, left as found); Hollow Knight's profile
  slot 3 may now hold a King's Pass save rather than New Game (check it before a
  measured run that uses `tools/pad/hk-new-slot.txt`).
- **Notes and reports:** `.work/agent-notes/pla-13-v2/`.

## Goal

People with no controller can play: on-screen controls over the game, a touch
keyboard, and gyro aim. A game that reads only a keyboard and mouse can be played
with a controller. Everything is set per game, by touch or controller, in the
release and dev apps, as the design boards show.

The owner's choices (2026-10-09):

- **Gyro source:** the controller's gyro when the controller has one, otherwise the iPhone's.
- **Gyro output:** mouse or right stick, chosen per game.
- **Gyro is always on when enabled.** No button has to be held, and no layout
  has an Aim button.
- **Layouts:** three presets, plus a full editor.

## Where things stand (the tree at `fbbabfb`)

- **Touch.** A direct touch is the left mouse button at that point
  (`HostIO.touch`, `GameSurfaceView.forward`). The view is single-touch.
- **Keys.** Hardware keys go through `KeyMap` to `winios_post_key`. A mouse goes
  through `GCMouse` to `RelativeMotion` and `winios_pointer` (relative moves).
  Winios's ring is mutex-locked (`winios_q_push_ev`, 256 events), so any thread may
  push. The ring drops new events when it is full.
- **Pads.** `GCExtendedGamepad` goes through `PadInput` and `PadMapping.values` to
  `GuestPadGate` and `host_pad_set` (`HostIO.publish`). That is the snapshot Wine's
  XInput reads, for x86-64 and i386 alike (Portal 2 milestone 3). `PadSlots` gives
  physical pads slots 0–3. The dev build's scripted pad (`Dev/VirtualPad.swift`,
  HostIOKit `PadScript`) publishes through the same function.
- **Releasing held input.** HostIOKit `Lifecycle` tracks held keys and mouse buttons
  and releases them on focus loss and when the menu opens (`holdGuest`). `GuestPadGate`
  rests the pads.
- **In-game menu.** It opens only when a controller's Home button is held
  (`QuickMenuControl`). A touch-only player cannot open it today.
- **Mouse look.** Relative mouse motion has never been shown to turn a mouse-look game
  on the phone. Portal 2 looks around by pad.
- **Prior art.** Madeira's `app/Madeira/TouchGamepad.swift` and its
  `docs/CONTROLLERS.md`: touch merges into slot 0, a physical stick outside its dead
  zone wins, and all holds are released on lifecycle events. It is reference only: the
  Madeira pin is frozen and none of its app code is built.

## Architecture

All the decisions live in HostIOKit or PlayportKit, as plain Swift with Linux
host tests. The app only moves events, as HostIO does today.

**Actions** (HostIOKit `InputAction`). An action is one of:

- `pad(button | trigger | stick)`
- `key(vk, modifiers)`
- `mouse(button | wheel | move)`
- `playport(menu | keyboard | gyroToggle)`

**Touch layouts** (PlayportKit `ControlLayout`). A layout is a list of `Control`s.
Each control has:

- an id
- a kind: button, stick, d-pad, look area or key bar
- an action, or four actions for a stick or d-pad
- a label
- a behaviour: hold, toggle or repeat
- a position: an anchor (a screen corner or edge), an offset in points and a size in
  points, so one layout fits every iPhone and iPad.

There are three presets: Gamepad, Keyboard & mouse, and Point & click. A layout file
has a `version` field.

**Controller maps** (PlayportKit `ControllerMap`). The mode is `controller` (today's
behaviour), `keyboardMouse`, or `custom` (a table from physical input to action).

**Gyro** (HostIOKit `GyroAim`, plus PlayportKit `GyroSettings`):

- **Settings:** output (off, mouse or right stick), source (auto, iPhone or
  controller), sensitivity, vertical ratio, turn axis (player space, yaw or roll),
  invert, and a pause button (none by default).
- **Processing:** bias calibrates itself while the device is still, and very small
  speeds get light smoothing.
- **Mouse output:** angular velocity × sensitivity, as `RelativeMotion` deltas, with
  no acceleration or dead zone.
- **Right-stick output:** angular velocity mapped to a deflection, added to the
  physical stick and clamped.

**Output** (HostIOKit `InputMixer`). The mixer collects every source:

- touch holds, merged into slot 0 with Madeira's rule
- physical pads, which pass through, or are translated when their map is not `controller`
- gyro, as mouse deltas or added to the right stick

For each change it emits `pad(slot, values)`, `key(vk, down)`,
`pointer(dx, dy | button | wheel)` or `playport(action)`. HostIO turns those into
today's calls. Key and mouse-button state stays in `Lifecycle`, so release on
pause, background or menu covers the new sources unchanged. A stick or gyro moving
the mouse needs a clock: one `CADisplayLink` while any continuous source is
active, stopped otherwise.

**Storage** (`UI/ControlsStore.swift`). The global defaults and per-game settings
live in UserDefaults next to `LaunchSettingsStore`. Unlike launch settings, a
change applies **at once** while the game runs. A per-game value marks the row with
the amber dot, and Y puts it back to the default, as other options do.

**Views.** `TouchControlsView` is a multi-touch `UIView` above `GameSurface` in
`RootView`:

- It hit-tests only its controls and look areas. Every other touch falls through to
  `GameSurfaceView`, which keeps today's tap-as-click.
- In the Gamepad layout, the lower left third is the floating-stick zone.
- The SwiftUI screens (Game options › Controls, Gyro aim, Controller,
  Settings › Controls, the in-game menu's Controls panel, the editor and the action
  picker) use the existing `Pad*` components. A controller reaches them through
  PadRouter and FocusMove, like every other screen.

**Driver** (dev only, decision 0012). New `pp ui` actions feed the same models
that touch, the sensors and the pads feed:

- `touch:<control id>[+…][@ms]`: press controls by id.
- `gyro:<script>`: angular-velocity steps (deg/s per axis, per duration), injected
  where CoreMotion's samples enter `GyroAim`. The scripted pad is the precedent.
- `controls:<title id>`: save UI_SETTINGS-style JSON as the game's controls, the way
  `settings:` does.

Every on-screen control and settings row gets a driver id. `pp verify --variant
release` must find no driver names in the release executable.

**Decision record.** **0075 On-screen controls, input mapping and gyro** covers:

- automatic display
- the Playport button as a second way to open the in-game menu. This adds to 0034,
  where only Home opens it.
- actions as the single model
- gyro always on when enabled
- the driver's new actions, under 0012.

## Phases

Each phase ends with host tests (`pp test`), `pp check`, a dev build, and the phone
gate listed. A UI change needs a run showing it. A runtime-facing change needs Hollow Knight
(`app-367520`) through `first-frame+10`. Every phone gate records the IPA's sha256 in
`docs/evidence/`. Each phase is committed when its gate passes, and PLA-13 gets the
result. Phases 1–3 make a releasable first cut.

### Phase 1: the Gamepad layout and the Playport button

**Status:** done 2026-10-13 ([evidence](../evidence/2026-10-13-touch-controls-phase1.md)).

1. **HostIOKit.** `InputAction`, `InputMixer` with slot-0 merging, and the
   touch-control state machines: hold, toggle, repeat, floating stick, double-tap
   for L3/R3, release-all. Host tests cover the cases Madeira's
   `check-touch-gamepad.py` lists, among them two fingers on one button, a physical
   pad and touch together, and release on pause.
2. **PlayportKit.** `ControlLayout` with the Gamepad preset; Codable round trip.
3. **App.**
   - `TouchControlsView`: the glass style, amber while held, a haptic tick on press.
   - The Playport button opens `InGameMenu`, the same as holding Home.
   - Automatic display: shown with no extended controller connected, hidden when
     one connects. The first time, a toast explains it.
   - Settings › Controllers becomes **Controls**: when to show, opacity, haptics,
     and the connected pads with a gyro badge.
   - The in-game menu gets a **Controls** row: Off or Gamepad, and opacity.
4. **Driver.** `touch:` and `controls:`.
5. **Gate.**
   - Hollow Knight driven only by `touch:`: menus, then walking and jumping, with
     screenshots.
   - The Playport button opens the menu, and Resume gives the controls back.
   - With the scripted pad connected, the overlay hides.
   - `pp perf` on Hollow Knight with the overlay on and off, same scene and window:
     no frame-rate drop beyond noise. If the blur costs GPU time, fall back to a
     flat translucent fill.

### Phase 2: gyro aim

1. **HostIOKit `GyroAim`.** Calibration, player space, smoothing, both outputs and
   the pause button, tested on the host with recorded or synthetic rate sequences.
2. **Sources.**
   - **iPhone:** CoreMotion `CMMotionManager` device motion at 100–200 Hz on its own
     queue. Raw rotation rate needs no permission prompt; check that on the phone.
   - **Controller:** `GCController.motion` with `sensorsActive = true`, for pads that
     report rotation rate (DualSense, DualShock 4, the others GameController supports).
   - **Auto:** the current controller's gyro when it has one, else the iPhone's.
   - Sensors run only while gyro aim is on and a game is in front.
3. **UI.**
   - Game options › Controls › **Gyro aim**, with the test area where a dot follows
     the aim.
   - The in-game menu's gyro switch and sensitivity.
   - The "Gyro aim" chip on the overlay.
4. **Driver.** `gyro:`.
5. **Spike first: relative mouse look.** With a scripted `gyro:` in mouse mode,
   Portal 2's (`app-620`) view must turn. If it does not, find where relative
   `winios_pointer` moves stop before the game: Wine's raw input or the cursor clip.
   Fix that as a Playport patch before going on.
6. **Gate.**
   - Portal 2 turns with a scripted `gyro:` in mouse mode and in right-stick mode
     (screenshots before and after).
   - Hollow Knight through `first-frame+10`.
   - **The owner plays Portal 2 with the phone's gyro and with a DualSense's**, to
     judge sensitivity, smoothing and calibration. Gyro feel cannot be checked by a
     script.

### Phase 3: controller as keyboard and mouse

1. **PlayportKit `ControllerMap`.** The `keyboardMouse` preset:
   - left stick: W A S D
   - right stick: mouse look
   - RT: left mouse button; LT: right mouse button
   - A: Space; B: C; X: R; Y: F
   - LB: Q; RB: E
   - d-pad: 1–4; View: Tab; Menu: Esc
   - Home stays Playport's.
   The `custom` mode is the same table, edited.
2. **Mixer.** A pad whose map is not `controller` publishes rest to its slot and its
   inputs as actions. The scripted pad goes through the same map, so the driver tests it.
3. **UI.**
   - The Controller page: a pad diagram with the three modes.
   - Press a button to select it.
   - **ActionPicker**, with Keyboard, Mouse, Controller and Playport tabs, modifiers,
     recent keys, and "press a real key" for a hardware keyboard. Built here and
     reused in phase 5.
4. **Gate.**
   - Portal 2 in `keyboardMouse` mode driven by the scripted pad: walk with WASD,
     look with the mouse, Esc opens its menu.
   - Back to `controller` mode, the pad plays as before.

### Phase 4: Keyboard & mouse and Point & click layouts, the touch keyboard

1. **Presets.**
   - Keyboard & mouse: a WASD stick, a look area (drag anywhere free to look), Fire,
     Jump, Reload, Use, Esc, Tab, 1–4 and the keyboard key. There is no Aim button.
   - Point & click: tap to click or trackpad, a hover tool, right click, scroll, keys
     and Esc, and a magnifier while a finger is down.
2. **Touch keyboard.** The full layout (F row, arrows, sticky modifiers). It opens
   from any layout's keyboard control or the in-game menu.
3. **Suggested layout.**
   - The default is Gamepad.
   - A compatibility-defaults entry (decision 0074, `Titles/compat-defaults.json`) can
     set `controls` for a game known to read only keyboard and mouse.
   - If a game on Gamepad has not asked for an XInput state within 20 s after its
     first frame, a toast offers Keyboard & mouse. The polling count is read where
     `winios_gamepad_get_state` is called.
4. **Gate.**
   - Portal 2 with the Keyboard & mouse layout through `touch:`: it moves, looks and
     fires.
   - A point-and-click run on a menu.
   - The touch keyboard types into a game's text field.
   - Hollow Knight regression.

### Phase 5: the layout editor

1. **The editor, over the paused game.**
   - Add, move, resize, duplicate and remove controls.
   - An 8 pt grid, snapping to other controls, undo and redo, reset to the preset.
   - Choose a preset as the starting point.
   - Per control: what it presses (through ActionPicker), its label, its size and
     its behaviour.
   - Editing a preset saves the game's own copy.
2. **Gate.**
   - Driven `controls:` layouts render as saved (screenshots of the editor and the
     result).
   - **The owner edits a layout by hand on the phone and plays with it.**
   - Hollow Knight regression.

### Phase 6: wrap up

1. Decision 0075, and the reference docs:
   - ARCHITECTURE.md: HostIO's input sources and the mixer.
   - DEVICE.md: the driver's `touch:`, `gyro:` and `controls:` actions.
   - `pp ui --help`.
2. A release build and `pp verify --variant release`. The owner installs the release
   app and signs it off (decision 0068).
3. Move the plan's outcome to `finished.md`, file follow-ups as linked issues, and
   close PLA-13. Answer the reports listed in PLA-13 (playport-triage) once a release
   carries the feature.

## Risks

- **Relative mouse may not reach mouse-look games.** Nothing has shown that it does
  (phase 2 spike). Without it, gyro and drag-to-look in mouse mode wait for a runtime
  fix; right-stick gyro and the controller map's keys do not.
- **The overlay's blur may cost GPU time.** It is a backdrop blur over a 120 Hz
  Metal layer. The phase 1 gate measures it, and a flat fill is the fallback.
- **Input volume.** Gyro at 200 Hz plus touch fits the 256-event ring as long as the
  game drains it. Coalesce mouse deltas per frame if `[winios]` reports drops.
- **Touch passes through to the game.** Touches outside controls still click the
  game. With the floating-stick zone, a tap in the lower left no longer clicks there.
  This is acceptable for Gamepad; Point & click has no zone.
- **Controller gyro coverage** depends on what GameController reports for each pad.
  Pads without rotation rate fall back to the iPhone's gyro, and the Gyro aim page
  says which source is in use.
- **Two-finger and system gestures.** Keep the overlay clear of the home indicator
  and of edge swipes, and defer system gestures on the bottom edge while a game runs.

## Not in this plan

- Sharing layouts between games, or exporting them. A follow-up issue once the
  editor exists ("Copy from another game" is the likely first step).
- Native gyro for games that read a DualSense or Switch gyro through HID, Steam
  Input or SDL. Playport's pads reach games through XInput only.
- DirectInput controllers, rumble, and more than one touch player.

## To confirm

These are the open questions from the design README. Each has the proposed answer
the plan follows:

1. **Where the Playport button goes:** top centre, dimmed after 3 s without a
   touch, full strength when touched. Needed by phase 1.
2. **How a game's starting layout is chosen:** Gamepad, unless a compatibility
   default sets another, plus the XInput-polling toast. Needed by phase 4.
3. **Sharing layouts:** not in this plan.
4. **Order:** the phases above. Phases 1–3 can ship before the editor.

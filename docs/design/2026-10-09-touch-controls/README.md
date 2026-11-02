# Touch controls, controller mapping and gyro aim

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Status:** shipped. This
is the design drawn for the owner's review on 2026-10-09; what was built is decision
[0171](../../decisions/0171-on-screen-controls-input-mapping-and-gyro.md), with phases 4–5 in
[evidence](../../evidence/2026-10-31-touch-controls-phases-4-5.md). Where the boards differ,
0171 and the code win: there is no Playport button (a three-finger tap opens the in-game
menu), and a title's starting layout can come from `controls` in its compatibility default.

Open `index.html` in a browser to see every board. Each `*.dc.html` is one
874×402 landscape screen in the gamepad UI's palette
([0034](../../decisions/0034-a-gamepad-first-ui.md),
[the gamepad UI boards](../2026-09-28-gamepad-ui/)). `canvas.json` lays them
out with notes for the canvas tool. `python3 boards.py` rewrites all of them
from one place, with the shared styles, the scene and `notes.json`. The game
behind the controls is a made-up scene, not any game's art.

## Owner's choices (2026-10-09)

- Gyro comes from the **phone and the controller**: a controller's own gyro
  when it has one (DualSense, DualShock 4, Switch Pro), otherwise the iPhone's.
- Gyro drives **the mouse or the right stick, chosen per game**.
- Layouts start from **presets, and a full editor** changes them: move, resize,
  add, remove and remap controls, saved per game.
- The design is drawn as **HTML boards**, the way the gamepad UI was.

## The model

**A control does an action.** Every on-screen control and every controller
button does exactly one action:

| Action | Examples | Reaches the game through |
| --- | --- | --- |
| a controller input | A, LB, LT, left stick, d-pad up | the XInput snapshot (`host_pad_set`, the one a physical pad uses) |
| a key, optionally with Shift, Ctrl or Alt | Space, E, Shift+1 | `winios_post_key` |
| a mouse button, the wheel, mouse movement | left button, look | `winios_pointer` (relative, as GCMouse) |
| a Playport action | in-game menu, touch keyboard, gyro on/off | the app |

A **layout** is a list of placed controls, each with an action, a label, a size
and a behaviour (hold, toggle, repeat). A **controller map** gives an action to
each physical button and stick. Both are saved per game. Settings › Controls
holds the defaults.

## Screens

| Board | What it shows |
| --- | --- |
| `TouchGamepad` | **Gamepad** layout: floating left stick, d-pad, ABXY, shoulders, right stick, View/Menu. The **Playport button** at the top opens the in-game menu without a controller. The first time a game starts with no controller, a toast explains the controls. |
| `TouchKeyboardMouse` | **Keyboard & mouse** layout: a WASD stick, drag on any free spot to look, Fire/Jump/Reload/Use around the right thumb (no Aim button: gyro aims by itself), Esc/Tab, 1–4, and the keyboard key. The lit chip shows gyro aim is on; it aims with no button held. |
| `TouchPointer` | **Point & click**: tap to click or a trackpad, with a loupe for small targets. A side bar holds right click, hover (move without clicking), scroll, keys and Esc. |
| `TouchKeyboard` | The full touch keyboard (F-row, arrows, sticky modifiers) over the game, for text fields and rare keys. |
| `QuickMenuControls` | In-game menu › **Controls**: switch layout, opacity, gyro on/off and sensitivity, and open the editor, the controller map or gyro settings. Works by touch and by controller. |
| `LayoutEditor` | The editor, **over the paused game**: grid, snapping guides, pinch to resize, undo/redo, reset, and an inspector for the selected control. |
| `ActionPicker` | What a control presses: Keyboard / Mouse / Controller / Playport tabs (LB/RB), modifiers, recent keys, and *press a real key* when a keyboard is attached. |
| `GameOptionsControls` | Game options gains a **Controls** section (on-screen controls, edit layout, controller, gyro aim), with the amber "changed for this game" dot. |
| `ControllerMapping` | Controller: **As a controller** (XInput, today's behaviour), **As keyboard & mouse** (a ready-made map), or **Custom**. Press a button on the pad to select it. Home stays Playport's. |
| `GyroAim` | Gyro aim: output (off, mouse, right stick), source (Auto, iPhone, controller), an optional pause button (none by default), sensitivity, vertical ratio, turn axis (player space, yaw, roll), invert, and automatic calibration. A test area where a dot follows your aim. |
| `SettingsControls` | Settings › **Controls** (today's Controllers): when on-screen controls show, the starting layout, opacity, haptics, and connected controllers with a gyro badge. |

## Behaviour the boards imply

- **Automatic display.** On-screen controls show only while no extended
  controller is connected. They hide as soon as one connects and come back when
  it disconnects. "Always" and "Never" are choices in Settings.
- **Suggested layout.** A game that reads XInput starts on Gamepad, a game that
  reads only keyboard and mouse starts on Keyboard & mouse. The person's choice
  wins. (How Playport knows a game's input is settled in 0171.)
- **Merged input.** Touch controls feed player 1 (slot 0). When a physical pad
  is also in slot 0, buttons combine, triggers take the larger value, and a
  deflected physical stick wins (Madeira's `TouchGamepad` rule).
- **Nothing gets stuck.** Every held touch, key and mouse button is released
  when the in-game menu opens, the app leaves the front, the layout changes or
  the editor opens (HostIOKit `Lifecycle` already does this for keys, buttons and pads).
- **Feel.** A glass look with the game showing through, and amber while held. A light haptic tick on
  press. Sticks start where the thumb lands. Double-tap a stick for L3/R3.
  Several fingers at once.
- **Gyro.** When gyro aim is on it always aims; no button has to be held
  (owner, 2026-10-09). A pause button, none by default, lets the person
  recentre. Mouse output is 1:1 angular velocity × sensitivity, with no
  acceleration or dead zone, plus a little smoothing at very small speeds to
  hide sensor noise. Right-stick output maps angular velocity to deflection,
  for pad-only games. Bias calibrates itself while the device is still.
  "Player space" combines yaw and roll so turning works however the phone is
  held. A controller's gyro needs `GCController.motion` with `sensorsActive`;
  the phone's needs CoreMotion's device motion.
- **Release and dev.** Everything here is for players, so it ships in both
  variants. The dev driver (`pp ui`) needs ids for each control and action
  (decision 0012).

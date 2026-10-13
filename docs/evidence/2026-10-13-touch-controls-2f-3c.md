# 2026-10-13: touch controls 2f and 3c on the phone (controller gyro, controller map)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue items 7 (2f), 10 (R) and 11 (3c).
Before: [R](2026-10-13-touch-controls-R.md), [2f host](2026-10-13-touch-controls-phase2f.md).
Branch `dev/pla-13-touch-controls`, HEAD `f82fa90`. No code changed in this chunk.

| IPA (dev) | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-7566e31a.ipa` | `7566e31a77d277e71acc08ace4db220ac5ffe7529bb3a0daa400af7dc7e0ccf7` | `3159bdd` |

`pp phone status` showed this IPA installed, so the session did not install. Battery 69% at the
start, 61% at the end. Unattended mode off: the owner was at the phone with a DualShock 4.

## The session

One `pp phone lock` session ran `.work/agent-notes/pla-13-v2/phone-session-S.sh`, a copy of R's
script with the run directory `.work/agent-notes/pla-13-v2/runsS/` (every run below is a
subdirectory). Changes from R's script:

- No install.
- A read-only run (`p2-before`) records Portal 2's own controls first.
- No restore runs. Nothing forces Hollow Knight's layout Off.

Every `pp ui` run and every `pp pad send` exited 0, and the session exited 0.

The gates worked as follows:

- **2f** waited for the owner's go.
- **3c:** the scripted pad was slot 0, and no DualShock was connected then.

**Restore.** The session relied on DriverUndo (`Dev/DriverUndo.swift`).

- Before the session:
  - Portal 2: On-screen controls Gamepad, Right stick Below A/B/X/Y and Gyro aim Mouse · 1.5×,
    all its own. D-pad, Opacity and Controller followed the defaults (`p2-before` screenshots).
  - Hollow Knight: Gamepad at 60%. The `hk-smoke` log has
    `controls: start: 1 controller(s) connected; Gamepad · controller connected`.
- A run after the session, outside its lock (`after-undo`), logged
  `ui: undo session d1d7e6e2dfcc: restored controls.games, settings:app-620`.
- Its screenshots show both games as before:
  - Portal 2: Gamepad, D-pad Default · Off, Right stick Below, Opacity Default · 60%, Controller
    Default · As a controller, Gyro aim Mouse · 1.5×.
  - Hollow Knight: Gamepad, D-pad On, Right stick Below, Opacity Default · 60%, Gyro aim Off.
- The session did not change Hollow Knight's controls. `hk-after` drew them as
  `controls: shown (Gamepad, 60%, d-pad on, right stick below)`.

| Run | What | Result |
| --- | --- | --- |
| `hk-smoke` | Hollow Knight (`app-367520`) `first-frame+10 --shot` | passed: JIT 2.41 s, runtime +3.58 s, first frame +9.65 s, pool exhausted none |
| `p2-ps` | Portal 2 `sp_a1_intro1`, gyro mouse, `playerSpace`, the DualShock 4 | passed (exit 0); measurements below |
| `p2-yaw` | the same with `yaw` | exit 0, **invalid for the pad**: see below |
| `ctl-page`, `ctl-stick`, `ctl-settings` | the Controller page, the ActionPicker, the stick's list, Settings' page | exit 0; screenshots below |
| `p2-km` + `km-*` pads | Portal 2 `sp_a1_intro3`, `keyboardMouse`, scripted pad | exit 0; works |
| `p2-ctrl` + `ctrl-*` pads | the same in `controller` mode | exit 0; works |
| `p2-panel` | the in-game Controls panel with the scripted pad | exit 0; screenshots below |
| `p2-look` + `look2-look` | `keyboardMouse` with Look speed 2× | exit 0; `controls: look speed 2.0×` |
| `hk-after` | Hollow Knight `first-frame+10 --shot` | passed: first frame +9.84 s |

## 2f: the DualShock 4's gyro

The pad: `gyro: controller "DUALSHOCK 4 Wireless Controller": motion, rotation rate yes, gravity
no, sensors turned on when read`. Auto chose it: `gyro: source controller ("DUALSHOCK 4 Wireless
Controller", polled 500 Hz, gravity estimated from acceleration)`.

The owner followed these steps in `p2-ps`:

1. The pad lay flat on the table until Playport's menu opened the second time.
2. Then the owner held it still in both hands.
3. 12 s after the second resume, the owner turned it slowly 90° to the left and back.

### Rates

| Measure | Before (2e IPA `fe0110ab…`, owner's log) | After (`7566e31a…`, `p2-ps`) |
| --- | --- | --- |
| Controller samples into gyro aim | 64.2–66.2 /s (handler on main) | **65.3, 67.1, 66.9 /s** (polled at 500 Hz) |
| GameController's own callback, same 2 s | the same | **65.3, 66.6, 66.4 /s** |
| Activity lines, samples a second | 63–67 | 63–67 |
| Mouse moves while turning | ≤ 66 /s | 54–67 /s (one per sample) |
| Coalescing delay, max | 0.0 ms | 0.0 ms; once 14.1 ms |
| iPhone device motion (`p2-yaw`, phone source) | 99.6 /s | 99.6 /s, 100 moves/s while turning |

- Polling reads the same rate as the callback: 65.3 against 65.3, 67.1 against 66.6, and 66.9
  against 66.4 a second.
- So GameController updates a DualShock 4's motion about 65 times a second. A faster reader does
  not raise it. The limit is the pad's Bluetooth report rate as iOS applies it, not the main
  queue.

### Gravity and the acceleration frame

| When | Acceleration (aim frame) | Gravity estimate | Note |
| --- | --- | --- | --- |
| Flat on the table, first start | `0.01 -1.03 0.03` | `-0.02 -1.00 0.05` | expected `0 -1 0` |
| Flat, after the first resume | `0.01 -1.04 0.03` | `-0.02 -1.00 0.05` | |
| Held still, after the second resume | `0.00 -0.84 0.71` | `-0.03 -0.75 0.66` | about 41° toward the player |
| Held still, activity lines (about 30 s) | | `-0.03 -0.75 0.66` to `-0.05 -0.71 0.71` | steady to ±0.05 |
| During the turn | | `0.04 -0.73 0.68` to `0.11 -0.58 0.81` | the hands' roll, then back |

**The frame verdict: Apple's header is right for the DualShock 4.**

- A pad at rest gives (0, 0, −1) in the pad's own axes, and our mapping turns that into
  `0 -1 0`.
- SDL's frame would have read `0 0 ±1` flat.
- No mapping fix is needed.
- The estimate held still in the hands. It moved with the hands' roll during the turn and came
  back afterwards.

### Calibration

- `gyro: calibrated: bias 0.0270 0.0102 0.0359 rad/s` came after `source controller` and before
  the first `sensor rate:` line, which comes 2 s after the start. So the pad was calibrated
  within 2 s, on the table.
- The owner's 2e log took 18.7 s.
- The bias matches 2e's owner log (`0.0305 0.0094 0.0361`). Later windows blended it while the
  pad was held (0.0258–0.0286 on x), with no new `calibrated` line.

### Counts for the turn

| Run | Turn axis | Source | Left | Back | Physical turn |
| --- | --- | --- | --- | --- | --- |
| `p2-ps` | playerSpace | DualShock 4 | −2428 dx (dy −130) | +2401 dx (dy +162) | owner's 90° by hand |
| `p2-yaw` | yaw | **iPhone** (the pad had disconnected) | −2046 | +2143 | whatever the phone turned |

- The sums are the activity lines with |dx| > 100. Lines at the edges of the turn add about ±50.
- At sensitivity 1.5 a degree is 30 counts. So `p2-ps` counted about 81° for the owner's turn,
  estimated by hand at 90°, and the turn came back to within 1%.
- The scale is right for the pad, in player space. The owner's "needs 2×" from 2e is not a frame
  or scale error. It was the 18.7 s calibration, with a 2.7°/s drift before it.
- **`p2-yaw` is invalid for the pad.**
  - The DualShock 4 was not connected when Portal 2 started (`controls: start: 0 controller(s)
    connected`). Setup's `before play:` line still names the paired pad.
  - Auto fell back to the phone, as designed: `source phone (device motion 100 Hz)`.
  - The pad dropped off between the two runs, about 3 minutes apart, probably asleep.
  - The supervisor chose not to rerun it, since `p2-ps` settles the frame and the scale.
  - So yaw against playerSpace on the same pad is **not measured**.

## 3c: the controller map

The DualShock 4 had gone, so the scripted pad was slot 0 in every 3c run, for example
`controls: controller map keyboardMouse for scripted pad (slot 0)`.

- **The Controller page.** These screenshots are in `ctl-page`, `ctl-stick` and `ctl-settings`:
  - **As a controller:** every row names its own pad input, and HOME · PLAYPORT MENU sits under
    the rows. The text is "The game sees an Xbox controller…".
  - **Right → As keyboard & mouse:** the preset is shown in full, with an Edit a copy button and
    the Look speed row. LT Right, LB Q, L stick W A S D, L3 –, D-pad 1 2 3 4, View Tab, Menu Esc,
    RT Left, RB E, Y F, X R, B C, A Space, R stick Mouse, R3 –.
  - **LB** rings the LB row and lights LB in the picture.
  - **A** changes to Custom (a copy, no question). Reset all appears.
  - **A again** opens the ActionPicker, "What LB presses". Now: Q. The tabs are Keyboard, Mouse,
    Controller and Playport. A full keyboard is shown with Q ringed and With Shift/Ctrl/Alt.
  - **RB** switches to the Mouse tab: Left, Right and Middle button, Wheel up and down.
  - **X** shows "Press a key on the keyboard…" with X Stop waiting.
  - **B B** comes back to the page in Custom, with LB still ringed.
  - **`ctl-stick`:** L stick's list has Whole stick and Four directions (chosen), then Up W,
    Left A, Down S, Right D.
  - **`ctl-settings`:** Settings › Controls › Controller is As a controller with the rows greyed.
- **`keyboardMouse` on Portal 2** (scripted pad, screenshots after each `pp pad send`):
  - LY=1 walked forward up the stairs to the door.
  - LX+LY walked diagonally through it.
  - RX then RY turned the view right and up.
  - START opened Portal 2's pause menu (Esc), and START again closed it.
  - RT held, then Home, opened Playport's menu over the game. Its A resumed with the view
    unchanged: no Space reached the game.
  - RT (`km-fire`) changed nothing visible, because there is no portal gun in this map.
- **`controller` mode:** `controls: controller map controller for scripted pad (slot 0)`. LY=1
  walked forward and RX turned the view right, as before 3a.
- **The in-game Controls panel** (`p2-panel`):
  - With the scripted pad connected, the panel shows seven rows without scrolling: On-screen
    controls, D-pad, Right stick, Opacity, Gyro aim, Sensitivity, and Controller (Pad · Keys &
    mouse · Custom).
  - Six downs ringed Controller. It showed Pad and was not changed.
- **Look speed 2×:** `controls: look speed 2.0×` with the `keyboardMouse` map. `look2-look`'s
  RX=0.6 for 1.2 s turned the view well right.
  - **Not measured:** its counts against `km-look`. The 3c pad steps' app logs were not kept,
    because each next `pp ui` run moves `s1-host.log` aside.

### Seen in the screenshots (reported, not fixed in this chunk)

- The in-game panel's Controller row label wraps as "Controlle / r".
- The Controller page's Look speed row is truncated: "Look sp…" and "Default…".
- In the in-game menu, the Controls row's value is truncated ("Gamepad · controller c…").
  The menu's Controller row reads "None" while the scripted pad is connected. This may be by
  design, since the scripted pad is not a GameController pad.
- The ActionPicker's footer hints move with the dialog's height and sit over the page behind it.
  In the waiting state they overlap the Look speed row.

## The 125 Hz cap

Keep it. The DualShock 4 delivers about 65 samples a second, and the iPhone 100. Neither reaches
125, so the coalescer never merges two samples. The longest delay was 0 ms, once 14.1 ms.
Passing every controller sample at about 250 Hz would change nothing for either source.

Games observed: Hollow Knight (`app-367520`), `first-frame+10` passed twice. Portal 2
(`app-620`): gyro mouse with the DualShock 4, `keyboardMouse` and `controller` maps with the
scripted pad, all working.

# 2026-10-13: touch controls U on the phone (gyro smoothing, arrow keys, the Controller page's ring, the in-game editor)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue items 12 and 13. Before:
[2f and 3c](2026-10-13-touch-controls-2f-3c.md). Branch `dev/pla-13-touch-controls`.

| IPA (dev) | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-5faec414.ipa` | `5faec4142790bd0cbb2ecbabe8a5c5d6e63fc1f7a37efcd333440c70f3d79d9a` | `c3920bd` |

Commits: `3052fe5` (gyro smoothing row), `01942c9` (Keyboard & mouse's d-pad: the arrow keys),
`c3920bd` (the Controller page's ring, the in-game editor, the cosmetic fixes). Host: `pp test`
all passed (tools/tests 597, HostIOKit 127, PlayportKit 298 tests), `pp check` dev and release.
`pp build` verified the IPA (86 checks); no build record changed.

## What changed

- **Gyro smoothing** (owner, after 2f): a Smoothing row (Auto, Off, Light, Normal) on the Gyro aim
  page and in Settings › Controls › Gyro aim, per game over `gyro.smoothing`. Auto is Off for a
  controller's gyro and Normal for the iPhone's. Normal is the smoothing as before; Light halves
  its window and thresholds; Off passes every sample. Host tests cover Off, Light against Normal
  on a slow ramp, and the per-source default. Not felt on the phone in this session: the owner
  plays it at the sign-off.
- **Keyboard & mouse's d-pad** presses the arrow keys (Up, Down, Left, Right) instead of 1–4. A
  saved Custom table keeps its keys. An unedited Custom, saved without a table, follows the
  preset.
- **The Controller page's navigation** (owner report on `7566e31a…`: rows out of reach, LB/RB did
  not change the mode, B went back instead of editing B). This **supersedes 3b's
  press-a-button-to-ring-its-row capture**, which is gone. The page now works like this:
  - The D-pad and the left stick move one ring through every item in every mode (PlayportKit
    `ControllerMapNav`). Down walks the header, the left column, Look speed, then the right
    column. Left and right go across at the same row.
  - LB and RB cycle the mode from anywhere. Custom keeps its table.
  - A edits the ringed input. In Custom the ActionPicker (or a stick's list) opens at once. As
    keyboard & mouse it asks "Edit a copy of Keyboard & mouse?" first; as a controller it asks
    "Change what this input does?" (Switch to Custom).
  - Y resets the row. B goes back.
  - The ActionPicker: LB and RB switch its tabs, A chooses, X waits for a real key, B cancels.
- **The in-game editor:** the in-game Controls panel opens the full Controller page and its
  ActionPicker over the paused game. A on the Controller row, a tap on its "Edit controller…", or
  choosing Custom there opens it; B returns to the panel. The menu keeps the input.
- **Cosmetic, from 3c:**
  - The panel's "Controller" label stays on one line.
  - Look speed fits: "Default" moved under its title.
  - The menu's Controls value is "Gamepad · hidden" while a controller hides the controls.
  - The ActionPicker's footer sits at the bottom of the screen.
  - The Controller row names the dev build's scripted pad "Scripted pad" (dev only, decided
    here: the scripted pad is no GameController pad, so it has no name of its own).

## The session

One `pp phone lock` session (`575ae7a9104a`, under `setsid nohup`) ran
`.work/agent-notes/pla-13-v2/phone-session-U.sh`. Its runs are in
`.work/agent-notes/pla-13-v2/runsU/`. The session installed the IPA in place (`install
--no-build`). Every step exited 0 and the session exited 0. Battery was 53% (charging) at the
start and 70% at the end. Unattended mode was off; the owner was at the phone. No DualShock was
connected, so the scripted pad was slot 0.

**Restore.** The session relied on DriverUndo. Settings and controls were saved by
`--settings`/`--controls` before the Controller page's own edits, so the originals were recorded
first.

- `before` recorded both games' controls first:
  - Portal 2: Gamepad, Right stick Below, Controller As a controller, Gyro aim Mouse · 1.5×, all
    its own.
  - Hollow Knight: Gamepad, D-pad On, Right stick Below, all its own.
- A run after the session, outside its lock (`after-undo`), logged
  `ui: undo session 575ae7a9104a: restored controls.games, settings:app-620`.
- Its three screenshots match `before`'s. The Controller page is pixel-identical; the two
  options pages differ only in Cloud saves' sync time.

| Run | What | Result |
| --- | --- | --- |
| `hk-smoke` | Hollow Knight (`app-367520`) `first-frame+10 --shot` | passed: JIT 2.47 s, runtime +3.75 s, first frame +9.34 s |
| `before` | both games' Game options › Controls, Portal 2's Controller page | read only |
| `ctl-ring` | Portal 2's Controller page, driven (below) | exit 0 |
| `ctl-settings` | Settings' Controller page | exit 0: As a controller, rows on the ring |
| `p2-km` + `km-*` pads | Portal 2 `sp_a1_intro3`, `keyboardMouse`, the scripted pad, its Esc menu | exit 0; first frame +5.77 s |
| `km-log` | the pad steps' app log (`pp phone log`), kept before the next run | `km-log/s1-host.log` |
| `p2-editor` | the in-game menu, the panel, the Controller page and ActionPicker over the paused game | exit 0 |
| `after-undo` | both games' controls after the session | restored |

## The Controller page's ring (`ctl-ring`)

The page opened on the mode switch, As keyboard & mouse. The footer read **A Change · LB RB Mode
· Y Back to default · B Back**, and Look speed was whole ("Look speed", "Mouse look · Default",
`1.0×`).

1. Down rang LT; right rang RT. A asked "Edit a copy of Keyboard & mouse?" with Not now (ringed)
   and Edit a copy. B left it unchanged.
2. RB went to Custom, then RB again to As a controller. Every row read "As the controller", RT
   was still ringed, and the footer read **A Edit · LB RB Mode · B Back**.
3. A on RT asked "Change what this input does?" (Keep As a controller / Switch to Custom). Down
   and A switched to Custom and opened the ActionPicker "What RT presses" on its Mouse tab, Left
   button ringed. Its footer read **LB RB Tabs · A Choose · X Press a real key · B Cancel**,
   at the screen's bottom edge. B cancelled.
4. Down ×4 rang RB, Y, X, then B. A opened "What B presses", Keyboard tab, C ringed. Right then A
   chose V: B's row read V with the amber dot, and the footer read **A Edit · LB RB Mode · Y Reset
   row · B Back**. Y put it back to C.
5. LB went back to As keyboard & mouse, and B left the page.

## Portal 2's Esc menu with the d-pad (item 2)

`p2-km`, then the scripted pad (keyboard & mouse; `controls: controller map keyboardMouse for
scripted pad (slot 0)`):

- `km-esc` (START): Portal 2's pause menu, RETURN TO GAME selected.
- `km-down1` (DOWN): SAVE GAME selected.
- `km-down2` (DOWN): LOAD LAST SAVE selected.
- `km-up` (UP): SAVE GAME selected.
- `km-esc-close` (START): back to the game.

The kept log (`km-log/s1-host.log`) has each step's `vpad: step` and `[winios] post_key vk=0x28`
(Down) and `vk=0x26` (Up), down then up. They were posted with scan codes 0x50 and 0x48 and no
extended flag, which Portal 2 took as arrows.

## The in-game editor (`p2-editor`, item 3 and 4)

1. Portal 2 with the scripted pad; `menu:open`. The menu showed Controls **Gamepad · hidden**
   (whole) and Controller **Scripted pad**.
2. `menu:controls`, down ×6: the Controller row, its label on one line, "Edit controller… ›"
   under it in amber, Pad · Keys & mouse · Custom. The menu footer read **A Edit controller… ·
   B Back**.
3. A opened the full Controller page over the paused game (`menu: controller page open for
   app-620: keyboardMouse`, `paused=true`), on the mode switch. B came back to the panel.
4. Right chose Custom, which went straight into the page (`controller page open for app-620:
   custom (19 inputs)`).
5. Down, right, down ×4 walked LT, RT, RB, Y, X, B (`focus ctl:…` in the log for each). A opened
   "What B presses" over the paused game.
6. B, B, B: the picker, the page, then the panel. `menu:resume` resumed the game's 28 threads.

The app log has no `post_key` from `menu: open` to `menu: closed`, nor anywhere else in this run.
The driver's `pad:` presses go to the menu itself (`InGameMenu.press`), so this run did not test a
physical pad's path to the guest. That path is the menu's hold, which U did not change; in 3c, RT
held then Home reached the menu with no key to the game.

## Not checked here

- The smoothing levels, felt by hand (Auto: Off on a controller). The owner does this at the
  phase 2 sign-off.
- A hardware key through the in-game ActionPicker's X.
- Touch on "Edit controller…" (the driver presses; the tap target is the row's title and its
  link).
- A physical pad's presses on the in-game page (the driver presses into the menu directly).

## Games observed

- Hollow Knight (`app-367520`): `first-frame+10` passed on `5faec414…` (runsU/hk-smoke).
- Portal 2 (`app-620`): keyboard & mouse with the scripted pad in `sp_a1_intro3`. Its pause menu
  moved with the d-pad's arrow keys. The in-game Controller page and ActionPicker worked over
  the paused game, and it resumed.

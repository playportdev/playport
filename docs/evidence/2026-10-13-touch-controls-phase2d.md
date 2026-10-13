# 2026-10-13: touch controls phase 2d (gyro aim on the phone)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue item 2d. Before:
[1c](2026-10-13-touch-controls-phase1c.md). Branch `dev/pla-13-touch-controls`.

iPhone (iPhone18,4), iOS 27.0.1, built-in JIT, on power, lying still, no controller connected.
Two `pp phone lock` sessions. Run directories are under `.work/agent-notes/pla-13-v2/`.

| IPA (dev) | sha256 | Built from | Session, runs |
| --- | --- | --- | --- |
| `Playport-26.5-0636a72d.ipa` | `0636a72d2cef974af92e5adbd1227df445609a25e0c6be60ce710a52fe095d4e` | `b03b0e0` (2c) | 1: `runs2d/` |
| `Playport-26.5-fe0110ab.ipa` | `fe0110ab0e74995b532ae61095195984917bb013cefe37969d71c1c89edd2592` | `51e01f5` (the fixes below) | 2: `runs2d-2/` |

Both builds passed `pp build` (86 verify checks). Both were installed in place with
`pp install --no-build --ipa`.

## Result

- **Relative-mouse spike: passed.** Portal 2 (`app-620`) started in its first map
  (`--settings '{"arguments":"+map sp_a1_intro1"}'`). Gyro aim was set to Mouse.
  - `gyro:yaw=90@500/rest@300` logged `mouse dx=900 dy=0`. The view turned right: the window
    went from the right edge to the centre (`p2-mouse/action-02` → `action-03`).
  - `gyro:pitch=-30@300` logged `dx=0 dy=180`. The view turned down: more bed, the lamp higher
    (`action-04`).
  - After a resume, `yaw=-90@500` logged `dx=-899` and the view turned left (`action-16`).
  - Every move reached Wine: the `[winios] drain type=0 … flags=0x1` lines sum to exactly what
    was sent (table below). There were no `client pointer dropped` lines.
- **Right stick: the view turns only at a high deflection.** Session 2, `p2-stick`, in the map.
  The game's stick dead zone ate everything below 0.50:

  | Script | Logged stick peak | View |
  | --- | --- | --- |
  | `yaw=90@500` | 0.50 | turned right a few degrees (`action-02` → `03`) |
  | `yaw=30@1000` | 0.17 | did not move (the screenshots are pixel-identical) |
  | `yaw=-60@1000` | 0.33 | did not move |
  | `yaw=15@2500` | 0.08 | did not move |

  In this game, right-stick mode needs the deferred anti-dead-zone option or a much higher
  sensitivity.
- **Lifecycle:**
  - `gesture:three-finger-tap` logged `gyro: stopped (menu); was source phone, output mouse`.
  - A `gyro:yaw=90@300` played while the menu was up logged `0 taken (not running: menu): nothing
    moved`, and no drain line came.
  - Resume logged a new `gyro: source phone …` and a `sensor rate:` line. The view did not jump:
    `action-15` (after resume) matches `action-06` (before the menu).
  - The "Gyro aim" chip shows in every in-game screenshot, top centre, between View and Menu.
  - On the menu's Quit, Portal 2 did not close on `WM_CLOSE` within 10 s, so Playport ended it
    (`exit code 42b`). The `pp ui` result is therefore `ok: false` for both Portal 2 runs. The
    game ran normally until then, and no crash reports were written.
- **No motion permission prompt** appeared anywhere: device motion needs none.
- **Hollow Knight (`app-367520`) `first-frame+10`: ok on both IPAs.**
  - Session 1 (`runs2d/hk-smoke`): first frame at +10.07 s.
  - Session 2 (`runs2d-2/hk-smoke`): first frame at +9.91 s.
  - Both had the layout set to Gamepad for the session. The screenshot shows 2a's bigger
    A/B/X/Y on the title menu.

## Timing (session 1, `p2-mouse`, a steady `gyro:yaw=45@2500`)

| Measure | Value | From |
| --- | --- | --- |
| iPhone device-motion rate delivered | 99.6/s (200 samples in 2.01 s) | `gyro: sensor rate:` (the phone at rest; every start, game and test area alike) |
| Samples in gyro aim | 100/s | activity line (scripted at 100 Hz, the same rate) |
| Mouse moves sent | 100/s (250 moves in 2.5 s: 88 + 162 across two activity windows) | activity lines |
| Longest coalescing delay | 0.0 ms | activity lines (100 Hz is under the 125 Hz cap, so every sample is a move) |
| Game frame rate | 60.0 fps (1296 frames in 21.6 s) | `[frames]` lines |
| Moves per game frame | about 1.7 (26–27 drains per 16-frame `[frames]` interval) | drain lines between `[frames]` lines |
| Moves drained ÷ sent | 250/250, Σdx 2250 = 2250 sent (spike 51/51, pitch 30/30, `-90` 50/50) | `[winios] drain type=0` lines |
| Ring fill | stays near empty: the drains are spread evenly between frames, at most a couple of events waiting; no drops | inferred: Winios has no fill counter |

**Not measured:**
- **Raw gyro above 100 Hz.** The code asks device motion for 100 Hz; finding out whether
  `startGyroUpdates` goes higher needs a probe build.
- **A controller's gyro rate.** No DualSense was connected.
- **Releases lost while gyro mouse output ran.** Driver actions run one after another and the
  phone lay still, so no touch or key happened during a turn.

The owner's sign-off covers these with a DualSense.

## UI (screenshots in the run directories, described)

All screens were captured in session 1 (`runs2d/pages`) unless noted.

- **Game options › Controls:**
  - Rows: On-screen controls (amber dot, Gamepad), D-pad `Default · Off`, Right stick
    `Default · Off`, Opacity `Default · 60%`, Gyro aim (amber dot, `Mouse · 1.0×`).
  - The note reads "Changed for this game. The rest follow Settings."
- **The Gyro aim page:**
  - The test area is at the left, with "Calibrated".
  - `gyro:yaw=30@500/pitch=15@300` logged `dot at x=0.50 y=0.15`, and the dot is drawn right of
    centre and a little up.
  - `pad:down+down+down+right` stepped Sensitivity to 1.25× with its amber dot.
  - On leaving the page: `gyro: stopped (…); … the test area's`.
- **Settings › Controls › Gyro aim:** the rows Gyro aim `Off`, Gyro from `Auto` ("Now: Auto ·
  iPhone"), Pause button, Sensitivity, Up and down, Turn with, Invert ×2.
- **In-game Controls panel:** all six 36 pt rows fit above the footer. The Gyro aim row is ringed,
  then Sensitivity `1.0×`.

## Fixed in `51e01f5`, seen in session 2

1. **The panel's Gyro aim values were truncated** to "M…" and "Rig…" beside the subtitle "Always
   on · Auto · iPhone gyro".
   - Fix: the panel's word for Right stick is now "Stick", and a value never shrinks.
   - Seen in `runs2d-2/p2-stick/action-13`: Off · Mouse · Stick, with the subtitle whole.
2. **The Gyro aim page's footer was truncated** to "Back to def…" and "Game optio…".
   - Fix: B is now "Back".
   - Seen in `runs2d-2/gyro-page/action-03`: Choose · Back to default · Back.
3. **A still phone in right-stick mode logged an activity line every 2 s** (`right stick peak
   0.00`, 73 lines in `runs2d/p2-stick`). These came from residual noise of about 1e-5.
   - Fix: a deflection under 0.005 is no longer counted as motion (HostIOKit `GyroActivity`,
     with a test).
   - Session 2 logged no activity line while still. There was one `peak 0.01` window right after
     a resume.

## Notes

- **Session 1's first right-stick run reached only Portal 2's main menu.** `menu:quit` was the
  run's last action, so the restart after the game was a launch outside the driven run, and
  `DriverUndo` restored the launch arguments (`ui: undo session …: restored controls.games,
  settings:app-620`). The rerun in session 2 saved the arguments together with the controls.
- **What the sessions changed has been put back:**
  - Portal 2's controls and launch settings were cleared (`app-620:{}`).
  - Hollow Knight's layout was set back to Off.
  - DriverUndo restores the recorded originals at the app's next launch outside the session.

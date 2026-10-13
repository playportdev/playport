# 2026-10-13: touch controls phase 2e (fixes from the owner's phase 2 play)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13); the background bug is
[PLA-338](https://linear.app/playportdev/issue/PLA-338). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue item 2e. Before:
[2d](2026-10-13-touch-controls-phase2d.md). Branch `dev/pla-13-touch-controls`.

Setup: an iPhone18,4 on iOS 27.0.1, built-in JIT, on power, lying still, no controller connected.
There were three `pp phone lock` sessions on one IPA. Run directories are under
`.work/agent-notes/pla-13-v2/`: `runs2e/`, `runs2e-2/` and `runs2e-3/`.

| IPA (dev) | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-1acd7cab.ipa` | `1acd7cabe2e8abc3e386543e2e3f6499584d021b96d3e5df54c43467e6434322` | `bd13674` |

- `pp build` passed: 86 verify checks, 0 failed.
- The IPA was installed in place with `pp install --no-build --ipa`.
- Every run reported this sha256.

## What changed

| Commit | Change |
| --- | --- |
| `57951b2` | **Right-stick anti-dead-zone.** A gyro deflection d becomes a + d × (1 − a) along its own direction (HostIOKit `GyroAim.past`). Under `GyroAim.stickRest` (0.005) it stays zero. a is 0.27 by default (`gyro.antiDeadZone`, or per game). Its row is on the Gyro aim page and in Settings › Controls › Gyro aim, only for Right stick. |
| `4de3a2b` | **Touches outside the controls are ignored while the controls show** (HostIOKit `TouchRoute`). The driver's `tap:` follows the same rule. **The "Gyro aim" chip shows briefly:** it fades in, stays 2.5 s and fades out when gyro aim starts, the source changes or the output changes (PlayportKit `GyroChipCue`). |
| `bd13674` | **The phone gyro's default sensitivity is now 1.5×** (owner). 1.0× still means GyroAim's own scale. |

Host checks: `pp test` passed (HostIOKit 91, PlayportKit 266, `tools/tests` 593). `pp check` passed for dev and release.

## Result

### Hollow Knight (`hk-smoke`)

- `first-frame+10` passed. The first frame came at +9.77 s.
- The screenshot shows the title menu with the Gamepad layout drawn.

### Touches outside the controls (`runs2e/p2-mouse`)

Portal 2 ran in its first map (`+map sp_a1_intro1`) with gyro set to Mouse and the right stick below.

- **A touch on a control works.** `touch:rightStick.right@600` logged `controls: driver holds rightStick … rx=32767`. The view turned far right, from the room to the wall lamp (`action-04` → `action-05`).
- **A tap outside the controls is ignored.**
  - `tap:0.5:0.3` and `tap:0.3:0.5` logged `ui: tap …: ignored: outside the on-screen controls`.
  - The app logged `controls: touches outside the controls are ignored` once.
  - The game area is pixel-identical across the taps (`action-06` → `07` → `08`, mean difference 0.0).
  - Limit: the driver's `tap:` uses the same decision function, but not UIKit's hit-testing. A real finger outside the controls was not driven.
- **The three-finger tap still opens the menu.** `gesture:three-finger-tap` logged `hostio: three-finger tap` and `menu: open over Portal 2`, then `menu:resume`. The driver calls the recognizer's handler; it was not a three-finger UIKit touch.
  - The view did not jump across the menu (`action-08` → `action-11`, difference 0.0).

### The chip (`runs2e-3/p2-chip`)

`pp ui`'s own screenshots come several seconds after an action, which is too late for a 2.5 s chip. The `--screenshot-after` and `--until first-frame+1/+4 --shot` attempts in `runs2e-2/` missed it. So `pp phone shot` ran back to back, about every 2.7 s, while Portal 2 started with gyro set to Mouse:

| Screenshot | What it shows |
| --- | --- |
| `shots/shot-1791901307.625.png` (the first one after the first frame) | Valve's intro video, with the amber "Gyro aim" chip at the top middle between View and Menu |
| `shot-…310.026` (2.4 s later) and every later one | No chip |

The log shows `gyro: source phone …; output mouse … sensitivity=1.5`.

Not shown on the phone: that a plain Resume shows no chip. Screenshots come too late to prove the absence of a short chip. This is covered by the host test `testTheGyroChipShowsOnlyWhenGyroAimStarts`.

### Right stick with the anti-dead-zone (`runs2e/p2-stick`)

Same map, gyro set to Right stick, defaults (1.5×, anti-dead-zone 0.27). The log line read `… antiDeadZone=0.27`.

| Script | Logged stick peak | View | 2d (1.0×, none) |
| --- | --- | --- | --- |
| `gyro:yaw=30@1000` | 0.45 | turned right: the bed and window came into view (`action-03` → `04`, mean difference 32) | 0.17, did not move |
| `gyro:yaw=15@2500` | 0.36 | did not move (`action-05` → `06`, difference 0.0) | 0.08, did not move |

0.36 is still inside Portal 2's dead zone and response curve. A slow turn at this sensitivity needs a slightly higher anti-dead-zone (0.3–0.35 on the page), or more sensitivity.

### Restored

| Game | Restored to | Log line |
| --- | --- | --- |
| Portal 2 | controls cleared, launch arguments cleared | `ui: controls app-620: layout=default … gyro=default`, `ui: settings app-620: … arguments=[]` |
| Hollow Knight | layout Off | `ui: controls app-367520: layout=off` |

## The background bug (owner): Portal 2's GPU work, not the controls

The owner reported that the controls stopped working after a trip to the Home Screen, while the three-finger tap still opened the menu. The owner's play log is the supervisor's `pp perf --keep-log` capture (`.work/perf-runs/pla13-dualsense-p2/pulled/s1-host.log`). On the first trip:

1. `hostio: gpu gate closed`
2. `[kk-queue] commit done error=1 … MTL4CommandQueueErrorDomain error 1`
3. `DxvkSubmissionQueue: Command submission failed: VK_ERROR_DEVICE_LOST`, 59 times

After that, only one more `[frames]` line was logged, so the game stopped presenting.

The controls still took touches after the return (`controls: rightStick down`). The menu is Playport's own, which is why the three-finger tap still worked. The cause is the background GPU gate: it covers only DXMT (`patches/dxmt/0002`), so Mesa's KosmicKrisp Vulkan queue, which Portal 2 uses, commits Metal work in the background.

This is filed as PLA-338 and is not fixed here. No `pp ui` action sends the app to the background, and none was added (decision 0012), so it was not reproduced.

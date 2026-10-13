# 2026-10-13: touch controls phase 2f (controller gyro), host only

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue item 7 (2f). Before:
[2e](2026-10-13-touch-controls-phase2e.md). Branch `dev/pla-13-touch-controls`.

**The phone gates were NOT RUN: the owner paused phone testing.** Nothing in this record was
seen on a phone. The input is the owner's DualShock 4 log from 2e's IPA (`fe0110ab…`,
`.work/perf-runs/pla13-dualsense-p2/pulled/s1-host.log`, not committed), and the host.

| IPA (dev) | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-1db2c6ec.ipa` | `1db2c6eca07f6b277eb3f371c46e76a1579b7673fee981ac07233ab6259c943f` | `23709dd` |

`pp build` passed (86 verify checks, 0 failed). The IPA was built, not installed.

## What changed

| Commit | Change |
| --- | --- |
| `c9dc6c3` | HostIOKit `GyroGravityEstimate`: gravity for a pad that reports only total acceleration. GyroAim's first bias estimate after 0.5 s still (1 s windows after it). |
| `23709dd` | A controller's `GCMotion` is polled at 500 Hz on gyro aim's own queue instead of through `valueChangedHandler`. Dev log lines for the phone session. |

Host checks: `pp test` passed (HostIOKit 96, up from 91; PlayportKit 266; `tools/tests` 593).
`pp check` passed for dev and release. The release executable has none of `sensor rate`,
`own callback` or `gyro: `.

## The owner's DualShock 4 log (before)

- The pad: `DUALSHOCK 4 Wireless Controller: motion, rotation rate yes, gravity no, sensors
  turned on when read`. Auto picked it, so the source was the controller, gravity "from
  acceleration".
- `sensor rate:` from the controller in four starts: 65.7, 64.2, 64.7 and 66.2 per second.
  Every activity line shows 63 to 67 samples a second. The phone's device motion gives 99.6
  per second in the same log.
- Calibration: the source started at 15:11:15.0 and `gyro: calibrated: bias 0.0305 0.0094
  0.0361 rad/s` came at about 15:11:33.7, **18.7 s later**. Until then every activity line
  shows bias 0, so the pad drifted by about 2.7°/s.
- Sensitivity: the owner raised it to 2.0 (and tried 2.5) from 1.0. The phone's default has
  been 1.5 since 2e.

## Findings

### Why about 65 a second

- `GCMotion.valueChangedHandler` is called on the controller's `handlerQueue`. Its default is
  the main queue, and the queue covers every element handler, motion included (`GCDevice.h`,
  `handlerQueue`: "The default queue is main … @see GCMotion.valueChangedHandler").
- `GCMotion` has no queue of its own and no timestamp (`GCMotion.h`).
- iOS 17's `GCControllerLiveInput` has a per-input `queue`, buffered states and
  `lastEventTimestamp` (`GCDevicePhysicalInput.h`, `GCDevicePhysicalInputState.h`). It has no
  motion element, so there is no motion-only queue.
- **Inference, not verified:** the main queue alone does not explain 65 per second. In game the
  app's display link asks for up to 120 Hz (`TitleScreen.swift`), and a dispatch to main runs
  every queued block. So the limit is either the rate the pad reports to iOS over Bluetooth, or
  GameController delivering at most one pending callback. The host cannot tell which.
- **The choice.** Poll `rotationRate` and `acceleration` from gyro aim's queue at 500 Hz. A new
  value is a sample, stamped as it is read. An unchanged value is taken again every 50 ms, so
  calibration and the aim's clock keep running on a pad at rest.
  - It is motion-only. HostIO's and PadRouter's pad handlers stay on main.
  - It needs no main-queue hop: the old path stamped on main, then hopped.
  - SDL reads `GCMotion` the same way, by polling in its joystick update and never through the
    handler (`SDL_mfijoystick.m`, `IOS_MFIJoystickUpdate`).
  - GyroAim integrates over the sample times. With no device timestamp these are read times,
    accurate to the 2 ms poll.
- **Rejected:**
  - A controller-wide `handlerQueue`: every pad handler would need an explicit hop to main, and
    `MainActor.assumeIsolated` in them would trap.
  - `extendedGamepad.lastEventTimestamp`: it is documented for the profile's elements, not
    motion.
- **Inference, to check on the phone:** if GameController applies a report only when it
  dispatches the callback, polling sees the same ~65 per second. The dev `sensor rate:` line now
  gives both rates side by side, so the phone session settles it:

  ```
  sensor rate: N samples … (X/s) from controller, polled at 500 Hz (GameController's own callback: M …, Y/s)
  ```

  A dev build keeps a counting handler for this. A release build sets none.

| Measure | Before (2e IPA, owner's log) | After (`1db2c6ec`) |
| --- | --- | --- |
| Controller samples into gyro aim | 64.2–66.2 /s (handler, main) | **NOT RUN** (phone paused) |
| GameController's own callback | the same | **NOT RUN** |
| Mouse moves, coalescing delay | ≤ 66 /s, 0.0 ms | **NOT RUN** |
| iPhone device motion | 99.6 /s | unchanged path |

The 125 Hz cap is unchanged. It waits for the measured rate.

### Gravity for a pad without it

- Before 2f, raw `acceleration` (gravity plus the hand's motion) was player space's vertical
  and GyroAim's stillness test.
- `GyroGravityEstimate` is a complementary filter in the aim frame:
  - The gyro turns the estimate (−ω × g).
  - The acceleration's direction pulls it, with a running mean for the first second and then a
    1 s time constant.
  - An acceleration outside 1 ± 0.25 g corrects nothing.
  - The estimate is zero (player space falls back to yaw) until 0.25 s of plausible
    acceleration has come in, after 2 s with none, and after a gap.
- Host tests (`GyroGravityTests`):
  - Shaking a pad tilted 45° (up to 0.3 g at 4–6 Hz): the estimate stays within 2° of the true
    gravity, while raw acceleration swings by more than 10°. A turn with roll reads within 1% of
    the true player-space turn.
  - A 60° tilt in 0.3 s is followed within 1°.
  - With no acceleration at all, the estimate is zero.

### Axis mapping and scale

- **Units.** `GCRotationRate` is in radians per second (`GCMotion.h`). So is CoreMotion's
  `CMRotationRate`. There is no scale factor between the two on paper.
- **Same turn, same counts.** A host test checks that the phone held upright in landscape and a
  pad held flat, or tilted 30° or 45° toward the player, give the same counts (±2) and the same
  sign for the same physical turn (`testThePhoneAndAPadTurnTheAimAlike`).
- **Open question: the frame of the pad's acceleration.**
  - The gyro mapping (c.x, c.z, −c.y) agrees with SDL's (`SDL_mfijoystick.m`).
  - Apple's header puts a controller's z up: "a device held at rest with the z axis aligned with
    the azimuth … has gravitation applying the vector (0, 0, −1)" (`GCMotion.h`, `GCAcceleration`).
    Our acceleration mapping follows that.
  - SDL maps `acceleration` as −(x, y, z), with no swap (`SDL_mfijoystick.m`; also in SDL commit
    `14c31ee12a`, "DualShock and DualSense controllers no longer have
    hasGravityAndUserAcceleration set"). In SDL's frame, y is up at rest, so this implies
    GameController reports a pad's gravity on its y axis.
  - Only one of the two can be right for a DualShock 4. If SDL's is, player space takes much of
    the turn from the pad's roll and loses part of a yaw. That alone could explain the owner's
    "needs 2×".
  - The host cannot settle this. The dev `sensor rate:` line (acceleration and gravity in the aim
    frame; flat and still should read `0 -1 0`) and the activity line (`gravity x y z`) settle it
    on the phone.
- **No controller-specific default sensitivity** (supervisor's decision A). If SDL's frame is
  right, the fix is the acceleration mapping, not a multiplier. A default is reconsidered only
  if the counts still differ after the phone session.

### Calibration on the controller

- The rules (`GyroAim`):
  - each axis's rate spread ≤ 0.04 rad/s;
  - mean ≤ 0.05 rad/s;
  - gravity direction spread ≤ 0.02 per axis (about 1.1°) over the window.
- With raw acceleration, hand jitter of a few hundredths of a g already breaks the gravity rule.
  So a pad in the hands was almost never "still", and the owner's bias came only after 18.7 s.
- The estimated gravity takes that jitter out. The phone's device-motion gravity is already
  filtered, so the pad and the phone now meet the same test.
- The first estimate needs 0.5 s still rather than 1 s. Later windows stay 1 s and only blend.
  The first estimate is still bounded by the same spread and `maxBias` rules, so no turn is
  learnt.
- Host test (`testAPadHeldStillInTheHandsCalibrates`): the owner's bias, a hand tremor (≤ 0.008
  rad/s) and 0.02–0.03 g of jitter. The pad calibrates in under 1 s with the estimate, and never
  in 4 s with raw acceleration.
  - The tremor and jitter sizes are assumptions, not DualShock 4 measurements.

## The phone session for later (not run)

The phone needs a person with the DualShock 4 connected before the runtime starts. Run it as one
lock: `./pp phone lock -- sh .work/agent-notes/pla-13-v2/phone-session-2f.sh`. The script:

```sh
R=.work/agent-notes/pla-13-v2/runs2f
NEW=1db2c6eca07f6b277eb3f371c46e76a1579b7673fee981ac07233ab6259c943f
IPA=.work/out/20261013-164455-1db2c6ec/Playport-26.5-1db2c6ec.ipa
mkdir -p $R; X=$R/exits.txt; : > $X
ui() { n=$1; shift; ./pp ui --expect-ipa $NEW --wait 600 --out $R/$n "$@" > $R/$n.jsonl 2>&1
       rc=$?; echo "$n $rc" >> $X; case $rc in 4|5) exit $rc;; esac; }
./pp install --no-build --ipa $IPA > $R/install.jsonl 2>&1; rc=$?; echo "install $rc" >> $X; [ $rc -eq 0 ] || exit $rc
ui hk-smoke --play app-367520 --until first-frame+10 --shot
ui p2-save-settings --settings 'app-620:{"arguments":"+map sp_a1_intro1"}'
ui p2-save-ps --controls 'app-620:{"gyro":{"output":"mouse","turnAxis":"playerSpace"}}'
# The person: the pad flat on the table until the second menu opens (the first resume's
# sensor-rate line, 2 s after it, is the flat one); then held normally and still (the second
# resume's line); then, 12 s after the second resume, one slow 90° turn to the left and back.
ui p2-ps --action play:app-620 --action wait:75 --action menu:open --action menu:resume --action wait:12 \
    --action menu:open --action menu:resume --action wait:12 --action wait:15 --shot-each-action
ui p2-save-yaw --controls 'app-620:{"gyro":{"output":"mouse","turnAxis":"yaw"}}'
# The person: held normally and still; 12 s after the resume, the same 90° turn left and back.
ui p2-yaw --action play:app-620 --action wait:75 --action menu:open --action menu:resume --action wait:12 \
    --action wait:15 --shot-each-action
ui p2-restore-controls --controls 'app-620:{}'
ui p2-restore-settings --settings 'app-620:{}'
ui hk-restore --controls 'app-367520:{"layout":"off"}'
```

What to read in each run's `s1-host.log`:

- `controller "…": motion …`.
- `source controller ("…", polled 500 Hz, gravity estimated from acceleration)`.
- `sensor rate: … from controller, polled at 500 Hz (GameController's own callback: …)`: the
  polled rate against the callback rate. In the flat run, acceleration and gravity should read
  about `0 -1 0`; anything else (for example `0 0 ±1`) means SDL's frame is right.
- `gyro: calibrated` and its time after `source controller`.
- The activity lines: samples per second, moves per second, `coalescing delay max`, and
  `gravity x y z` while held.
- For the same turn, the summed `dx` with `playerSpace` against `yaw`. They should be close; a
  playerSpace sum far below yaw's points to the acceleration frame.

If no controller is connected, the controller rate stays unmeasured and the 125 Hz cap is left
as it is. Games observed: none (no phone run).

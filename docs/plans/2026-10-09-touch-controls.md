# Plan: on-screen controls, controller mapping and gyro aim

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Design:**
[`docs/design/2026-10-09-touch-controls/`](../design/2026-10-09-touch-controls/)
(boards and README).

**Date:** 2026-10-09. **Kind:** plan. **Status (2026-10-19):** phases 1–3 are done, signed off
by the owner and merged to `main` (`631bd7f`, 2026-10-13), and that run has stopped. Phases 4+
are not started; the next run starts on a new branch from `main`. Open follow-ups: PLA-338,
PLA-339 and PLA-340. The Run state below is the 2026-10-13 run's record (started over from
`main` at `412de5f`; the branch was `dev/pla-13-touch-controls`). The four items under [To confirm](#to-confirm) take the
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
  call). `3f10fc4` ("touch controls 2a: gyro aim on the host"): HostIOKit `GyroAim`
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
- **Done: 2c** (host only; no phone run). `97ff6ac`: the dev `gyro:` activity line gives the
  samples' rate and, for the mouse, the moves sent, their rate and the longest coalescing delay
  (for 2d's timing); `b03b0e0`: a `sensor rate:` line once, 2 s after the sensors start, still or
  not. The ring's fill has no counter: Winios is Madeira's code (a patch), so 2d counts its
  `[winios] drain` lines against the moves sent. `d6fb8fe`: Game options › Controls (layout, d-pad, right stick, opacity,
  Gyro aim) and the Gyro aim page with its test area (the sensors run for the dot only while the
  page is up and no game runs; that run sends nothing to the guest), Settings › Controls › Gyro
  aim, the in-game Controls panel's Gyro aim and Sensitivity, the "Gyro aim" chip with the
  controls, `set:gyro.sensitivity=1.5` read as a number, and `open:ID#gyro`, `open:ID#controls`,
  `open:settings#gyro`, `gyro:` on the test area. A pad's gyro is still chosen by
  `hasRotationRate` (as SDL does; a dev line logs each pad's motion flags). Dev IPA `0636a72d…`
  built and verified, not installed.
- **Done: 2d** (phone; [evidence](../evidence/2026-10-13-touch-controls-phase2d.md)). The
  relative-mouse spike passed on Portal 2 in its first map (`+map sp_a1_intro1`): 900 counts
  turned the view right and 180 turned it down, and every move was drained. Right stick turns the
  view only at 0.50; 0.33 and below are eaten by the game's dead zone. Timing: the iPhone gives
  99.6 samples/s, 100 moves/s reach Wine (1.7 per 60 fps frame) with 0 ms coalescing delay, and
  250 of 250 were drained. `51e01f5` fixed three things seen on the phone: the panel's gyro values
  ("Stick"), the Gyro aim page's B ("Back"), and a still right stick's activity lines. Dev IPA
  `fe0110ab…`; Hollow Knight `first-frame+10` passed on both IPAs.
- **Done: 2e** (host and phone; [evidence](../evidence/2026-10-13-touch-controls-phase2e.md)).
  `57951b2`: the right stick starts past an anti-dead-zone (`gyro.antiDeadZone`, 0.27, per game;
  its row only for Right stick). `4de3a2b`: touches outside the shown controls are ignored
  (HostIOKit `TouchRoute`), and the "Gyro aim" chip shows 2.5 s as gyro aim starts or its source
  or output changes (PlayportKit `GyroChipCue`). `bd13674`: the phone gyro's default sensitivity is
  1.5×. Dev IPA `1acd7cab…`. On the phone: Hollow Knight `first-frame+10` passed; in Portal 2's
  first map a touch on the right stick turned the view, the driver's taps outside the controls were
  ignored (no change), the chip showed at the start and was gone 2.4 s later, and right-stick
  `yaw=30@1000` (peak 0.45) now turns the view (0.36 still does not). The background bug is
  PLA-338, not the controls. The 125 Hz cap is unchanged.
- **Done: 2f** (host and phone; [evidence](../evidence/2026-10-13-touch-controls-phase2f.md),
  [phone](../evidence/2026-10-13-touch-controls-2f-3c.md)). On the phone (IPA `7566e31a…`, with the
  owner's DualShock 4): polling reads 65–67/s, the same as GameController's callback, so the pad
  delivers about 65/s. Flat, the acceleration reads `0.01 -1.03 0.03`: Apple's header frame is
  right, so no mapping fix. Calibrated within 2 s (was 18.7 s). A hand-turned 90° in player
  space counted about 81°. The yaw run fell back to the phone (the pad had dropped off), so it
  was not compared. The 125 Hz cap stays (the owner decides at the sign-off). Host work: `c9dc6c3`: a pad's gravity
  estimated from its acceleration (HostIOKit `GyroGravityEstimate`), and GyroAim's first bias
  after 0.5 s still. `23709dd`: a controller's `GCMotion` polled at 500 Hz on gyro aim's queue
  instead of its main-thread handler (about 65/s from the DualShock 4), with dev lines giving
  the polled rate beside the handler's and the pad's gravity in the aim frame. Dev IPA
  `1db2c6ec…` built, not installed. No controller-specific sensitivity.
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
  3. **2c, done:** UI: the Gyro aim page and its test area, the in-game panel's gyro switch and
     sensitivity, the overlay chip.
  4. **2d (phone), done:** the relative-mouse spike on Portal 2 (`app-620`) in mouse and
     right-stick modes, plus Hollow Knight `first-frame+10`. If the spike fails, a fix
     chunk follows. Also **measure the gyro event timing** (owner, 2026-10-13): the
     iPhone's real device-motion rate (and whether raw gyro goes higher), a controller's
     gyro rate if one is connected, `winios_pointer` moves per second and per frame
     with the 125 Hz coalescer, the delay it adds, and the ring's fill. The owner then
     decides on the cap (keep 125 Hz, or pass every controller sample at about 250 Hz).
  5. **Phase 2 owner play, in progress:** mouse mode with the phone's gyro "feels great"
     (owner, 2026-10-13). Owner decisions from the play, settled:
     - **Right stick stays, with an anti-dead-zone.** Mouse stays the default. Right-stick
       output starts past an anti-dead-zone (default about 27%, XInput's right-stick dead
       zone 8689/32767), adjustable per game on the Gyro aim page. Its purpose is games with
       no mouse look.
     - **Touches outside the controls are ignored while the on-screen controls show:** no
       cursor jump and no click. A stray touch flicked the view in a mouse-look game. With
       the layout Off, touch is a mouse as before. This replaces phase 1's tap-as-click
       fall-through for the Gamepad layout.
     - **The "Gyro aim" chip shows briefly** (a few seconds, then fades) when gyro starts:
       the game starts with it on, it is turned on in the menu, or its source changes.
     - **DualSense capture:** the supervisor runs `pp perf --keep-log` on Portal 2 while the
       owner plays with a DualSense, for the controller's `sensor rate:`, Auto's choice and the
       coalescing delay. The owner then decides the 125 Hz cap.
     - **Bug:** after sending the app to the background and coming back, the on-screen
       controls stopped working while the three-finger tap still worked. 2e found the cause
       outside this plan: the Vulkan device is lost in the background because KosmicKrisp's
       queue commits outside the GPU gate, so the game stops presenting. Tracked in
       [PLA-338](https://linear.app/playportdev/issue/PLA-338); not fixed here.
     - **Phone gyro default sensitivity 1.5×** (owner, after playing with the phone's gyro
       again: "feels much better but needs ~1.5x"). The 1.0× scale keeps its meaning. In 2e.
     - **Controller capture (2026-10-13, IPA `fe0110ab…`, log
       `.work/perf-runs/pla13-dualsense-p2/pulled/s1-host.log`; the owner stopped the
       `pp perf` run early, so only the app log was pulled):** the pad was a DualShock 4
       (`rotation rate yes, gravity no`), and Auto picked it. Its samples reached gyro aim at
       only **about 65/s** (`sensor rate: 64.7/s`, `66.2/s`), not the pad's own rate, so the
       cap never applied (delay 0 ms). Its bias (about 0.03 rad/s, 1.7 °/s) was learnt only
       some time into play. The owner found it too slow (set 2–2.5×) and laggy compared with
       the physical right stick; mouse mode with the phone's gyro feels great.
  6. **2e (fix), done** (see "Done: 2e" above)**:** the three decisions, the 1.5× default and the background diagnosis above; one short
     phone session.
  7. **2f (controller gyro), done** (see "Done: 2f" above)**:** Deliver the controller's motion off the main thread, near its
     own rate, with better timestamps. Derive gravity for a pad without it from low-passed
     acceleration, not raw acceleration. Check the DualShock/DualSense axis mapping and
     scale against the phone (the same physical turn should give the same counts), and
     consider a source-specific default sensitivity. Host tests first, one short phone
     session, then the owner's phase 2 sign-off (phone gyro and controller). The 125 Hz cap is decided
     after 2f measures the new rate.
  8. **3a, host done (no phone run):** `6e5a087`: PlayportKit `ControllerMap` (`controller` |
     `keyboardMouse` | `custom`, versioned, per game in `GameControls.controllerMap`, default
     `controls.controllerMap`; d-pad up/right/down/left = 1–4), HostIOKit `ControllerBindings`,
     `MappedPad` (keys, mouse buttons, wheel repeat, stick and trigger hysteresis 0.5/0.4,
     stick to mouse: dead zone 0.15, t² curve, 2000 counts/s, remainder carried) and the
     mixer's mapped pads (slot at rest but for `pad:` actions; the menu or a dialog releases
     them; the controls' pad never mapped). `d322113`: the app resolves the game's map at once on a
     change; `InputClock`, one `CADisplayLink` for the continuous sources; `pp ui --controls`
     `"controllerMap"`; the `controls: controller map MODE for PAD (slot N)` log line. Dev IPA
     `1e83233a…` built and verified, not installed. The owner allowed phase 3's host chunks
     (3a, 3b) to start while the phone is paused (2026-10-13). 3c and the phase 3 sign-off
     still wait for 2f's phone session and the owner's phase 2 sign-off.
  9. **3b, host done (no phone run):** the Controller page and the ActionPicker. Owner,
     2026-10-13: the preset's d-pad stays clockwise from up (1 up, 2 right, 3 down, 4 left), and
     the right stick's mouse-look speed becomes a per-game "Look speed" row (Keyboard & mouse
     and Custom; Y resets it). `a98d901`: Look speed, `GameControls.lookSpeed` over
     `controls.lookSpeed` (1× = 2000 counts/s, 0.25–4×), applied in place. `cde4ead`: PlayportKit
     `ActionPicker` and the page's model (`ControllerMapPage.swift`: a row's Y back to the preset,
     Reset all and Edit a copy asking first), the in-game Controller row's model. `c30de5e`: the
     Controller page (Game options' `opt:controllerMap`, Settings' `set:controllerMap`; X, LB, RB,
     View, Menu, LT, RT, L3, R3 and the right stick ring their rows), the ActionPicker (a PadModal;
     X waits for a hardware key), the in-game Controls panel's Controller row while a controller is
     connected (its rows scroll where they do not fit), `open:ID#controller`,
     `open:settings#controller`. Dev IPA `2c985b4d…` built and verified, not installed. **Next:** the
     phone sessions once the owner unpauses it: 2f's, then 3c.
  10. **R (review fixes), host done:** two read-only reviews of `412de5f..16ffafc` (owner
     asked, 2026-10-13; reports under `.work/agent-notes/pla-13-v2/review/`) found no blocker;
     their findings are fixed with host tests. `5a19de4`: `controls.games` read record by record
     (PlayportKit `GameControlsRecords`): an unreadable record is written back untouched, and
     reading never writes. `33dd958`: a pad button mapped to `playport:menu` is not read again
     as a menu press (`QuickMenuControl.opened(holding:)`); non-finite gyro samples dropped;
     mapped pads held while the guest's windows take the pads' presses before the first frame;
     a controller's gyro aim keyed on the pad; the mapped wheel only while active; GyroAim
     outside the pad lock; a chord over its key already down sends key up, modifiers, key.
     `3159bdd`: the gyro chip in its own view (shown with the layout Off or a controller
     connected too); Y over an edited Custom table asks first (`ControllerMapConfirm.useDefault`);
     Reset all's Keep changes nothing; the Controller row's "Default ·"; two stale texts.
     Two sources sharing one key or button release each other early: a note only, tracked in
     [PLA-339](https://linear.app/playportdev/issue/PLA-339). Dev IPA `7566e31a…` built, verified and
     installed ([evidence](../evidence/2026-10-13-touch-controls-R.md); Hollow Knight
     `first-frame+10` passed). **R done (host).** The combined 2f + 3c phone session
     (`.work/agent-notes/pla-13-v2/phone-session-R.sh`, with gates for the owner's controller
     steps and the scripted pad's slot) stopped after the install and the smoke run. **R done:**
     its 2f and 3c phone parts ran in the session recorded in
     [2f and 3c](../evidence/2026-10-13-touch-controls-2f-3c.md).
  11. **3c (phone), done** ([evidence](../evidence/2026-10-13-touch-controls-2f-3c.md)): the
     Controller page, the ActionPicker and Settings' page drawn as designed. Portal 2 with the
     scripted pad (slot 0) in `keyboardMouse` walked, strafed, looked, and opened and closed its
     pause menu with START. Held RT plus Home opened Playport's menu, and nothing leaked. In
     `controller` mode the pad played as before. The in-game panel showed its Controller row
     without scrolling. `lookSpeed` 2× applied (its counts were not measured). Seen, not fixed:
     the panel's "Controlle / r" wrap and the page's truncated Look speed row. Hollow Knight
     `first-frame+10` passed. **Next (queue head): the owner's phase 2 sign-off (phone and
     controller gyro, the 125 Hz cap) and phase 3 sign-off.**
  12. **Owner play after 2f/3c (2026-10-13), settled:**
     - The controller's gyro still feels a little delayed next to the phone's ("not major";
       the phone's is perfect). **Smoothing becomes a per-game row** on the Gyro aim page:
       Off / Light / Normal. Controllers default to Off, the phone keeps Normal.
     - Keyboard & mouse plays Portal 2 but can't drive its menus. **The preset's d-pad
       presses the arrow keys** (Up, Down, Left, Right) instead of 1–4; this supersedes the
       earlier "1–4 clockwise". A stays Space.
     - Choosing Custom in the in-game menu changes nothing visible, and the editor isn't
       reachable there. **The in-game Controls panel opens the full Controller page and the
       ActionPicker over the paused game;** choosing Custom goes straight into the editor.
     - **The Controller page's navigation is reworked** (owner: "some buttons can't be
       reached, LB/RB don't change the mode, B goes back instead of editing B"). The left
       stick and d-pad ring every row; A edits the ringed input; B goes back; Y resets the
       row; LB/RB cycle the mode at the top. This supersedes 3b's "press a physical button
       to select its row".
  13. **U (fixes from the owner's play), done** ([evidence](../evidence/2026-10-13-touch-controls-U.md);
     dev IPA `5faec414…`, installed). `3052fe5`: the gyro Smoothing row (Auto, Off, Light,
     Normal; Auto is Off for a controller, Normal for the iPhone). `01942c9`: Keyboard &
     mouse's d-pad presses the arrow keys; Portal 2's Esc menu moved with them on the phone.
     `c3920bd`: the Controller page's ring (PlayportKit `ControllerMapNav`: every item in every
     mode, LB/RB the mode, A edits with "Edit a copy?" or "Switch to Custom?" first outside
     Custom, Y resets, B back), which **supersedes 3b's press-a-button-to-ring-its-row capture**
     (removed); the in-game Controls panel opens the full Controller page and its ActionPicker
     over the paused game (A on the Controller row, its "Edit controller…", or choosing Custom);
     and the cosmetic list below (the scripted pad is named "Scripted pad" in dev). Hollow
     Knight `first-frame+10` passed; both games' own controls restored by DriverUndo. **Next
     (queue head): the owner's phase 2 and phase 3 sign-offs.**
  14. **Phase 2 and phase 3 signed off by the owner (2026-10-13)** on dev IPA `5faec414…`.
     Phases 1–3 are done and merged to `main` (`631bd7f`); this run stopped here. Phases 4+ are not started; follow-ups:
     PLA-338 (Vulkan device lost in the background), PLA-339 (shared held keys release
     early), PLA-340 (arrow keys without the extended flag).
- **Phone:** dev IPA `5faec414…` (U) installed; unattended mode off (the owner is at the
  phone). Both games keep the owner's own controls, restored by DriverUndo after the 2f/3c
  session: Portal 2 Gamepad, right stick Below, gyro Mouse 1.5×; Hollow Knight Gamepad 60%,
  d-pad on, right stick Below. Hollow Knight's profile slot 3 may hold a King's Pass save
  rather than New Game (check it before a measured run that uses `tools/pad/hk-new-slot.txt`).
- **Settled after 2f (supervisor, 2026-10-13):** keep the 125 Hz cap (the DualShock 4 gives
  about 65/s and the phone 100/s, so neither reaches it), and keep the 500 Hz `GCMotion` poll
  (the same rate as the handler, but off the main thread).
- **For the next fix chunk (seen in 3c, cosmetic):** the in-game panel's "Controller" label
  wraps; the Controller page's Look speed row and the in-game Controls value are truncated;
  the ActionPicker's footer hints overlap the page while it waits for a key; the in-game
  Controller row says "None" with the scripted pad; the 3c script loses the pad steps' app
  log (keep it next time).
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
  `GameSurfaceView`, which keeps today's tap-as-click. *Superseded (owner, 2026-10-13,
  Run state queue item 5): while the controls show, touches outside them are ignored; a
  three-finger tap opens the menu.*
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

*Superseded in part: phase 6 writes it (as 0105) from the owner's decisions in Run
state, which replace this list where they differ.*

- automatic display
- the Playport button as a second way to open the in-game menu. This adds to 0034,
  where only Home opens it. *Superseded (owner feedback on phase 1, item 4): no
  Playport button; a three-finger tap anywhere opens the menu.*
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
  This is acceptable for Gamepad; Point & click has no zone. *Superseded (owner,
  2026-10-13, Run state queue item 5): touches outside the shown controls are ignored;
  with the layout Off, touch is a mouse as before.*
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

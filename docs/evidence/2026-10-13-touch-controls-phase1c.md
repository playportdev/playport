# 2026-10-13: on-screen controls, phase 1c (the owner's feedback on 1b)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), "Owner feedback on 1b". **Commit:**
`7f6cd07` on `dev/pla-13-touch-controls`. Before: [phase 1](2026-10-13-touch-controls-phase1.md),
[1b](2026-10-13-touch-controls-phase1b.md).

**IPA (dev):** `.work/out/20261013-122033-67d0938d/Playport-26.5-67d0938d.ipa`, sha256
`67d0938d414b2755e5e3edfbf3ae1a8a2c2553575ccbe3a2082ce6d13226f3bd`, built from `7f6cd07`
(`pp build`, 86 verify checks passed; no build record changed), installed in place with
`pp install --no-build`. iPhone (iPhone18,4), iOS 27.0.1, built-in JIT.

## 1. Late controls when turned on in-game

**Cause: the game, not Playport.** With a game's layout Off, slot 0 had no pad
(`OnScreenControls` connected the controls' pad only while they were shown). Turning them on in
the in-game panel connected a new pad in slot 0 at once: the panel's change, `controls: shown`
and the first `host_pad_set` all happen on the main thread in the same turn, and Wine's XInput
reads the host snapshot on every call (patches/wine-port 0055, `host_pad_state`; no cache). Hollow
Knight did not act on a pad that connected after its start. [DEVICE.md](../DEVICE.md) already
notes this for controllers ("a Unity title does not see one that connects later").

**Shown on the 1b IPA** (`4cfadad8…`, before installing 1c; run `diag-old`): Hollow Knight started
with its layout Off (`controls: start: 0 controller(s) connected; Off, no controls' pad`), the
three-finger tap opened the menu, Controls › On-screen controls was set to Gamepad
(`menu: controls for app-367520: layout gamepad`, 12:23:24), and Resume
(`controls: shown (Gamepad, 60%)`, `menu: closed; back to Hollow Knight`, 12:23:45). Then four
left-stick-down presses, each logged as reaching slot 0 (`controls: driver holds leftStick for 300
ms: ... ly=-32768`), at 12:23:56, 12:24:17, 12:24:56 and 12:25:54, that is 11 s to 129 s after
Resume. The screenshots after each press (`action-08`, `-10`, `-12`, `-14`) all show the main
menu's selection still on Start Game: the game took none of them in over two minutes.

**Fix (the plan's conservative choice):** the controls' pad is player 1 from the runtime's start
whenever no controller is connected, at rest while the layout is Off (PlayportKit
`ControlsState.padConnected`; `OnScreenControls` publishes it). Turning the controls on in-game is
now only an overlay change. A controller connecting still takes slot 0 (Automatic), and Always
with a controller connected merges as before. **Risk:** with the layout Off and no controller, a
game sees a pad connected and may show pad prompts or prefer pad input; Off still draws nothing.

**Shown on the 1c IPA** (run `ingame`): `controls: player 1 is the controls' pad (Off)` and
`controls: start: 0 controller(s) connected; Off, player 1 is the controls' pad` at the launch;
Gamepad chosen in the panel at 12:29:36, Resume at 12:29:57 (`controls: shown (Gamepad, 60%, d-pad
off, right stick off)`); the first left-stick-down press at 12:30:08 (11 s after Resume, the time
the driver takes its screenshots) moved the selection to Options (`action-08`), the second at
12:30:30 to Achievements (`action-10`). Each press reached the game on the first try.

## 2–4. The layout

- **Same size:** the d-pad and A/B/X/Y are each a 120 × 120 point square. The four face buttons
  sit in its middle row and column, each hit over its own 40-point square, side by side without
  overlapping (the square's corners and middle are the game's). Both are drawn 2 points inside what is hit, so a face button (36 points) and a d-pad arm
  (about 38) look alike. Before: the d-pad hit 116 / drawn 100, A/B/X/Y a 156-point diamond of
  52-point squares.
- **D-pad and right stick off by default**, per game in the in-game Controls panel (rows D-pad:
  Off, On; Right stick: Off, Below, Above), defaults in Settings › Controls (`controls.dpad`,
  `controls.rightStick`), applied at once. The d-pad is centred above the left zone; A/B/X/Y are
  centred where the right zone's middle is (105 points in from the safe area's right edge); with
  Below the right zone takes the lower right corner and A/B/X/Y sit 12 points over it; with Off and
  Above A/B/X/Y take the corner, and Above puts the zone 12 points over them. Zones are 210 × 126
  points (Above 210 × 120), so every option fits the 5.4-inch safe area (712 × 354) with the
  12-point gap to the zones and nothing overlapping; `ControlZone` gained an offset (`x`, `y`, 0
  when left out), so the layout format stays version 2 and older layouts read the same. A game
  saved before reads the new options as the defaults.
- **No outlines** on the zones.
- **Driver:** `--controls`/`controls:` take `"dpad":"off"|"on"` and
  `"rightStick":"off"|"below"|"above"`; `pp ui --help` says so.

## Host

`pp test` passed (PlayportKit 251 tests, among them `ControlLayoutTests`
`testThePresetFitsEveryScreenWithZonesClearOfTheControls`, which checks all six d-pad × right-stick
choices on the seven screens, both insets and one-sided insets: inside the safe area, no
overlaps, the 12-point gap to every zone, the d-pad centred over the left zone, the right zone
centred on A/B/X/Y below or above them and A/B/X/Y in the corner for Off and Above;
`testTheZonesAndTheirNeighboursHitWhereTheyAreDrawn`; `ControlsSettingsTests`
`testTheControlsPadIsConnectedWhileNoControllerIs` and
`testTheDpadAndRightStickFollowTheGameThenTheDefaults`; HostIOKit 67; `tools/tests/test_ui.py`).
`pp check` and `pp check --variant release` compile.

## Phone

One `pp phone lock` session. Hollow Knight's own layout on the phone is Off (the owner's); the
session's first run saved Off with `--controls`, which records that value, so the app puts the
owner's setting back at its next launch outside the session, whatever the in-game panel saved.
Run directories, under `.work/agent-notes/pla-13-v2/runs1c/`:

| Run | IPA | Result |
| --- | --- | --- |
| `save-off-old`: `--controls` Off | 1b `4cfadad8…` | ok |
| `diag-old`: Off, Gamepad in the panel, four presses over 129 s | 1b `4cfadad8…` | ok actions=15; no press reached the game |
| `pp install --no-build` | 1c `67d0938d…` | upgrade in place, container kept |
| `save-off-new`: `--controls` Off | 1c | ok |
| `smoke`: Hollow Knight `--until first-frame+10 --shot` | 1c | ok; first frame at +9.84 s |
| `ingame`: Off, Gamepad in the panel, presses; then D-pad On + Right stick Below; then Above | 1c | ok actions=32 |
| `settings`: Settings › Controls | 1c | ok actions=4 |

What the screenshots show (they stay in the run directories):

- `smoke/screen-stop.png`: Hollow Knight's main menu, no controls drawn (layout Off).
- `ingame/action-07`/`-08` (default: d-pad Off, right stick Off): LT/LB, View, Menu, RT/RB at the
  top, the left stick resting in the lower left, A/B/X/Y as a compact diamond in the lower right
  corner; no d-pad, no right stick, no zone outlines.
- `ingame/action-19`/`-20` (D-pad On, Right stick Below): the d-pad above the left stick, the right
  stick resting in the lower right corner with A/B/X/Y above it, the d-pad and A/B/X/Y the same
  size. `touch:dpad.up` moved the selection back up (`buttons=0x0001`).
- `ingame/action-27`: the panel with On-screen controls Gamepad, D-pad On, Right stick Above ringed,
  Opacity 60% and the note under them; it fits beside the menu's rows.
- `ingame/action-29`/`-30` (Right stick Above): A/B/X/Y in the lower right corner, the right stick
  resting above them, centred on them. `touch:rightStick.left` gave `rx=-32768`.
- `settings/action-01`: Settings › Controls with D-pad Off ("Above the left stick") and Right stick
  Off ("Where it goes beside A/B/X/Y") between Opacity and the haptics switch.
- **Frame rate:** 60 fps in each layout's stretch of `[frames]` in `ingame`.

**Not checked here (the owner's sign-off):** the clusters' size and the face buttons' 40-point hit
squares under real thumbs; either landscape orientation other than the phone's (the driver cannot
turn the phone; the host tests cover both sides' insets); whether Hollow Knight shows pad prompts
while the layout is Off; a controller connecting mid-game, then leaving (slot 0 goes back to the
controls' pad).

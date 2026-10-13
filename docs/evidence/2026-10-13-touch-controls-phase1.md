# 2026-10-13: on-screen controls, phase 1 (the Gamepad layout and the Playport button)

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), phase 1. **Commit:** `b784617` on
`dev/pla-13-touch-controls`.

**IPA (dev):** `.work/out/20261013-103922-3911e0fa/Playport-26.5-3911e0fa.ipa`, sha256
`3911e0fafacf918d4d21b3300b378e3e55c1227dad17924802140fecb37a3ecf`, built from `b784617`
(`pp build`, 86 verify checks passed), installed in place with `pp install --no-build`. iPhone
(iPhone18,4), iOS 27.0.1, built-in JIT.

**Host:** `pp test` passed (HostIOKit 65 tests, among them `TouchControlsTests`,
`InputMixerTests`, `InputActionTests`; PlayportKit 248, among them `ControlLayoutTests`,
`ControlsSettingsTests`, `QuickMenuTests`; `tools/tests/test_ui.py`). `pp check` and
`pp check --variant release` compile; the release executable `pp check` wrote names none of
`verify-ipa.py`'s dev strings, `UI_CONTROLS` (added to them) included.

**Phone:** two batched sessions, each one `pp phone lock`. Run directories, under the build area:

| Run | Directory | Result |
| --- | --- | --- |
| Hollow Knight smoke, `--until first-frame+10 --shot` | `.work/agent-notes/pla-13-v2/runs/smoke` | ok; first frame at +9.96 s |
| Hollow Knight by `touch:` only: menus, the Playport button, the in-game menu's Controls, Resume | `.work/agent-notes/pla-13-v2/runs/touch` | ok actions=17 |
| Hollow Knight with the scripted pad (`--pad`), `first-frame+10` | `.work/agent-notes/pla-13-v2/runs/pad` | ok |
| Settings › Controls, `open:settings#controls` | `.work/agent-notes/pla-13-v2/runs/settings` | ok |
| Hollow Knight by `touch:` only: a new game, then walking with the d-pad and the stick, jumping and attacking | `.work/agent-notes/pla-13-v2/runs2/walk` | ok actions=75 |

What they show (the screenshots stay in the run directories):

- **The Gamepad layout over the game** (smoke, `screen-stop.png`): the Playport button top centre
  between View and Menu (dimmed after 3 s), LT and LB at the left, RT and RB at the right, the
  d-pad, the left stick in the lower left, the right stick and A B X Y at the lower right, as
  `TouchGamepad.dc.html` draws them, over Hollow Knight's main menu. The log:
  `controls: start: 0 controller(s) connected; Gamepad · 60%, player 1 is the controls' pad`,
  then `controls: shown (Gamepad, 60%)` at the first frame.
- **Menus by touch** (touch, `action-04`, `action-06`): `touch:a` chose Start Game, then the
  profile screen's ringed slot (New Game, slot 3), and the prologue started. Each press is logged
  as the slot-0 pad it made, e.g. `controls: driver holds a+dpad for 600 ms: buttons=0x1008`.
- **Walking, jumping and attacking by touch** (walk): the Knight in King's Pass at 90 s; at 104 s
  he has walked right with the d-pad's right lit amber; at 108 s further right with the left stick
  held right (its nub amber and over); at 112 s facing and walking left with the d-pad's left lit,
  Hollow Knight's own "X Attack" prompt shown (it reads an Xbox pad). The jumps (`touch:a`,
  `touch:dpad.right+a`) were pressed between screenshots; no screenshot caught the Knight in the air.
- **The Playport button opens the in-game menu** (touch, `action-12`): `controls: playport down`,
  `controls: hidden (menu)`, `menu: open over Hollow Knight`, `menu: pause -> 0, 68 threads`; the
  menu shows Resume, Controls (`Gamepad · 60%`), Screenshot, Performance overlay, Controller (None),
  Quit game. `menu:controls` (`action-13`) opens the Controls panel: On-screen controls Off |
  Gamepad (Gamepad on), Opacity ‹ 60% ›, ringed amber; `pad:b` closed it.
- **Resume gives the controls back** (touch, `action-15`, `action-16`): `menu: closed; back to
  Hollow Knight`, `controls: shown (Gamepad, 60%)`, and the next `touch:dpad.right@1000` reached the
  game (`buttons=0x0008`), the controls drawn again over the cinematic.
- **A connected controller hides them** (pad): with the scripted pad in slot 0,
  `controls: start: 1 controller(s) connected; Gamepad · controller connected, no controls' pad`,
  no `shown` line, and the screenshot at first-frame+10 is Hollow Knight's menu with no controls.
- **Settings › Controls** (settings, `screen-stop.png`): the section list says Controls; On-screen
  controls ‹ Automatic › (Shown while no controller is connected), Opacity ‹ 60% ›, A tap you can
  feel (on), the note on the in-game menu and the Playport button, and No controller.

**Frame rate with the overlay:** Hollow Knight held its 60 fps limit with the controls drawn: the
`[frames]` counts give 60.0 fps in every 2 s window of the smoke run's main menu and of the walk
run's last 60 s of play, as in the scripted-pad run with no controls. The glass's backdrop blur shows
no cost at this limit, so the plan's `pp perf` A/B was not run (no headroom above 60 fps was
measured).

**Not checked here:** a person's own fingers (several at once, haptics, the floating stick from a
real thumb), the first-time toast on screen (it shows for 6 s at the first frame, before the smoke
run's screenshot), a real Bluetooth controller connecting and disconnecting during a game, and
`Always`/`Never` and the per-game Off on the phone (host tests cover their rules).

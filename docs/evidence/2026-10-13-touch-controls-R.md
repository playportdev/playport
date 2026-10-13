# 2026-10-13: touch controls R (review fixes), host, plus one install and smoke run

**Linear:** [PLA-13](https://linear.app/playportdev/issue/PLA-13). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), queue item 10 (R). Before:
[2f](2026-10-13-touch-controls-phase2f.md). Branch `dev/pla-13-touch-controls`.

| IPA (dev) | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-7566e31a.ipa` | `7566e31a77d277e71acc08ace4db220ac5ffe7529bb3a0daa400af7dc7e0ccf7` | `3159bdd` |

`pp build` passed (86 verify checks, 0 failed). `pp test` passed (HostIOKit 125 tests,
PlayportKit 294). `pp check` passed for dev and release.

## What changed

| Commit | Change |
| --- | --- |
| `5a19de4` | `controls.games` is read record by record (PlayportKit `GameControlsRecords`). An unreadable record is written back untouched, and reading never writes. |
| `33dd958` | Input fixes for review findings F2–F8: a pad button mapped to `playport:menu` is not read again as a menu press; non-finite gyro samples are dropped; mapped pads are held while the guest's windows take the pads' presses; a controller's gyro aim is keyed on the pad; the mapped wheel works only while the app is active; GyroAim runs outside the pad lock; a chord sends the key up, then the modifiers, then the key. F9 is [PLA-339](https://linear.app/playportdev/issue/PLA-339). |
| `3159bdd` | UI fixes: the gyro chip gets its own view; Y over an edited Custom table asks first; "Keep my changes" changes nothing; the Controller row shows "Default ·"; two stale texts. |

## On the phone

The phone came back briefly. One `pp phone lock` session started the combined 2f and 3c
script, `.work/agent-notes/pla-13-v2/phone-session-R.sh`. The owner then paused phone tests
again, so the session ended after its first two steps:

- `pp install --no-build`: exit 0. The installed IPA is the one above (`7566e31a…`).
- Hollow Knight (`app-367520`) `first-frame+10`: passed.
  - Timeline: JIT acquired in 2.43 s, runtime started at +3.67 s, first frame at +9.10 s.
  - Pool: no exhaustion.
  - The screenshot shows the title menu with the Gamepad controls drawn, d-pad included. No
    controller was connected (`controls: start: 0 controller(s) connected; Gamepad · 60%`).
  - Run directory: `.work/agent-notes/pla-13-v2/runsR/hk-smoke`.
- The session saved no settings or controls: Portal 2's settings and controls are untouched.
- Hollow Knight's own controls were already drawn as Gamepad before this session. The plan
  expected them Off. This session did not change them.

**Not run (owner paused):** the 2f part, i.e. the DualShock 4's rates, gravity frame and
calibration time. **Not run:** the 3c part (the controller map on Portal 2, the Controller page,
the ActionPicker, the in-game Controller row). The script keeps both, with gates for the owner's
steps and for the scripted pad's slot when a real controller is connected.

Games observed: Hollow Knight (`app-367520`), first-frame+10 passed.

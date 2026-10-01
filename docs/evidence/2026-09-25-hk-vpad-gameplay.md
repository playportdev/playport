# Hollow Knight driven by a scripted pad: gameplay metrics with nobody at the phone

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-25. **Tree:** the commit that adds the scripted pad
(`app/HostIOKit/Sources/HostIOKit/VirtualPad.swift`, `VirtualPad` in
`app/Sources/S1Probe/HostIO.swift`, `harness/device/vpad.py`,
`perf-run.py --vpad`, `harness/device/vpad/*.txt`). **Build:** lane builds
(`--from stage`) of that tree against the DXMT and FEX trees of the
`profile-seed` lane, so their DXMT/FEX PE hashes differ from the committed
`app/artifacts.tsv` (path-dependent builds; no source difference):
run `vpad1` on IPA sha256
`d0164c0197deb2560ed72c1ae658aae01d7f6d7586f948efb440d0a43ec4038f`, run
`vpad2` on `fbdb311ec26ca8c715fb582efb691b435de28b5205f730df734a62f571693f70`
(adds wall-clock times to the `vpad:` lines and one-`writev` log lines).
**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, on a 15 W
charger, warm from earlier runs; every run under
`flock $PLAYPORT_BUILD/device.lock`.

**Result:** a launch with `HIO_VPAD=vpad.txt` gets a controller Hollow Knight
accepts, and scripts pushed from the workstation took the game from the main
menu to the Knight walking, jumping and slashing in King's Pass with no one
touching the phone (`vpad2`, fully unattended). In gameplay the game runs at
38 to 55 FPS where the menu holds 120 in the same thermal state, and it is
CPU-bound: the process gets no P-core time at all, runs 2.1 to 2.5 E cores
at 1.1 to 1.7 GHz, and the frame interval (18 to 26 ms) is well above the GPU
time (10 ms for the first minute of play, 17 ms once the GPU clocks down).

## 1. Driving

`perf-run.py --secs 180 --shot 44 --shot 80 --shot 110 --shot 170
--vpad 45:harness/device/vpad/hk-new-game.txt --vpad 85:harness/device/vpad/hk-walk.txt`
([DEVICE.md, "Driving a title"](../DEVICE.md#driving-a-title)). The pushes
landed 48 s and 88 s after launch; `vpad2-pad-lines.txt` has the steps as
the app played them. The Start Game press was at 02:55:01.9 and King's Pass
drew its first frame at 02:55:49.8: the opening cinematic is a video Wine's
Media Foundation cannot open (player log: `WindowsVideoMedia error
0xc00d36c4 ... The byte stream type of the given URL is unsupported`), so
the screen is black (`vpad2-shot-080.jpg`) until A presses skip it. At 110 s
the Knight is slashing grass (`vpad2-shot-110.jpg`), at 170 s jumping
(`vpad2-shot-170.jpg`). `vpad1` was the same route pushed by hand with
`vpad.py send`, which is how the menu sequence was found.

## 2. Menu against gameplay

From `vpad2-summary.txt` (5 s buckets, `t` from the first HUD line; the phone
was already at thermal pressure 10 at launch):

| phase | t (s) | FPS | frame ms | GPU ms | P cores | E cores | E GHz | pressure / limit |
|---|---|---|---|---|---|---|---|---|
| menu | 45–65 | 120 | 8.34 | 6.4–6.6 | 74–77 % | 30–33 % | 2.0–2.5 | 20 / 5–6 |
| play, first minute | 80–120 | 38–48 | 21–26 | 9.7–10.5 | 0 | 215–249 % | 1.1–1.4 | 20 / 6 |
| play, after | 125–170 | 49–55 | 18–20 | 16.5–18.4 | 0 | 214–244 % | 1.3–1.7 | 20 / 6 |

`vpad1` (`vpad1-summary.txt`) shows the same shift: the menu at pressure 20
held 120 FPS from 70 to 160 s with the P cores busy, and the moment gameplay
loaded (175 s) the P share fell to 0 and stayed there to the end of the
600 s run (57 to 66 FPS, 225 to 250 % E).

## 3. What it means

- The menu's drop (evidence `2026-09-25-hk-thermal-baseline`) and the
  gameplay drop are not the same problem. In play, the game needs more than
  two cores of CPU per 120 frames and the scheduler gives it only E cores
  once the phone is warm, so even a cold GPU cannot help. Stable 120 FPS in
  play needs the CPU work per frame cut severalfold, not only a lower GPU
  load.
- Hitches: the first seconds of every new scene have frames of 150 to 350 ms
  (`ftmax`), which is where shader compilation and asset loading show.
- Next: per-thread CPU in gameplay (which guest and host threads the 230 %
  is), measured from a cold start with this script.

# Hollow Knight at 120 Hz: the drop to 40 to 80 FPS is thermal

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-25. **Tree:** the commit that adds
`harness/device/perf-run.py` and `harness/device/rotate-host-log.py`; no app
or runtime change. **Build:** the IPA installed on the phone at the time, from
the tree of `d1d8f03` (built-in JIT); it was not rebuilt or reinstalled for
these runs, and its sha256 was not recorded. **Phone:** iPhone Air
(`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, on a 15 W charger, every run
under `flock $PLAYPORT_BUILD/device.lock`.

**Result:** with nobody touching the phone, Hollow Knight on its main menu
holds 120 FPS at the panel's native 2736x1260 for 35 to 60 s, then falls to 40
to 80 FPS and stays there. The drop is the thermal pressure level reaching
20 (moderate): at that moment the process loses the P cores entirely, the E
cores go to their lowest clock (0.82 GHz) and the GPU time per frame rises
from about 6.6 ms to 15 to 26 ms. The same menu rendered at 1564x720
(`HOST_SCREEN=720`) held 120 FPS for the whole of a 300 s run, with the
pressure reaching only 10 (light). The drop reproduces without gameplay, so it
can be measured with no one at the phone.

## 1. How it was measured

`harness/device/perf-run.py` ([DEVICE.md, "Measuring a
title"](../DEVICE.md#measuring-a-title)): a `title-device-run.py` launch with
`MTL_HUD_LOG_ENABLED=1`, the app killed after `--secs`, and a 5 s table from
three sources that exist in the shipped build:

- the Metal HUD's once-a-second log line: frame counter, Metal and app memory,
  then a (frame interval, GPU time) pair per frame. The device syslog redacts
  everything after the memory figures; the copy on the app's stderr
  (`s1-host.log`) is complete;
- the runtime's `[xp]` census every 250 ms (Madeira `server_ios.c`
  `ios_xprobe_main`): CPU time on P and E cores and each cluster's clock;
- thermalmonitord's `Thermal pressure level` and `mTLL` lines and the kernel's
  CPMS `Budget Trace`, from the device syslog.

Runs were five to nine minutes apart; the phone was never fully cold.

## 2. Runs

| Run | Environment | 120 FPS until | Then | Pressure |
| --- | --- | --- | --- | --- |
| base1 | the app's default | 60 s | 55 to 73 FPS | not captured |
| quiet2 | `MADEIRA_QUIET=1 WINEDEBUG=-all` | 40 s | 38 to 85 FPS, GPU 26 ms | budget 1985 mW from 60 s |
| native2 | as quiet2 | 50 s | 65 to 87 FPS | not captured |
| native3 | as quiet2 | 45 s | 63 to 81 FPS, GPU 15 ms | 10 at 35 s, 20 at 50 s |
| r720 | as quiet2, `HOST_SCREEN=720` | whole run (150 s) | | not captured |
| r720long | as r720 | whole run (300 s) | | 10 at 120 s, `mTLL` 1 at 280 s |

Every run has one 160 to 175 ms frame about 10 s in, as the menu loads, and a
few slow frames in the first second.

native3's system log around the drop
(native3-thermal-lines.txt):
Game Mode and CLPC's Sustained Execution Mode come on at launch; at pressure
10, powerexperienced sets new CLPC power targets ("Device in use and warm");
within ten seconds of pressure 20 the `[xp]` census shows P=0 for the rest of the
run and the limit level climbs to 5.

## 3. What this rules out and what it points at

- **Not the runtime's logging.** A default launch wrote 6.4 MB of
  `s1-host.log` in 2.5 min and a quiet one 3.6 to 5 MB; the drop came at
  the same point in both. (The 290 MB `s1-host.log` on the phone held every earlier
  launch in the container, appended; `perf-run.py` now moves it aside first.)
- **Not a leak or a stall.** App memory is flat at about 2.75 GB; there is no
  log event at the drop; frame time rises smoothly with the clocks.
- **Power is the lever.** Before the drop the game uses about 1.2 to 1.4 cores
  (P cores at up to 4 GHz, 550 to 750 mW by the process's own energy counter)
  and the GPU, at 120 frames a second. Keeping pressure below 20 means cutting
  that total: fewer pixels (the 720-row run), less GPU work per pixel in DXMT,
  and less CPU per frame (the runtime's always-on samplers, FEX-translated
  code). Gameplay will cost more than the menu.

## 4. Not yet done

- Gameplay: no input was sent. Moving the Knight needs a scripted input
  source, since no controller is connected and nobody is at the phone.
- Shader-compile stutter: not measured here; the menu shows one long frame
  at load.

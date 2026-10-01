# Hollow Knight: GPU load, and 540 rows

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-25. **Tree:** the commit that adds the `gpu%`, `ren%`,
`til%` columns and `--energy` to `perf-run.py`. **Build:** the lane build
from the [thread-QoS record](2026-09-25-hk-thread-qos.md), IPA sha256
`62e149af5ef540aa739592b89a08137958d4c2e64814d35be38ae0e7f52bb80f`. Another
session's job had its own IPA installed for a Witcher 3 launch; at 06:17:17 it
reinstalled this IPA and gave the phone back, before these runs. Every run
logged FEX build id `rev=ml908 compiled Sep 24 2026 23:29:34` and 28
`[thr-qos]` lines. **Phone:** iPhone Air (`iPhone18,4`, A19 Pro: 2 P + 4 E
cores, iOS 27.0), over netmuxd Wi-Fi, on a 15 W charger. Every run was under
`flock $PLAYPORT_BUILD/device.lock`.

**Result:**

- **The GPU is busy 76–80 % in gameplay at 720 rows.** Apple's GPU counters
  (`dvt graphics`) put the device at 76–80 % utilization and the tiler at
  64–69 % through King's Pass, against 40 % and 18 % on the save-slot screen.
  The Metal HUD's GPU time is 5.1–5.5 ms a frame, 61–65 % of the 8.33 ms
  frame. The counters cover the whole device, so the other 11–15 points
  are other GPU work, probably including the compositor's.
- **Gameplay's GPU time is half fixed, half per pixel.** At 540 rows
  (1172x540, 56 % of 720 rows' pixels) gameplay GPU time is 4.0 ms against
  5.1 ms, and the save-slot screen's is 1.34 ms against 2.46 ms (the screen
  is pixel-bound). A fit of gameplay's two points gives about 2.5 ms of
  per-frame GPU work that does not scale with pixels, plus 2.6 ms per 720
  rows. The tiler stays at 53–56 % at 540 rows. That points the fixed part at
  geometry and render-pass work rather than shading.
- **At 540 rows the run held 120 FPS to its end.** From t=105 s to 235 s
  every bucket was 117.2–120.2 FPS, the P cores stayed at 3.8–4.1 GHz and
  thermal pressure reached only 10 (at t=180 s). The same run at 720 rows
  reached pressure 20 at t=170 s and its P clock fell to 1.31–1.88 GHz at
  t=225–235 s. CPU work was identical (59.3 and 59.6 million instructions per
  frame), so the difference comes from the GPU.
- **Over 10 minutes at 540 rows the P cores stayed fast, but room changes
  stall.** In gpu540long (600 s) thermal pressure reached 10 at t=215 s and
  20 at t=435 s. The P clock stayed at 3.27–4.11 GHz until t=565 s, and the
  median bucket was 118.5–119.4 FPS in each third of the play. The 10-minute
  run at 720 rows in the [720-row record](2026-09-25-hk-720-gameplay.md)
  (g720long, an older build without the thread QoS setting) had its P clock
  at 1.31–1.33 GHz from t=210 s and a median of 108.7 FPS in its last 150 s.
  gpu540long also had five single frames of 600–1,540 ms, at t=311, 387, 463, 521 and 583 s. Four of them followed about 1 s of
  `Loading.PreloadManager` work on the E cores and then 0.3–0.6 s of the
  main thread alone on a P core, then Unity's `BatchDeleteObjects`
  and `AssetGarbageCollector` threads. That sequence is a room transition
  followed by an unused-asset sweep, and g720long's walk never showed it
  (its longest frame was 63 ms). The frame of 1,540 ms at t=311 s differs:
  the census's own 250 ms tick took 780 ms, 5,308 threads were waiting for a
  core, and two native threads were the busiest.
- **Xcode's energy gauge perturbs the title.** With `dvt energy <pid>`
  polling (about 10 samples a second), the save-slot screen had 26–37 frames
  over 8.5 ms per 5 s against 0–4 in the same run without it. The run also
  started warmer, so its frame rates are not comparable. The gauge rated the
  GPU at about 60 % of the CPU's cost in gameplay at 120 FPS (cpuE 780–890,
  gpuE 510–530), in its own units.

## 1. Runs

All runs used `perf-run.py --secs 240 --env HOST_SCREEN=<rows>
--vpad 48:harness/device/vpad/hk-new-game.txt --vpad 103:harness/device/vpad/hk-walk.txt
--env WINE_IOS_THREAD_QOS=UnityGfxDeviceWorker=utility,Job.Worker=utility,Background Job.Worker=utility,dxmt-=utility,Loading.=utility
--shot 200`, with the Metal HUD on and madeira.cfg absent, as in qos4 of the
[thread-QoS record](2026-09-25-hk-thread-qos.md).

| run | rows | extra | rest before | notes |
|---|---|---|---|---|
| gpu1 | 720 (1564x720) | | 5 min, after a 40 s Witcher 3 launch | `dvt graphics` only |
| gpu2 | 720 | `--energy` | 7 min, after gpu1 (pressure 20 at its end) | pressure 10 by t=40 s |
| gpu3 | 540 (1172x540) | | 10 min, after gpu2 (pressure 20, P at 1.31 GHz at its end) | |
| gpu540long | 540 | `--secs 600` | 10 min, after gpu3 (pressure 10 at its end) | |

`screens.txt` has the `title: display` lines of gpu1 and gpu3. The tables are
`gpu1-summary.txt`, `gpu2-summary.txt` and `gpu3-summary.txt`, and the
per-thread tables are `*-threads.txt`.

## 2. Phases

Averages of the 5 s buckets. "App GPU busy" is the HUD's GPU time times the
frame rate. In gpu1 and gpu3, t=15–30 s is the title menu, t=50–90 s the
save-slot screen, and from t=100 s King's Pass.

| run | phase | FPS | GPU ms | app GPU busy | device % | renderer % | tiler % | P GHz |
|---|---|---|---|---|---|---|---|---|
| gpu1 (720) | title menu | 118.8 | 5.27 | 63 % | 78.5 | 77.5 | 65.0 | 3.35 |
| gpu1 (720) | save slots | 119.6 | 2.46 | 29 % | 40.3 | 39.6 | 17.7 | 2.61 |
| gpu1 (720) | play t=100–165 | 119.6 | 5.14 | 61 % | 76.6 | 75.4 | 63.6 | 3.90 |
| gpu1 (720) | play t=170–235 | 119.0 | 5.48 | 65 % | 79.6 | 79.0 | 68.9 | 2.77 |
| gpu3 (540) | title menu | 118.9 | 3.86 | 46 % | 62.2 | 61.2 | 52.0 | 3.27 |
| gpu3 (540) | save slots | 119.5 | 1.34 | 16 % | 28.0 | 27.0 | 21.1 | 2.66 |
| gpu3 (540) | play t=105–235 | 119.5 | 4.02 | 48 % | 63.8 | 63.2 | 54.4 | 3.94 |

The P GHz column is the highest clock the census saw in each bucket. The
P clock alternates between buckets on the save-slot screen because its CPU
load is light.

At 720 rows gameplay, thermal pressure was 10 from t=125 s and 20 from
t=170 s. From t=215 s the P clock fell to 1.31–2.80 GHz; FPS held at
117.7–120.0 until the run ended, but that is the state from which earlier
runs fell to 103–116 FPS
([thread-QoS record](2026-09-25-hk-thread-qos.md)). At 540 rows, pressure 10
came at t=180 s and 20 never came.

Both runs show `renderpass=19+0 clear=3+6` in DXMT's `[FRAME_STATS]` lines
(`gpu1-frame-stats.txt`, `gpu3-frame-stats.txt`) and about 100 draws a frame.
The pass structure does not change with resolution.

## 3. Ten minutes at 540 rows

`gpu540long-summary.txt` is the table and `gpu540long-pressure.txt` has the
two pressure changes. By thirds of the play (5 s buckets from t=105 s):

| run | t (s) | median FPS | min FPS | buckets at 115+ | lowest P GHz | longest frame (ms) |
|---|---|---|---|---|---|---|
| gpu540long (540) | 105–300 | 119.4 | 101.4 | 36/39 | 3.53 | 267 |
| gpu540long (540) | 300–450 | 118.5 | 74.8 | 24/30 | 3.27 | 1,540 |
| gpu540long (540) | 450–600 | 119.0 | 96.5 | 24/30 | 2.60 | 763 |
| g720long (720) | 105–300 | 119.1 | 112.6 | 38/39 | 1.31 | 50 |
| g720long (720) | 300–450 | 115.2 | 111.4 | 15/30 | 1.31 | 29 |
| g720long (720) | 450–600 | 108.7 | 100.5 | 0/30 | 1.31 | 63 |

g720long's row is recomputed with this tree's `perf-run.py --analyze` from
the [720-row record](2026-09-25-hk-720-gameplay.md)'s run. That run differs
in more than the rows: it had no `WINE_IOS_THREAD_QOS` setting, it ran an
older build, and its rest before the run is not recorded. Of gpu540long's 15
buckets under 115 FPS from t=105 s, nine hold a frame of 100 ms or more
(`gpu540long-hitches.txt`). The other six (t=195, 315, 355, 545, 565, 570 s)
have 13–114 frames over 8.5 ms and a longest frame of 33–83 ms. The last of
them, t=570 s at 99.0 FPS, came as the P clock fell to 3.0 GHz.

`gpu540long-stall-census.txt` has the census lines before each frame of
600 ms or more. Four of the five have the same shape: ~1 s of
`Loading.PreloadManager` (on the E cores under the QoS setting), with the
main thread, graphics worker and encoder still running, then 1–2 ticks of
the main thread alone at 250–320 ms of P time per tick, with `BatchDeleteObjects`
in the first, then five `AssetGarbageCollector` threads. The scripted walk
crossed room boundaries here: `hitches.txt` counts 2,447 and 649 newly
translated blocks in the t=387 and 463 s frames. Whether the utility QoS class on `Loading.` threads
lengthens these stalls is not yet measured.

## 4. The GPU counters

`dvt graphics` answers once a second with the IOAccelerator's statistics
(`gpu1-gpu-txt-head.txt`): `Device Utilization %`, `Renderer Utilization %`,
`Tiler Utilization %`, memory figures, `SplitSceneCount` and
`CoreAnimationFramesPerSecond`. `SplitSceneCount` was 0 throughout every run,
so the tiler never overflowed its parameter buffer. `CoreAnimationFramesPerSecond`
read 60 in 240 of gpu3's 263 samples, and through gpu1's run, while the game presented 120 frames a second
and the HUD reported `Direct` (the layer goes to the display without
compositing), so that counter does not count the game's frames.
Utilization is busy time at the clock the GPU's DVFS chose. Compare it
between runs at similar clocks, or together with the HUD's GPU time; do not
read it as an amount of work.

## 5. The energy gauge

`dvt energy <pid>` returns a sample about every 0.1 s; every other one is all
zeros and the first carries everything since the query began
(`gpu2-energy-txt-head.txt`). `perf-run.py` averages the other samples. In
gpu2:

| phase | FPS | frames > 8.5 ms per 5 s | cpuE | gpuE |
|---|---|---|---|---|
| save slots (t=45–80) | 110–115 | 26–37 | 434–465 | 302–338 |
| play, P at 3.4–3.8 GHz (t=90–100) | 107–111 | 32–54 | 778–886 | 506–531 |
| play, P at 1.31 GHz (t=145–230) | 49–61 | 131–196 | 844–963 | 339–414 |

gpu1's save-slot screen had 0–4 such frames per 5 s; the earlier runs qos4
and sync1 averaged 1.6 and 3.0. gpu2 also began at a raised thermal
level (pressure 10 at t=40 s, against t=125 s in gpu1). The two causes cannot
be separated, so gpu2's frame rates are left out of every comparison here.
`--energy` is off by default.

## 6. Next

- Find the ~2.5 ms of gameplay GPU work that does not scale with
  resolution. The tiler is 54–69 % busy at 100 draws and 19 render passes a
  frame. DXMT could log each pass's attachments, sizes, load and store
  actions and draw count once, to show what the 19 passes are.
- Room-transition stalls of 0.6–1.5 s: repeat gpu540long without the QoS
  setting on `Loading.` threads, then look at the main thread's
  scene-activation work.
- DXMT's `DXMT_METALFX_SPATIAL_SWAPCHAIN=1` upscales the swap chain with
  MetalFX (factor `d3d11.metalSpatialUpscaleFactor`, default 2). It could give
  a 540-row render a sharper picture on the panel than plain scaling does.

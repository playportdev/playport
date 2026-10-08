# Vulkan performance: where both routes stand against DXMT after `patches/mesa` 0019 (warm, measurement only)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), chunk 11: measurement only, with no code change and no build. **IPA (dev):**
`4e6e930d5289b1a6d54bd61468eee97dd2b28122883039d827465c3ae09f87d7` (commit `ca12f08`; branch HEAD
`a14e0f4` adds only documents). It carries `wine-unix` 0021, decision 0066 (tiler mode off),
`patches/mesa` 0018 (no present wait on iOS) and 0019 (texture usage that keeps lossless
compression).

**Result:**

- **Not at exit.** Read against the [exit criteria](../plans/2026-10-06-vulkan-performance.md#exit-criteria),
  each Vulkan route meets 2 of the 9 rows below. Both routes still fail phone mW at native/60
  (+6 to +8 %), sys mJ/f at native/free (+12 to +17 %) and GPU ms at native/free. One D3D12 run
  froze.
- **The GPU gap is now mostly DXVK's.** At native/free, DXVK's GPU time a frame is 29 % above DXMT's.
  vkd3d-proton's is 4 % above DXMT's, on the same KosmicKrisp with the same texture usage. The cooled
  profile runs showed the same split (DXVK 13.40 against vkd3d 10.18 ms). From the code (inference):
  DXVK masks the sample mask to the rasterized samples (`0x1`), which turns on `KK_WORKAROUND_7`'s
  `discard` epilogue in its fragment shaders. vkd3d-proton passes D3D12's `0xFFFFFFFF`, which turns
  it off.
- **The CPU gap is vkd3d's UnityGfxDeviceWorker.** It does 18.9 Mi/f against DXMT's 9.8 at native/60,
  and the whole vkd3d frame is 81.3 against 66.5 Mi/f. The CPU power gap no longer shows at native/60,
  but that comparison is thermal-confounded: DXMT ran first, from `nominal`, with the P cores busy.
- **Caveat: warm runs.** Every run here ran warm, back to back, without `--cool`, and the exit runs
  are cooled. Thermal start went from `nominal` to `serious` through the session. The criteria
  marks below are a standing, not the exit result.

## Runs

Phone iPhone18,4, iOS 27.0, on the charger at 100 %. Every run used route v2: a new game,
`hk-new-game` at `first-frame+25`, `hk-walk` at `first-frame+80`, `--secs 130`,
`--shot first-frame+128`, no `--cool`. Settings were
`{"screen":"native","frameLimit":60|0,"graphics":"dxmt"|"vulkan"}`, plus
`"arguments":"-force-d3d12"` for vkd3d.

Session 1 (`pp phone lock`, 12:23–12:44) ran the six runs in an order meant to spread the thermal
bias: native/60 DXMT, DXVK and vkd3d, then native/free vkd3d, DXVK and DXMT. Run directories are
`$PLAYPORT_BUILD/perf-runs/<name>`. No run log or play log has `Metal HUD off` or `ui: undo session`
(PLA-82), so none is void.

- **`vk-st-n60-vkd3d-1` froze** (see [the D3D12 freeze](#the-d3d12-freeze-vk-st-n60-vkd3d-1)). Its
  HUD figures stop at t = 35 s, so it has no window figures.
- Decision (unattended): the one allowed rerun, `vk-st-n60-vkd3d-2`, ran in a second locked session
  right after session 1. It started at `serious`, the hottest start of the set.

`pp perf --compare … --window 85:125`. CPU mJ/f is CPU mW / FPS. The thermal and budget columns
come from `summary.json`: `thermal_start`, `first_pressure_s`/`max_pressure`, `budget_min_mw` and
`budget_first_s`. The budget is the CPMS minimum over the run, and "first" is the second it was
first logged (negative: before the first frame).

### Native, 60 FPS (2736×1260)

| run | thermal start → states | pressure onset (max) | budget min / first | FPS | p99 ms | ≥25/50/100 | GPU ms | gpu% | P% | Mi/f | CPU mW | sys mW | CPU mJ/f | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-st-n60-dxmt-1` | nominal → fair | t = 95 (10) | 2874 / t = 136 (none in window) | 60.0 | 29.2 | 136/0/0 | 14.81 | 92.9 | 96 | 66.5 | 595 | 3912 | 9.91 | 65.2 | 18.2 |
| `vk-st-n60-dxvk-1` | fair | none | 769 / t = −3 | 59.9 | 25.0 | 55/3/0 | 15.14 | 94.8 | 85 | 74.1 | 554 | 4215 | 9.25 | 70.4 | 18.5 |
| `vk-st-n60-vkd3d-2` (rerun) | serious | none | 769 / t = −2 | 58.2 | 33.4 | 255/4/0 | 14.39 | 81.3 | 66 | 81.3 | 598 | 4161 | 10.28 | 71.5 | 24.5 |
| `vk-st-n60-vkd3d-1` | fair | none | 1180 / t = −21 | froze at t ≈ 37 s | | | | | | | | | | | |

Against DXMT: DXVK has CPU mW −6.8 %, phone mW +7.7 %, sys mJ/f +8.0 % and Mi/f +11.4 %. vkd3d has
CPU mW +0.6 %, phone mW +6.4 %, sys mJ/f +9.7 % and Mi/f +22.3 %.

- At the cap the GPU clocks down to fill the 16.7-ms frame, so GPU ms (14.4–15.1) does not rank the
  backends here.
- DXMT ran first, from `nominal`, with no CPMS budget in the window, and it kept the P cores busy
  (P% 96 against 85 and 66). Its CPU mW is therefore not a like-for-like control. The Vulkan routes'
  CPU mW "≤ DXMT" is partly the hotter phone parking their P cores.
- The phone power is higher on both Vulkan routes while their CPU power is not. At an equal frame
  rate, that points the remaining native/60 power gap at the GPU and memory side.
- vkd3d's rerun started at `serious` and fell below 60 FPS from t ≈ 115 (the 30-s FPS column reads
  58.8 for t = 90–120 and 47.5 for t = 120–130). Its FPS row is thermal, not a backend figure.

### Native, free-running

| run | thermal start → states | pressure onset (max) | budget min / first | FPS | p99 ms | ≥25/50/100 | GPU ms | gpu% | P% | Mi/f | CPU mW | sys mW | CPU mJ/f | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-st-nat-dxmt-1` | serious | none | 1450 / t = −3 | 51.1 | 45.9 | 531/13/3 | 9.19 | 59.9 | 0 | 70.7 | 171 | 3088 | 3.35 | 60.4 | 20.2 |
| `vk-st-nat-dxvk-1` | serious | none | 1516 / t = −22 | 50.4 | 45.9 | 504/19/4 | 11.84 | 72.3 | 0 | 79.0 | 170 | 3570 | 3.37 | 70.8 | 20.4 |
| `vk-st-nat-vkd3d-1` | fair → serious | t = 35 (20) | 769 / t = −19 | 56.8 | 50.0 | 443/27/4 | 9.52 | 67.1 | 0 | 80.3 | 207 | 3853 | 3.64 | 67.8 | 23.7 |

Against DXMT: DXVK has FPS −1.4 %, GPU ms +28.8 %, sys mJ/f +17.2 % and CPU mJ/f +0.6 %. vkd3d has
FPS +11 %, GPU ms +3.6 %, sys mJ/f +12.3 % and CPU mJ/f +8.7 %.

- All three ran with the P cores parked (P% 0) and the GPU 60–72 % busy. Warm native/free is bound
  by the E cores, not by the GPU, so FPS here ranks CPU throughput under the budget. The cooled
  reference `vk-nat-dxmt-1` reached 108.9 FPS at 7.46 ms.
- GPU ms still ranks GPU work per frame, because all three ran at the same thermal level, except that
  vkd3d reached pressure 20. DXVK's +29 % matches the cooled profile runs, where DXVK showed 13.40 ms
  and vkd3d 10.18 ms (+32 %) in the same window.
- `vk-st-nat-dxvk-1`'s end screenshot shows the Knight still in the lit first room. The other five
  show the same dark-cave spot, so its walk took another path late in the run. The 5-s buckets at
  t = 85–100 (below) already show its GPU time above DXMT's while both walked the same part of the room.

### GPU ms in 5-s buckets, t = 65–100 (GPU ms / FPS / thermal pressure)

| run | 65 | 70 | 75 | 80 | 85 | 90 | 95 | 100 |
|---|---|---|---|---|---|---|---|---|
| `vk-st-n60-dxmt-1` | 8.32 / 44.8 / – | 9.21 / 59.7 / – | 9.49 / 60.2 / – | 8.93 / 60.0 / – | 14.00 / 59.8 / – | 15.34 / 60.1 / – | 15.24 / 59.6 / 10 | 14.48 / 60.0 / 10 |
| `vk-st-n60-dxvk-1` | 8.41 / 44.3 / – | 9.03 / 59.9 / – | 9.07 / 59.7 / – | 8.91 / 60.0 / – | 14.40 / 59.7 / – | 15.21 / 60.0 / – | 15.28 / 59.3 / – | 15.19 / 60.3 / – |
| `vk-st-n60-vkd3d-2` | 8.28 / 44.1 / – | 8.90 / 59.5 / – | 8.93 / 60.0 / – | 8.83 / 59.9 / – | 12.43 / 59.4 / – | 14.70 / 60.1 / – | 14.78 / 60.0 / – | 14.80 / 59.4 / – |
| `vk-st-nat-vkd3d-1` | 7.63 / 73.7 / 20 | 11.74 / 76.4 / 20 | 10.03 / 78.9 / 20 | 9.55 / 70.4 / 20 | 8.49 / 65.6 / 20 | 8.91 / 66.5 / 20 | 8.58 / 59.8 / 20 | 8.64 / 59.3 / 20 |
| `vk-st-nat-dxvk-1` | 9.68 / 57.8 / – | 23.29 / 42.9 / – | 16.17 / 55.3 / – | 11.24 / 50.1 / – | 10.81 / 50.9 / – | 10.92 / 53.8 / – | 10.51 / 55.6 / – | 10.77 / 54.0 / – |
| `vk-st-nat-dxmt-1` | 9.00 / 60.4 / – | 23.74 / 37.8 / – | 9.18 / 48.9 / – | 9.25 / 50.3 / – | 8.82 / 50.5 / – | 8.61 / 53.9 / – | 8.65 / 54.1 / – | 8.49 / 57.8 / – |

- On a warm phone the King's Pass start (t = 70) spikes GPU time on DXMT too (23.7 ms), as on DXVK
  (23.3). After the spike DXMT settles at 8.5–9.2 ms, DXVK at 10.5–11.2 and vkd3d at 8.5–8.9.
- At native/60 all three sit at 8.3–9.5 ms before King's Pass and at 14–15 ms in it: there the GPU
  clock follows the cap, not the work.

### Per thread, Mi/f, t = 85–125 (top 3, and the backend's recording thread)

From the same per-window thread accounting as the [profile](2026-10-08-vulkan-perf-profile.md)
(totals 1–3 % below `--compare`'s Mi/f, from frame counting). `002c` is the game's main thread.
`00c4`/`00bc`/`00ec` is the same unnamed game thread on each backend.

| mode | DXMT | DXVK | vkd3d |
|---|---|---|---|
| native/60 | main 20.46, `00c4` 11.10, UnityGfxDeviceWorker 9.80; dxmt-encode-thr 4.26 | main 20.66, UnityGfxDeviceWorker 11.75, `00bc` 11.14; dxvk-cs 4.74 | main 22.46, **UnityGfxDeviceWorker 18.86**, `00ec` 11.96 |
| native/free | main 21.06, `00c4` 13.23, UnityGfxDeviceWorker 9.67; dxmt-encode-thr 4.23 | main 21.02, UnityGfxDeviceWorker 13.37, `00bc` 13.22; dxvk-cs 4.53 | main 20.83, **UnityGfxDeviceWorker 18.03**, `00ec` 12.04 |

- vkd3d's UnityGfxDeviceWorker is +9 Mi/f over DXMT's in both modes. That is 60 % of vkd3d's whole
  Mi/f gap. The worker also records vkd3d's Metal work (there is no separate recording thread), so
  part of it is DXMT's dxmt-encode-thr. Net of that, it is still about +4.8 Mi/f.
- DXVK's gap is spread out: UnityGfxDeviceWorker +2.0 and dxvk-cs +0.5 over dxmt-encode-thr, with
  small amounts on the host threads.

### End screenshots

`shot-ff128.png` in each run directory. They are described here and not published.

- DXMT (both modes), DXVK native/60, vkd3d native/60 (`-2`) and vkd3d native/free all show the same
  dark King's Pass cave, with the Knight under the stalactites and the radial light drawn the same way.
- DXVK native/free shows the Knight still in the lit first room, drawn correctly. The walk diverged
  and nothing was misdrawn.
- `vk-st-n60-vkd3d-1` shows a black screen with the HUD's last frame (see the next section).

## The D3D12 freeze (`vk-st-n60-vkd3d-1`)

Facts, from `run/pull/s1-host.log`:

- First frame at +9.30 s. The last `[frames]` line is at 12:32:00.465, about `first-frame+37`, while
  the `hk-new-game` script was at step 8 of 64, so in the menu before the opening cinematic. After
  that, no frame was presented until the run stopped at `first-frame+130`. The app did not crash and
  was ended by the driver.
- vkd3d-proton logs `Enabling staggered submissions for command queue 000000702bf08d10` at
  106716.336, and then nothing more. In the normal pattern, which this run followed three times
  before and every other vkd3d run follows, a `Disabling staggered submissions` line comes about
  1 s later.
- From then on the `[waiters]` census shows 42 threads parked for over 60 s with no timeout. Among
  them are UnityGfxDeviceWorker (`00b0`) and vkd3d's threads (`00ac`, `00b4`, `00b8`), waiting on
  addresses inside the command-queue objects at `0x702bf08d10` and `0x702bf08f70`. The guest
  threads' samples sit in `os_sync_wait_on_address`. FEX ran no guest code (`x64->EC 0/s`).
- The plan's Progress records no D3D12 freeze since `wine-unix` 0020. The two other D3D12 runs in
  this session, and the four D3D12 plays of chunk 10, ran through.
- The signature matches the one the [FEX band record](2026-09-28-fex-band.md) left open: four DXVK
  plays that froze at the menu's Start Game, with every thread in `os_sync_wait_on_address`.

Inference: a deadlock in vkd3d-proton's queue submission when staggered submission turns on, or in
what it waits on below (KosmicKrisp's queue, a FEX futex). It is not a performance issue, and this
chunk did not investigate it. It needs its own issue: the exit criteria require every exit run to
end in play.

## Standing against the exit criteria (warm, one run each)

The plan's 720/60 rows are read here at native/60, as this chunk asked (power first). The exit runs
are cooled, and these are warm.

| criterion | DXMT | DXVK (D3D11) | vkd3d-proton (D3D12) |
|---|---|---|---|
| native/60 CPU mW ≤ DXMT + 5 % | 595 | 554 (−6.8 %): **met**, thermal-confounded | 598 (+0.6 %): **met**, thermal-confounded |
| native/60 phone mW ≤ DXMT + 5 % | 3912 | 4215 (+7.7 %): **not met** | 4161 (+6.4 %): **not met** |
| native/60 FPS ≥ DXMT − 0.5 | 60.0 | 59.9: **met** | 58.2: **not met** (rerun started `serious`) |
| native/60 Mi/f ≤ DXMT + 5 % | 66.5 | 74.1 (+11.4 %): **not met** | 81.3 (+22.3 %): **not met** |
| native/60 ≥ 50 ms hitches ≤ DXMT | 0 | 3: **not met** | 4: **not met** |
| native/free FPS ≥ DXMT | 51.1 | 50.4 (−1.4 %): **not met** (E-core bound, within noise) | 56.8: **met** |
| native/free GPU ms ≤ DXMT | 9.19 | 11.84 (+28.8 %): **not met** | 9.52 (+3.6 %): **not met** |
| native/free phone mJ/f ≤ DXMT + 5 % | 60.4 | 70.8 (+17.2 %): **not met** | 67.8 (+12.3 %): **not met** |
| native/free CPU mJ/f ≤ DXMT + 5 % | 3.35 | 3.37 (+0.6 %): **met** | 3.64 (+8.7 %): **not met** |
| stability (every run ends in play) | 2/2 | 2/2: **met** | 2/3: **not met** (one freeze) |

Since the [profile](2026-10-08-vulkan-perf-profile.md) (cooled, before 0019), the native/free gap
narrowed from +80 % / +36 % GPU ms (DXVK / vkd3d against DXMT) to +29 % / +4 %, and from +47 % / +104 %
sys mJ/f to +17 % / +12 %. The two sets differ in thermal state, so only the ratios are compared.

## The remaining gaps, largest first

1. **DXVK's GPU time at native, +29 % (about 2.6 ms a frame; +17 % phone energy a frame).**
   - **Evidence:** vkd3d on the same KosmicKrisp, memory types and 0019 usage is +4 %. So about
     25 points are DXVK-specific, in this run and in the cooled profile pair.
   - **Lead: the `KK_WORKAROUND_7` epilogue.** DXVK sets
     `msSampleMask = sampleMask & ((1 << rasterizationSamples) − 1)` (`dxvk_graphics.cpp:384`), which
     is `0x1` for single-sample pipelines. KosmicKrisp adds the workaround when
     `sample_mask != UINT16_MAX` (`kk_shader.c`): a `discard_if` on `sample_mask_in` and a static
     `[[sample_mask]]` write. The [King's Pass capture](2026-10-08-vulkan-perf-kings-pass-capture.md)
     found it in 28 of 30 fragment shaders. vkd3d-proton passes the PSO's `SampleMask` unmasked
     (`state.c:6079`). Unity's is D3D12's default `0xFFFFFFFF`, stored as `0xFFFF`, so vkd3d's shaders
     skip the workaround.
   - The workaround is for multisample depth/stencil (`workarounds.rst`, ≥ 2 samples). With one
     sample whose bit is set, the `discard` never fires, but a shader that can discard loses the
     GPU's early depth and hidden-surface removal. King's Pass layers many full-screen sprites.
     This is an inference: the cost is unmeasured.
   - **Lead: the depth store in pass 20** (17.2 MB a frame; DXMT stores none). It is about 3 % of the
     frame's attachment bytes. It is smaller, and it is not known whether vkd3d stores it.
2. **The KosmicKrisp-wide residual: vkd3d +4 % GPU ms, +12 % phone energy a frame, +6 % phone mW at
   native/60.** Common to both routes:
   - render targets in shared storage under a whole-heap buffer alias, where DXMT's are private
     (chunk 8's `private_memory`, never tested together with 0019's usage);
   - the WSI copy into the drawable, 27.6 MB a frame (item 4; not removable safely).

   The phone mW gap at native/60 with equal or lower CPU mW points at this GPU and memory side.
3. **vkd3d's CPU work, +22 % Mi/f.** UnityGfxDeviceWorker does +9 Mi/f over DXMT's.
   - The profile split the worker into FEX (guest and `xtajit64`) 13.5 % of samples against DXVK's
     7.6 %, with 3× the ARM64EC transitions, plus Apple's driver 3.6 %.
   - It shows as +8.7 % CPU mJ/f at native/free and in the 720/60 profile (+45 % CPU mW). It does not
     show in this warm native/60 CPU mW, because the P cores were parked.
4. **DXVK's CPU work, +11 % Mi/f.** UnityGfxDeviceWorker +2.0 and dxvk-cs +0.5 Mi/f. dxvk-cs's time
   in Apple's driver is 2.2 % of samples against KosmicKrisp's 0.6 %. No CPU power gap shows at
   native, so this is the smallest gap.
5. **Stability, outside the ranking:** the D3D12 freeze after `Enabling staggered submissions`. It is
   not a performance gap, but it blocks exit, and it is for its own issue.

## Next chunks proposed, in order (one change each)

1. **`patches/mesa`: KosmicKrisp's sample-mask lowering only when the mask clears a rasterized
   sample.** In `kk_shader.c`, compare `sample_mask & BITFIELD_MASK(rasterization_samples)` with
   `BITFIELD_MASK(rasterization_samples)` instead of `sample_mask` with `UINT16_MAX`. That skips
   both the `KK_WORKAROUND_7` discard and the static `[[sample_mask]]` write when every rasterized
   sample is covered. A partial mask keeps both.
   - **Size first, at no cost:** in the same session, a warm native/free DXVK leg with the existing
     switch `"graphicsOptions":"MESA_KK_DISABLE_WORKAROUNDS=7"`, which removes only the discard.
   - **Then:** gate, and one warm native/free DXVK pair (control, change), read as GPU ms and
     sys mJ/f. Target: DXVK's GPU ms down toward vkd3d's (−20 % or more).
2. **`private_memory` on top of 0019** (chunk 8's 0020, from `c8c6016`, behind
   `MESA_KK_EXPERIMENTAL`). One warm native/free pair on vkd3d, the route without the DXVK-specific
   shader cost, so that storage alone is measured. Read GPU ms, sys mJ/f and the native/60 phone mW.
3. **FEX on the D3D12 route (work-queue item 8)** for UnityGfxDeviceWorker's +9 Mi/f. The hot guest
   blocks and the ARM64EC transitions a frame, then one warm 720/60 pair.

The D3D12 freeze goes to its own issue before the exit runs. DXVK's depth store in pass 20 comes after
chunk 1, if DXVK still trails vkd3d on GPU ms.

## Games observed

| title | IPA | run directory | outcome |
|---|---|---|---|
| Hollow Knight (367520), DXMT native/60 and native/free | `4e6e930d…` | `perf-runs/vk-st-n60-dxmt-1`, `vk-st-nat-dxmt-1` | 130 s each, King's Pass, no crash |
| Hollow Knight (367520), DXVK native/60 and native/free | `4e6e930d…` | `perf-runs/vk-st-n60-dxvk-1`, `vk-st-nat-dxvk-1` | 130 s each, no crash (native/free walk ended in the first room) |
| Hollow Knight (367520), D3D12 (vkd3d-proton) native/60 | `4e6e930d…` | `perf-runs/vk-st-n60-vkd3d-1` | **froze** at about `first-frame+37` in the new-game menu: no frames after `Enabling staggered submissions`, 42 threads parked, no crash |
| Hollow Knight (367520), D3D12 native/60 (rerun) and native/free | `4e6e930d…` | `perf-runs/vk-st-n60-vkd3d-2`, `vk-st-nat-vkd3d-1` | 130 s each, King's Pass, no crash |

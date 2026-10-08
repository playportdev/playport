# Vulkan performance, step 0: the tooling the Vulkan route lacked

**Date:** 2026-10-06. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md),
step 0. **Branch:** `vulkan-performance`. **IPAs:** `a69efc64…` (0.1–0.3),
`4b6b0586…`, then `18805415…` (0.4 with the per-thread tables, 0.2, the gate), all dev,
installed in place. Run directories are under `$PLAYPORT_BUILD`.

## 0.1 Graphics options on the game page (decision 0060)

- `LaunchSettings.graphicsOptions`, a typed line in a dev build's Developer section
  (*Graphics options*, under *Runtime keys*), parsed by
  `LaunchSettings.graphicsEnvironment` into an allowlist: `DXVK_CONFIG`,
  `VKD3D_CONFIG`, `MESA_KK_DEBUG`, `MESA_KK_EXPERIMENTAL`,
  `MESA_KK_DISABLE_WORKAROUNDS`, and DXVK options by section (`dxvk.tilerMode=False`
  goes into `DXVK_CONFIG`). PlayportKit tests cover the parse and the refusals.
- On the phone: `pp ui --settings 'app-367520:{"graphics":"vulkan","graphicsOptions":"dxvk.hud=fps,devinfo"}'`
  then `open:app-367520#developer` and eight `pad:down`
  (`ui-runs/20261006T170142`): the last shot shows the ringed row *Graphics options*
  with the changed dot and the value `dxvk.hud=fps,devinfo`.
- A play with the same settings (`ui-runs/20261006T170409`, first frame +9.12 s) logs
  `title: graphics options: DXVK_CONFIG=dxvk.hud = fps,devinfo` and DXVK's
  `Found config env: dxvk.hud = fps,devinfo`; the screenshot shows DXVK's HUD over the
  main menu (the GPU, `Driver: KosmicKrisp`, Mesa's version, `FPS: 60.0`). The option
  reaches DXVK.

## 0.2 Frames without the HUD, on either backend

`PacedMetalLayer.nextDrawable` (dev builds) logs `[frames] HH:MM:SS.mmm n=N` every 16
drawables; `pp perf --no-hud` (and `--analyze --frames layer`) counts frames by them.
A 30 s Vulkan run at 720/free with `--no-hud` (`perf-runs/vk-nohud-check`) has 286
such lines and a table of 117–120 FPS in the menu, with the frame-time and GPU columns
empty as for DXMT's Present lines. `pp perf --compare … --window LO:HI` was added for the
plan's windows: FPS, frame-interval p50/p99/p99.9 and ≥25/50/100 ms counts from the HUD's
intervals, GPU ms and utilisation, all threads' Mi/f, CPU and phone mW, the phone's mJ a
frame, the lowest budget, srv/f.

## 0.3 GPU capture on KosmicKrisp

- `patches/mesa` 0017: `MESA_KK_GPU_CAPTURE_FRAME=N` captures one frame (the submits
  after present N-1 to present N) into `MESA_KK_GPU_CAPTURE_DIRECTORY`, logging the
  `A new capture will be saved to` line `pp gpu` and `pp perf` look for. Settings'
  GPU capture sets it on a Vulkan launch; `pp gpu capture --settings JSON` was added.
- `tools/gputrace.py` read only Metal 3 captures; KosmicKrisp records Metal 4
  (`MTL4CommandBuffer`, heaps, `MTL4Compiler`). It now reads Metal 4 command buffers,
  passes (a Metal 4 pass descriptor's layout, read from this capture), draws,
  `signalDrawable` presents and heap textures. The call-name table was built once
  (`pp gpu names --fetch`, iOS 27.0).
- One frame each, frame 600 (the main menu), same IPA:

| | DXMT (`gpu-runs/vk-dxmt-cap1`, 696 MB) | KosmicKrisp (`gpu-runs/vk-kk-cap1`, 763 MB) |
|---|---|---|
| command buffers / passes / draws | 2 / 3 / 11 | 4 / 5 / 13 |
| scene pass | 1564×720 RGBA8 L/S, D32FS8 L/S, 9 draws, 1314 indices | the same: 1564×720 RGBA8 L, D32FS8 L, 9 draws, 1314 indices |
| second pass | RGBA8 L/S, 1 draw (6) | the same |
| after it | present quad to the BGRA8 drawable (3 vertices) | a compute dispatch, a 3-vertex pass (DXVK's blit to its swap-chain image), then a 6-vertex pass to the BGRA8 drawable (KosmicKrisp's WSI blit) |

  The game's own work is the same pass for pass. **The Vulkan frame has one more
  full-screen pass and one compute dispatch**: the swap-chain image is drawn by DXVK and
  then copied again by the WSI into the drawable. KosmicKrisp encodes store actions as
  unknown and sets them (store) at the end of each pass, which ends the same as DXMT's.
  Candidate for step 5. Pipeline statistics are not read for Metal 4 pipelines yet
  (their descriptors name functions differently); the table shows them as empty.

## 0.4 CPU profiles of DXVK and KosmicKrisp

- `patches/madeira-unix` 0096: the sampler names a KosmicKrisp leaf
  `KosmicKrisp+<offset>` (dladdr named every static function after the nearest export),
  and adds `thread-leaf` and `thread-module` tables, keyed by thread name, so a thread
  whose time spreads over many small functions (dxvk-cs) adds up.
- `tools/sampleprof.py` resolves `KosmicKrisp+<offset>` against the staged framework's
  local symbols, and on a run whose log says `graphics: vulkan` symbolises `d3d11`,
  `dxgi` and `d3d12` against DXVK's and vkd3d-proton's DLLs (`Runtime/vulkan`).
- One DXVK play at 720/free through New Game and the walk with `--cpu-prof`
  (`perf-runs/vk-prof-dxvk3`), the thread-module table, % of all samples:

| thread | module | % |
|---|---|---|
| main (`w…951`) | guest code / xtajit64 / kernel | 38.2 / 7.6 / 3.2 |
| wineserver (`m…945`, `read` 8.4) | kernel | 13.0 |
| UnityGfxDeviceWorker | guest / kernel / d3d11 | 6.2 / 2.7 / 0.6 |
| dxvk-cs (8–11 % in all) | AGXMetalG18P / kernel / KosmicKrisp / d3d11 / memset·memmove / IOGPU / objc / Metal / malloc | 2.0 / 2.0 / 1.2 / 1.1 / 1.0 / 0.6 / 0.6 / 0.4 / 0.4 |
| dxvk-submit | kernel / AGX | 0.5 / 0.2 |

  dxvk-cs spends more in Apple's driver (AGX, IOGPU, Metal, objc: 3.6) than in
  KosmicKrisp (1.2) or DXVK (1.1): KosmicKrisp encodes Metal on DXVK's CS thread.
  winevulkan does not show: its thunks are under 0.1 %.

## Gate

`pp test` passed. One locked session on the step's IPA: Hollow Knight and Portal 2 to
`first-frame+10` on their default backends (`ui-runs/20261006T172840`,
`ui-runs/20261006T172937`), both ok.

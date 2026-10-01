# Hollow Knight at native resolution: where the GPU frame goes

Status: measurement only (no fix yet). Wine 11.18 build with `madeira-unix`
0027 (the Mono trampoline fix) plus `patches/dxmt` 0008, which adds the
profiler used here. Dev IPA sha256
`6fd0a3975ff15a7907416300b1a5285a4b1ab92621a654d2471decf03aaf6e8a`.

## Why

After 0027 ([2026-09-26-hk-mono-trampoline.md](2026-09-26-hk-mono-trampoline.md)),
King's Pass runs at 62-71 FPS, and the Metal HUD reports 8.5-13.5 ms of GPU
time a frame. 120 FPS needs less than 8.3 ms. The HUD gives one number a frame,
so the frame had to be split up.

## The profiler (`patches/dxmt` 0008)

With `DXMT_PASS_PROF=1` in a game's environment, winemetal samples the GPU
timestamp counters at the stage boundaries (`MTLCounterSamplingPointAtStageBoundary`)
of every render, blit and compute encoder, for two whole frames once every 1200
presents (first at present 600). Twelve presents later it prints one
`[pass-prof]` line per encoder:

- the command buffer
- the size and sample count
- each colour and depth attachment's format and load/store action
  (`L`oad, `C`lear, `x` don't care / `S`tore)
- the draws and primitives
- the vertex and fragment GPU times, and where they start and end in the frame

A frame total follows. Without the variable, no descriptor is touched.

On this phone, the resolved counter timestamps are nanoseconds, while
`sampleTimestamps:gpuTimestamp:` returns mach ticks (ratio 41.667). The first
run (`w1118-passprof`) scaled by that ratio, so its ms figures are 41.667 times
too large. The patch now prints nanosecond-based ms and reports the ratio only
for the record.

## Run

`pp perf --out .work/perf-runs/w1118-passprof2 --secs 160 --settings
'{"environment":[{"name":"DXMT_PASS_PROF","value":"1"}]}' --pad
first-frame+35:hk-new-game --pad first-frame+90:hk-walk` (the same route as the
earlier records). It produced 14 reports. The 8 frames sampled in King's Pass
all have the same 29 encoders in 3-4 command buffers and 102-108 draws. The
frame's fragment work runs back to back with no idle gap, so the sum of
fragment times is the GPU frame.

Mean over those 8 frames (ms, min-max in brackets):

| # | encoder | ms |
|---|---|---|
| 0 | 2736x1260 RGBA8 clear-only pass (C/S, 0 draws) | 0.47 [0.36-0.61] |
| 1-6 | 782x360 passes (a small camera plus 5 one-quad passes) | 0.41 total |
| 7 | 2736x1260 depth clear-only (D32S8) | 0.00 |
| 8 | 2736x1260 scene, C/S colour + C/S depth, 17 draws, 2814 prims | 1.63 [1.19-1.97] |
| 9 | blit | 0.56 [0.25-0.80] |
| 10 | 2736x1260 scene, L/S + L/S depth, 30 draws, 10896 prims | 1.15 [0.91-1.61] |
| 11 | blit | 0.43 [0.26-0.65] |
| 12 | 2736x1260 scene, L/S + L/S depth, 13 draws | 1.01 [0.50-1.41] |
| 13 | blit | 0.37 [0.26-0.45] |
| 14 | 2736x1260, L/S + L/S depth, **3 draws, 63 prims** | **2.47 [1.66-3.05]** |
| 15-19 | 684x315 one-quad chain (bloom-sized) | 0.55 total |
| 20-22 | 2736x1260 one-quad passes | 0.34 / 0.71 / 0.50 |
| 23 | 2736x1260, depth cleared, 15 draws, 669 prims (HUD) | 0.27 |
| 24 | 2736x1260 one quad, depth L/x | 0.38 |
| 25-26 | depth clear-only, small blit | 0.01 |
| 27 | 2736x1260 one quad | 0.37 |
| 28 | present: blit into the drawable (BGRA8) | 0.30 |
| | **frame** | **11.9 (8.2-14.6)** |

The vertex stage costs less than 0.1 ms a pass. The frame is fragment and
bandwidth work at 3.45 Mpixels:

- **Pass 14** alone is about 20% of the frame: three draws of 63 primitives
  that cover the screen with an expensive shader or heavy overdraw.
- **Three full-screen blits** between the scene passes (0.37-0.56 ms each,
  1.4 ms a frame). Each one also splits the scene into separate render passes
  (8, 10, 12, 14) that load and store full-resolution colour and D32S8 depth.
  That is about 31 MB of load plus 31 MB of store per boundary.
- **Eight full-screen one-quad passes** (20-22, 24, 27, 28, plus 0), about
  2.9 ms, each a full load and store of a full-resolution target.
- **Pass 0**: a clear with no draws, stored to memory (0.47 ms). DXMT folds a
  clear into the *next* render pass only when that pass is on the same
  attachment. Here the clear stands alone.

## What this says about the target

- The GPU time a frame swings from 8.2 to 14.6 ms with the GPU clock, for
  the same passes. Even at the best clock, 8.2 ms is right at the 8.3 ms budget.
  Stable 120 FPS for 10 minutes, with the thermal clock drop, needs the frame
  to be about 40% cheaper at native resolution.
- In the HUD columns of the same run, t=115-125 s shows GPU time at 8.5 ms
  and still only 63-65 FPS, with every thread on the E cores. So the CPU
  side, the main thread off the P cores, has to be fixed as well.

## Leads, in order

1. Find out what pass 14's three draws are (the pipeline or shader hash per
   draw) and why they take 2.5 ms. It may be a poor shader conversion or plain
   overdraw.
2. The blits between scene passes: what they copy, and whether DXMT can avoid
   splitting the render pass or storing depth around them.
3. Render-target texture flags. Unity creates render textures as TYPELESS.
   DXMT then adds `MTLTextureUsagePixelFormatView`
   (`d3d11_resource_helper.cpp`), which can turn off the Apple GPU's lossless
   framebuffer compression. Every pass above is bandwidth-bound, so this may
   cost the whole frame. Confirmed and fixed by `patches/dxmt` 0009: the
   King's Pass GPU frame went from 13 ms to 6.7 ms
   ([2026-09-26-hk-lossless-compression.md](2026-09-26-hk-lossless-compression.md)).
4. Stand-alone clear passes (pass 0), and depth stores that the next use
   clears anyway.

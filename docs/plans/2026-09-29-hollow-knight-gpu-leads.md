# Plan: Hollow Knight leads from the first GPU captures and validation

**Date:** 2026-09-29. **Status:** leads to hunt. Nothing here is a measured
cause or a fix. **Title:** Hollow Knight (`app-367520`) on DXMT, iPhone18,4,
iOS 27.0. **Tools:** `pp gpu` and `pp perf --pass-prof`
([GPU-DEBUGGING.md](../GPU-DEBUGGING.md)). **Evidence:**
[metal-tools-without-a-mac](../evidence/2026-09-29-metal-tools-without-a-mac.md).
**Relation:** complements
[the performance follow-up](finished.md#performance-follow-up-after-the-runtime-audit), which
covers CPU, power and memory; this plan covers what the GPU tools showed.

## The runs

| Run (`$PLAYPORT_BUILD/…`) | What | Build (dev IPA sha256) | Caveat |
| --- | --- | --- | --- |
| `perf-runs/metal-capture-hk` | `pp perf --secs 150 --pad first-frame+35:hk-new-game --pad first-frame+90:hk-walk --pass-prof --gpu-capture 9000`: King's Pass, frame 9000 captured | `a82400a7dd1e0400f4b9b66ae637c401c1f4160444686c8e10ba88539465807d` | capture on for the whole process; global settings 1564×720 and a 60 FPS limit |
| `gpu-runs/hk-kings-pass` | `pp gpu capture --frame 7200 … --validation shaders --pass-prof` (before validation left `capture`): the same route with API and shader validation; no capture was written | `8d094fd8b3e75c0468decfb26ec91bdfe33d4b5bf39e3bdd9446c320e730faad` | validation roughly doubled GPU time (6 to 15 ms a frame) |
| `gpu-runs/capture-title`, `scratch/metaltools/traces/hollow_knight_F.600_…` | title-screen captures (frames 1200, 600) | `0c2a0012a4970eb3d943e7897434d4f87f09c8161a2c1aa5afb67b43b78efd1c`; `2af2841a948ef12365c69b784ab1b680907492f840106374753c4f55c9f79578` | title screen only |

All had the Metal HUD on and were charging. None is a performance baseline:
compare a change only against a `pp perf` run without capture or validation,
under the performance plan's measurement rules.

## What the runs showed

King's Pass frame 9000 (`pp gpu read`, with the same run's `passes.txt`):

- **Structure:** 28 passes plus the present, all in one command buffer:
  - 23 render passes;
  - 5 blits;
  - 97 draws;
  - 168 fence waits and 57 fence updates.
- **GPU time:** about 6.0 ms a frame (pass timer), and the HUD agrees
  (6.16 ms). At a 60 FPS limit the GPU is not the limit at 1564×720.
- **Frame times:** of 8,819 frames, 566 took 25 ms or more:
  - 501 exactly 25.01 ms;
  - 51 at 29.18 ms;
  - 7 over 33 ms.
- **By kind of pass** (`passes.txt`, ms a frame, share):

  | Passes | ms | share |
  | --- | --- | --- |
  | full-size, colour and depth loaded and stored (about 5.4 a frame) | 2.48 | 41 % |
  | blits (the grab copies and others) | 0.89 | 15 % |
  | full-size colour-only loaded and stored (post effects) | 0.67 | 11 % |
  | the first scene pass, colour and depth cleared | 0.45 | 8 % |
  | the 782×360 camera pass | 0.34 | 6 % |
  | 391×180 blur passes (4.4 a frame) | 0.26 | 4 % |

Validation over 164 s (King's Pass route, 60 FPS limit, so about 9,800
frames):

- **Shader validation:** 52,970 `INF or NAN detected in interpolant`
  findings, in 8,842 frames, from 12 vertex shaders:

  | Vertex shader | Interpolant | Findings |
  | --- | --- | --- |
  | `vs_87a79b60_d24bfa8c…` | `reg1_0` | 19,705 |
  | `vs_756ae290_5b6d5908…` | `reg2_0` | 11,475 |
  | `vs_20449f12_70745d52…` | `reg2_0` | 9,845 |
  | `vs_30b826a6_218a3f87…` | `reg1_0` | 4,135 |
  | `vs_756ae290_70745d52…` | `reg2_0` | 2,917 |
  | `vs_a979d1ae_218a3f87…` | `reg1_0` | 2,067 |
  | `vs_31a7193c_5b6d5908…` | `reg2_0` | 1,983 |
  | `vs_f59f853e_47c48eba…` | `reg3_0` | 757 |
  | `vs_52b54bfe_7bd03733…` (the final composite) | `reg0_0` | 82 |
  | three more | | 1 or 2 each |

  The title screen alone gives the same kind in nearly every frame
  (`reg2_0`, `reg1_0`, `reg3_0`).
- **API validation:** no error. About 1.8 million performance messages, the
  main ones (totals over the run; at 60 FPS, 394,539 is about 40 a frame):

  | Message | Count |
  | --- | --- |
  | redundant `setStencilReferenceValue` | 394,539 |
  | previous `setStencilReferenceValue` unused | 234,340 |
  | unused vertex buffer binding, index 1 / 2 / 0 | 173,320 / 173,319 / 164,475 |
  | unused fragment buffer binding, index 1 / 0 | 173,237 / 97,806 (+75,515 at end of encoding) |
  | redundant `setBlendColor` | 119,068 |
  | redundant `setDepthStencilState` | 95,361 |
  | redundant fill mode, cull mode, depth clip, depth bias (each) | 12,258 |
  | redundant `setRenderPipelineState` | 5,855 |

- **A capture and validation in one play do not mix:** the capture was never
  written. `pp gpu` now keeps them apart.

## Leads, in order

### 1. NaN interpolants (correctness)

- **Question:** do DXMT's translations of these vertex shaders produce
  INF/NaN outputs the game's own shaders do not, and does any reach the
  picture?
- **Why first:** it is the only correctness signal so far. Twelve shaders in
  nearly every frame is more like a translation pattern than game data.
  - A NaN in an interpolant the fragment stage reads shows as black or
    missing pixels.
  - One in an unused interpolant is harmless, but a hint to what the
    translation writes.
- **Steps:**
  1. Map each `vs_<hash>_<hash>` to its DXBC. The first hash names the
     shader; the pipeline half differs between variants.
     `pp shaders TITLE_DIR OUT --match <hash>` runs the title's shaders
     through a host airconv. Read the translated `reg1_0`/`reg2_0` outputs
     against the DXBC's `o1`/`o2`.
  2. Check the DXBC's own maths for a division or normalisation that is
     legitimately INF on some inputs (Unity sprite shaders with zero-size
     quads, for example). If the game's own shader produces it, it is the
     game's and harmless on Windows too.
  3. Compare the picture with the Proton + RenderDoc reference at King's
     Pass ([GPU-DEBUGGING.md](../GPU-DEBUGGING.md#the-reference-on-this-pc)).
     Also look for the same NaN under Proton: RenderDoc's pixel history shows
     NaN outputs.
  4. If DXMT is wrong, it becomes a patch in `patches/dxmt/` with the
     validation count going to zero as its check.
- **Done when:** each of the 12 is explained as the game's own behaviour or
  fixed.

### 2. Redundant state and unused bindings (CPU)

- **Question:** does DXMT's encoder spend measurable CPU time setting Metal
  state that has not changed and binding buffers the pipeline does not read?
- **Why:** about 40 redundant stencil-reference sets a frame, plus blend
  colour and depth-stencil state and three or four unused buffer bindings
  per draw. This is per-draw CPU work on DXMT's encode thread.
  - DXMT's `[FRAME_STATS]` lines give `enc_flush` 13-22 ms in these runs.
    What that figure times is to be read in `dxmt_context.cpp` before using
    it.
  - With the GPU at 6 ms, the CPU side is where frame time goes.
- **Steps:**
  1. Find where DXMT emits each state per draw (`dxmt_context.cpp`, the
     render encoder's state flush).
  2. Count per frame with a `pp perf --cpu-prof` run: how much of the encode
     thread is in those calls.
  3. If it is worth it, cache the last value per encoder, and skip bindings
     the pipeline's reflection says are unused.
- **Measure:** encode-thread CPU and power, A/B under the performance
  plan's rules, and the validation counts to confirm.
- **Done when:** the CPU cost is measured, and a change is kept or rejected.

### 3. The grab-pass copies (GPU bandwidth)

- **Question:** what do the four full-screen colour copies a frame
  (1564×720 RGBA8, `copyFromTexture`, 1,126,080 texels each) and the pass
  splits they force cost in total?
- **What is known:**
  - Each copy ends a render pass.
  - The next pass loads and stores colour and D32FS8 depth-stencil again.
  - Copies are 15 % of GPU time; the reloading passes are 41 %.
  - This is Unity's screen grab for distortion effects, which the game
    asks for.
- **Unknown:** load/store bandwidth versus the draws' own work. That needs
  counters, a Mac item
  ([GPU-DEBUGGING.md](../GPU-DEBUGGING.md#agenda), item 2).
- **Linux-side experiments:**
  - Whether DXMT could keep depth in the tile across a copy: not possible
    in Metal across passes. Whether it could at least not store and reload
    depth when the grab pass does not need it.
  - At native resolution the same structure costs more
    ([hk-gpu-passes](../evidence/2026-09-26-hk-gpu-passes.md)): 2736×1260
    is 3.1 times the pixels.
- **Done when:** the share is measured with counters, or a DXMT change
  removes a load or store and `passes.txt` shows it.

### 4. Clear-only depth passes (GPU, small)

- **Question:** are DXMT's two `ClearPass` encoders a frame (passes 5 and
  25, each clearing and storing a 1564×720 D32FS8 depth-stencil with no
  draw) needed?
- **What is known:**
  - Nothing later in the same frame names either texture.
  - Pass 24 discards a depth (`L/x`) that pass 25 then clears and stores.
  - The pass timer puts clear-only depth passes at about 0.05 ms a frame
    (`d=260/CS st`, 1.75 a frame): small.
- **Steps:**
  1. Capture two consecutive frames (frame N and N+1) and check whether
     frame N+1 reads the cleared textures.
  2. If it does not, find what issues the clears (a Unity
     `ClearRenderTarget` on a camera target, perhaps) and whether DXMT could
     defer a clear into the target's next use.
- **Done when:** explained, or the passes merge and the pass count drops.

### 5. Frames of exactly 25 ms (pacing)

- **Question:** why do 501 frames take exactly 25.01 ms and 51 exactly
  29.18 ms, with a 60 FPS limit on the 120 Hz panel?
- **What is known:**
  - 25 ms is three 120 Hz refreshes.
  - A frame that misses its 16.67 ms slot waits for the next one the
    limiter and display link allow.
  - 29.18 ms is 3.5 refreshes: that is not simple display pacing.
  - This run had capture on, which costs every frame.
- **Steps:**
  1. Repeat without capture or validation (`pp perf`, the same route) and
     see whether the pattern stays.
  2. If it does, read `hitches.txt` around them, and look at `PacedMetalLayer`
     and `FramePacer` (the frame limit) against DXMT's present, with the
     `drawable_block` figure in `[FRAME_STATS]` (12-15 ms a window).
  3. This overlaps the performance plan's baseline item: use its 720/60
     runs.
- **Done when:** the 25 ms frames are counted in a clean run and explained.

### 6. Fences and residency calls (CPU and GPU, to measure)

- **Question:** does DXMT's synchronisation per pass serialise the GPU or
  cost encode time?
- **What is known:**
  - 168 fence waits and 57 updates a frame: 6-10 waits per render pass.
  - 20-44 `useResource` calls on the busy passes.
- **Steps:**
  1. Compare with `passes.txt`'s spans. On a Mac, a Metal System Trace
     shows GPU idle between encoders directly.
  2. On Linux, check the pass timer's `at=` columns for gaps between
     consecutive encoders in one command buffer.
- **Done when:** gaps are found or ruled out.

### Not a lead

- **No FP16 in any of the 30 pipelines:** DXMT's shaders are all 32-bit.
  Hollow Knight is not ALU-bound (6 ms at a 60 FPS limit), so
  half-precision would matter only for heavier titles. Revisit with The
  Witcher 3.

## Reusing the runs

The captures are in their run directories; `pp gpu read BUNDLE` reads them
(call names need `pp gpu names --fetch` once). The logs are
`run/pull/s1-host.log` in each. They stay in `$PLAYPORT_BUILD`. Before
relying on a number here in new work, repeat the run on the current build.

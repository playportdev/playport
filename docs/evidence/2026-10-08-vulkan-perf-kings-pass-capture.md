# Vulkan performance: King's Pass at native, captured on DXMT and on DXVK

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 7 (GPU energy a frame at native). **Kind:** measurement only. No code
changed and no build was made. **IPA:** dev
`55ca5c34df9cdb72de6d290533e4a4e622ad58058e30ffe91b8dac9c078276d7` (commit `c8c6016`). It carries
`patches/mesa` 0019 and 0020 behind `MESA_KK_EXPERIMENTAL`, so with the flags off it runs as HEAD
`c17946c`.

**Result:**

- **No structural extra work on the Vulkan side (fact).** DXVK's King's Pass frame has the same
  game passes as DXMT's: the same sizes, formats, load and store actions and draw chains. It has no
  render-pass split or forced load or store that DXMT's lacks. Its only extra full-resolution pass
  is the known present copy (item 4). On attachment traffic it moves *fewer* nominal bytes than
  DXMT's frame did (477 against 625 MB). H3 is ruled out for these frames.
- **The flagged run left the blocker in place (fact; it was not tested before).** With
  `MESA_KK_EXPERIMENTAL=narrow_usage,private_memory` (chunk 8's test), KosmicKrisp's render targets
  were private, as intended. But the scene colour targets and the depth target still had **pixel
  format view** usage (`0x15`), and Apple documents that usage as turning off lossless compression.
  DXMT's are `0x5`. Chunk 8's null result therefore says nothing about compression.
- **Top cause (inference):** Unity's TYPELESS render targets are uncompressed on Vulkan. DXVK
  creates them with the format list of the whole typeless family (UNORM, SNORM, SRGB, UINT, SINT).
  KosmicKrisp then sets pixel format view usage, and chunk 8's `narrow_usage` rule kept it, because
  it accepted only the sRGB twin. This is the defect `patches/dxmt` 0009 fixed in DXMT, and it had
  the same signature: native King's Pass at 13 ms, the menu unchanged
  ([lossless compression](2026-09-26-hk-lossless-compression.md)).

## Runs (one locked session each, warm, no `--cool`)

Every run used
`pp gpu capture --settings '{"screen":"native","frameLimit":0,"graphics":…}' --pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk`.
The run directories are under `$PLAYPORT_BUILD/gpu-runs/`.

| run | graphics | `--frame` / `--secs` | outcome |
|---|---|---|---|
| `vk-kp-dxmt-1` | `dxmt`, `--pass-prof` | 9000 / 150 | King's Pass frame, 664 MB; `passes.txt` has 26 sampled frames |
| `vk-kp-dxvk-1` | `vulkan` | 7200 / 150 | no capture: the play did not reach present 7200 by `first-frame+150`. It started at `serious`, straight after the DXMT run |
| `vk-kp-dxvk-2` | `vulkan` | 4800 / 240 | wrong scene: captured at about `first-frame+37`, before King's Pass (17 passes, 21 draws). Not used |
| `vk-kp-dxvk-3` | `vulkan` | 6600 / 240 | King's Pass frame, captured at `first-frame+90`, 1.5 GB |
| `vk-kp-dxvk-pm-1` | `vulkan` + flags | 6600 / 240 | no capture: the set launch logged `ui: undo session …: restored gpuCaptureFrame, …`, so the play ran without the capture switch (PLA-82's settings undo) |
| `vk-kp-dxvk-pm-2` | `vulkan` + flags | 6600 / 240 | King's Pass frame (a spot with more grab copies), 877 MB |

The flags were `"graphicsOptions":"MESA_KK_EXPERIMENTAL=narrow_usage,private_memory"`. The DXMT
and DXVK frames are at different spots of the walk, because each backend reaches a given present
number at a different time. The game's own passes vary with what is on screen: grab copies
numbered 3 in the DXMT frame, 1 in `vk-kp-dxvk-3` and 10 in `vk-kp-dxvk-pm-2`. Pass-by-pass
comparisons below therefore match passes by role, not by index.

Each frame was read with `pp gpu read --calls` and `--json`, and the texture and heap descriptors
with `dumptex.py` (build area, `agent-notes/vk-gpu-energy/`). The per-pass tables and bytes come
from two small readers of the `--json` output (`agent-notes/vulkan-perf/chunk9-passes.py`,
`chunk9-bytes.py`).

## The frames, pass by pass (facts from the captures)

- In the DXMT column: C is clear, L load, S store, x don't care. KosmicKrisp encodes every store as
  Unknown (`U`). The calls show it sets Store at the end of every pass (`setColorStoreAction 1`,
  `setDepthStoreAction 1`, `setStencilStoreAction 1`).
- "Copy" is a full-screen `copyFromTexture` of the scene colour target into a grab texture. It is a
  blit encoder on DXMT and a compute encoder on Metal 4 (KosmicKrisp).

| role | DXMT `vk-kp-dxmt-1` (29 encoders, 103 draws) | DXVK `vk-kp-dxvk-3` (27 encoders, 96 draws) |
|---|---|---|
| clear-only RGBA8 full res | 0: C/S | 0: C/U, then a 1-texel upload (comp 1) |
| small camera 782×360, D32FS8 | 1: C/S, 7 draws | 2: C/U, 9 draws |
| 782×360 one-quad chain (D16) | 2–6: L/S | 3–7: L/U |
| depth clear-only full res | 7 | (folded into the scene pass's clear) |
| scene RGBA8 + D32FS8 full res | 8 C/S (14 draws), copy, 10 L/S (30), copy, 12 L/S (13), copy, 14 L/S (3 draws, 63 prims) | 8 C/U (15 draws), 9 L/U (35), copy, 11 L/U (3 draws, 63 prims) |
| bloom 684×315 chain | 15–19 (5 one-quad passes) | 12–16 (the same 5) |
| full-res one-quad passes | 20, 21 | 17, 18 |
| scene + HUD | 22 (1 draw, L/S), 23 (15 draws, its own depth C/S) | 19 (17 draws, scene depth L/U) |
| full-res pass with depth | 24: colour L/S, depth **L/x** | 20: colour L/U, depth **L/U (stored)** |
| depth clear-only, small upload | 25, 26 | 22, comp 21 |
| final full-res one-quad | 27 | 23 |
| present | 28: DXMT's quad into the drawable | comp 24 (1-thread `libkk_write_u32`), 25 DXVK's blit into its swap-chain image, 26 the WSI's blit into the drawable |

- **Render-pass splits.**
  - Every DXMT split of the scene pass sits at a grab copy.
  - DXVK's frame has one split with no copy (8 → 9, nothing between the two encoders). It was
    preceded by in-pass barriers (`barrierAfterEncoderStages 1 2`). It costs what one DXMT
    copy boundary costs.
  - There is no other split. MSAA is off: every target has 1 sample on both backends.
- **Formats.** Both use RGBA8 colour, D32FS8 scene depth, D16 for the small chain, and
  BGRA8 for the drawable.
- **Resolution.** The same on both. The scene, the one-quad passes and the copies are 2736×1260;
  the bloom chain is 684×315 and the camera 782×360. Neither backend renders at another size or
  scales.

### Attachment traffic a frame (uncompressed bytes; inference from load and store actions)

How it was counted:
- A Load reads the attachment and a Store writes it, at 4 B/px for RGBA8, 5 B/px for D32FS8 and
  2 B/px for D16.
- A full-res copy reads 13.8 MB and writes 13.8 MB.
- Shader texture reads are not counted. The present path's sampled reads are added at the end.

| | DXMT `vk-kp-dxmt-1` | DXVK `vk-kp-dxvk-3` | DXVK + flags `vk-kp-dxvk-pm-2` |
|---|---|---|---|
| attachments, read + write | 625.0 MB | 449.2 MB | 1007.7 MB |
| full-res copies | 3 (counted above) | 1: +27.6 MB | 10: +276 MB |
| present path (sampled reads) | 1 quad: +13.8 MB | 2 blits: +27.6 MB | +27.6 MB |
| **total** | **≈ 639 MB** | **≈ 504 MB** | **≈ 1311 MB** |

Notes on the table:
- The two plain frames come from different spots. Within those spots, the Vulkan frame moves *less*
  attachment data than DXMT's, because its spot had two fewer grab copies.
- The flagged frame's spot is heavier: 10 copies and 16 scene splits.
- The only extras that are Vulkan's by construction are about 45 MB:
  - the WSI copy, 27.6 MB (item 4, cannot be removed safely);
  - the depth store in pass 20, 17.2 MB, where DXMT stores none.
- These cannot double the GPU time.

### Texture usage and storage (facts from `dumptex.py`, descriptor word 13: 0 shared, 2 private)

| full-res render target | DXMT | DXVK (flags off) | DXVK + `narrow_usage,private_memory` |
|---|---|---|---|
| RGBA8 scene and post targets | `0x5`, private, standalone (`newTextureWithDescriptor`) | `0x17`, shared, in a placement heap with a whole-heap buffer | **5 × `0x15`**, 2 × `0x5`, 1 × `0x17`, all private in placement heaps (options `0x120`) |
| D32FS8 depth | `0x15`, private | `0x17`, shared | `0x15`, private |
| swap-chain images | – | `0x16`, shared | `0x4` (3 private, 3 shared in the WSI) |

- In the flagged run, 11 heaps are private (`resourceOptions 288`) and 34 shared (256). All have
  sparse page size 16.
- Usage bits: `0x1` shader read, `0x2` shader write, `0x4` render target, `0x10` pixel format view.
- Apple's "Optimizing texture data" lists pixel format view among the usages that stop lossless
  compression (as quoted in the GPU-energy notes).

**Why `0x15` survived `narrow_usage` (fact from the code):**

- DXVK makes a TYPELESS texture mutable, with the whole family as its format list
  (`d3d11_texture.cpp:85-92`). For `R8G8B8A8_TYPELESS` the family is UNORM, SNORM, SRGB, UINT and
  SINT (`dxgi_format.cpp:616-620`).
- Chunk 8's `kk_image_srgb_views_only` dropped pixel format view only when every listed format is
  the image's own format or its sRGB or linear twin. So it kept the flag on every typeless target,
  and Unity makes its render textures TYPELESS.
- The two `0x5` targets are typed ones, whose format list is only UNORM and SRGB.

### Shaders (facts from the KosmicKrisp capture's MSL)

The capture holds the MSL KosmicKrisp compiled (53 libraries, 30 fragment shaders). Neither
backend's capture has GPU time per shader, and KosmicKrisp's Metal 4 pipelines have no compiler
statistics, so per-shader cost cannot be compared.

- 28 of the 30 fragment shaders read `[[sample_id]]` and `[[sample_mask]]`, write `[[sample_mask]]`
  (`gl_SampleMask & 1`), and end in `discard_fragment`. That is `KK_WORKAROUND_7` with
  `msl_lower_static_sample_mask` (`kk_shader.c:601-617`). It applies because DXVK's sample mask,
  masked to one sample, is not `UINT16_MAX`.
- 15 of the 30 read `[[color(0)]]`: blending is lowered into the shader (`kk_lower_fs_blend`,
  `nir_lower_blend`).
- Inference: these cost something per pixel, but they cannot explain the native-only doubling:
  - At 720/free in King's Pass, DXVK's GPU time equals DXMT's (5.8 against 5.1–5.9 ms), and a
    per-pixel ALU cost would show there in the same proportion.
  - The cooled DXVK run's first King's Pass bucket at native was 7.2 ms (DXMT 6.7) before it
    doubled (the [private memory](2026-10-08-vulkan-perf-private-memory.md) record).

### DXMT's GPU time per pass (`vk-kp-dxmt-1/passes.txt`, fact)

- The two King's Pass reports (presents 7898 and 9112) sum to 6.7–6.9 ms of fragment time, with
  29 encoders and 94–95 draws.
- Over all 26 sampled frames, the largest groups are:
  - full-res scene passes with load and store of colour and depth, 3.10 ms a frame;
  - blits, 1.29 ms;
  - full-res one-quad colour passes, 1.06 ms.
- At native, the frame's time goes to full-res colour and depth traffic. That is the work lossless
  compression shrinks.

## Conclusions

1. **Fact:** the Vulkan King's Pass frame does the same passes at the same size, formats and actions
   as DXMT's. It has no MSAA, no other render size and no scaling. The extra work is about 45 MB:
   the WSI copy plus one depth store. H3 (KosmicKrisp splits or forced loads) is not the cause.
2. **Fact:** in the chunk-8 flagged run, the TYPELESS scene targets kept pixel format view (`0x15`),
   so that run never removed the documented compression blocker from them.
3. **Inference (top cause):** the Vulkan route's full-res TYPELESS colour targets are not
   losslessly compressed, where DXMT's (`0x5`, private, after `patches/dxmt` 0009) are. Five
   observations fit:
   - the doubling depends on resolution and scene: equal at 720, equal in the light menu, double in
     King's Pass at native;
   - it is the same signature DXMT had before 0009;
   - per-frame energy is higher even at equal GPU time;
   - native King's Pass is the only case where the uncompressed traffic pushes the GPU's power into
     the budget;
   - the captures show no other difference large enough.
4. **Inference (second, bounded):** the present path's extra full-res pass and the stored depth in
   pass 20 add about 45 MB a frame uncompressed (about 7–9 % of the frame's attachment bytes).
   The `sample_mask`/`discard` epilogue in 28 of 30 fragment shaders is an unmeasured per-pixel cost.
   Neither can produce a 2× at native alone.

## Proposed changes (not implemented)

1. **Widen `narrow_usage`'s view-format rule to layout-preserving families** (first; `patches/mesa`,
   `kk_image.c` `kk_image_srgb_views_only` as chunk 8 drafted it, in
   `agent-notes/vulkan-perf/chunk8-patches/0019.patch`).
   - **Rule:** treat a format list as needing no pixel format view when every listed format keeps
     the image format's component layout (the same block size, channel count, order and bit
     widths), for example `R8G8B8A8_{UNORM,SNORM,SRGB,UINT,SINT}`. This is the rule
     `patches/dxmt` 0009 applies, under Apple's statement that the flag is needed only for a view
     that changes the component layout.
   - **Depth/stencil and block-compressed formats keep the flag.**
   - **Test:** one IPA, behind the existing flag. A capture (`pp gpu capture`, `vk-kp-dxvk-*`) should
     show the scene targets at `0x5`. Then one warm native/free pair. Run with `narrow_usage`
     alone first; add `private_memory` only if `narrow_usage` alone does not move the King's Pass
     doubling. That separates usage from storage.
   - **Risk:** a view in a format whose layout differs would then need the flag. Metal's
     validation would report such a view, and DXMT logs none (`[pfv-view]`).
2. **If 1 moves King's Pass but leaves a gap:**
   - the depth store in pass 20, where DXMT's matching pass does not store depth: compare the
     store op DXVK passes for it (`dxvk_context.cpp` render-pass ops) with DXMT's don't-care;
   - after that, `KK_WORKAROUND_7`'s sample-mask epilogue for single-sample pipelines
     (`kk_shader.c` `kk_lower_fs`): skip it when `rasterization_samples` is 1 and the mask covers
     that sample.

   Each is one change and one warm pair.

## Games observed

| title | IPA | run directory | outcome |
|---|---|---|---|
| Hollow Knight (367520), DXMT, native/free | `55ca5c34…` | `gpu-runs/vk-kp-dxmt-1` | played to `first-frame+150`, capture written |
| Hollow Knight (367520), DXVK, native/free | `55ca5c34…` | `gpu-runs/vk-kp-dxvk-1`, `-2`, `-3` | played to `first-frame+150` / `+240` each, no crash. Capture 1 not reached, capture 2 in the wrong scene, capture 3 in King's Pass |
| Hollow Knight (367520), DXVK with flags, native/free | `55ca5c34…` | `gpu-runs/vk-kp-dxvk-pm-1`, `-pm-2` | played to `first-frame+240` each, no crash. Capture 1 lost to the settings undo, capture 2 in King's Pass |

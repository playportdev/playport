# Vulkan performance: lossless compression on Unity's TYPELESS targets (KosmicKrisp texture usage, kept)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 7 (GPU energy a frame at native). **Change:** `patches/mesa` 0019
(`kk: texture usage that keeps lossless compression on render targets`).
**IPAs (dev):**

- flag IPA `8ea52bd99c89bb4da834b156f2e7ed3da4dd16fd8f10ac84d316897b8b033018` (commit `1545734`):
  the change behind `MESA_KK_EXPERIMENTAL=narrow_usage`, so one IPA ran the control and the change;
- default IPA `4e6e930d5289b1a6d54bd61468eee97dd2b28122883039d827465c3ae09f87d7` (commit `ca12f08`):
  the change on by default, and `MESA_KK_DEBUG=wide_usage` restores KosmicKrisp's own usage.

**Result:**

- **Fact:** the full-res RGBA8 scene and post targets are now `0x5` (shader read, render target),
  like DXMT's. In the [King's Pass capture](2026-10-08-vulkan-perf-kings-pass-capture.md) they were
  `0x17`, and `0x15` under chunk 8's sRGB-only rule.
- **Fact:** at native/60, with the change both routes held 60 FPS through King's Pass, and their
  controls did not (37.5 and 53.5 FPS in the window). Energy a frame fell by 33 % on DXVK and by 21 %
  on vkd3d. On vkd3d, phone power also fell by 12 % (4862 → 4299 mW).
- **Kept, on by default.** No view changed the layout: no `[kk-pfv-view]` line came in any play. The
  end screenshots show the same scenes.
- **Caveat:** every pair here ran warm and on the charger, and the controls reached thermal pressure
  20 where the changed runs did not. This held in either order: the change ran first in one pair
  and second in the other. The cooled exit runs are the confirmation.

## The rule (`patches/mesa` 0019)

KosmicKrisp at the pin sets Metal shader write on every image that a transfer can write. It also
sets pixel format view on every `MUTABLE_FORMAT` image. Apple's "Optimizing texture data" says
Metal does not compress a texture with either usage losslessly.

DXVK makes every TYPELESS texture mutable. Its format list is the whole family
(`d3d11_texture.cpp:85-92`; for `R8G8B8A8_TYPELESS`, UNORM, SNORM, SRGB, UINT and SINT:
`dxgi_format.cpp:616-620`). Unity makes its render textures TYPELESS.

The patch changes two usages:

- **Shader write only for `STORAGE` images.** Transfers into an image are Metal copies or render
  passes (clears, blits, resolves). The gate in chunk 8 already ran this half.
- **No pixel format view when every listed view format keeps the image format's component
  layout.**
  - The test is on Mesa's format description: the same block bits, the same number of channels,
    and for each channel the same size, bit position and swizzle. An sRGB or linear twin always
    passes.
  - The justification is Apple's `MTLTextureUsage.pixelFormatView` page (kept in the build area,
    `agent-notes/vk-gpu-energy/metal_mtltextureusage_pixelformatview.json`). The usage is needed
    only "to create a texture view with a different component layout". It continues: "The pixel
    layout is considered different if the number of components differs, or if their size or order
    is different". For a change between linear and sRGB: "Don't set this option". The numeric type
    is not part of the layout, so UNORM, SNORM, UINT, SINT and FLOAT views of one layout need no
    flag.
  - `patches/dxmt` 0009 relies on the same statement (colour typeless families). It has run on
    Hollow Knight since 2026-09-26 ([lossless compression](2026-09-26-hk-lossless-compression.md)).
  - This rule is narrower than DXMT's, because it reads the format list. The usage stays on:
    - when a listed format has another layout, as when DXVK adds `R32_UINT`, `R32_SINT` and
      `R32_SFLOAT` for the UAV of an R32-compatible format;
    - on an image without a format list, since any compatible format may come;
    - on a block-texel-view-compatible image;
    - on depth/stencil and on every non-plain format (block compressed, shared exponent, planar);
    - on `Z32_FLOAT_S8X24`, as before.
  - Internal views keep the layout:
    - KosmicKrisp's own copies use Metal blits, or go through a buffer when the formats differ
      (`kk_cmd_copy.c`);
    - its meta blits, resolves and clears view an image in its own format.
- **Diagnostic.** A view that changes the format of a texture made without pixel format view,
  other than to its sRGB or linear twin, is logged as `[kk-pfv-view]` (the first 32), as DXMT logs
  `[pfv-view]`. KosmicKrisp's `stderr` reaches `s1-host.log` (its `[kk] frame` capture lines are
  there).

## Runs

Every play ran warm, with no `--cool`, on the charger at 100 %. Run directories are under
`$PLAYPORT_BUILD/` (`perf-runs/`, `gpu-runs/`, `ui-runs/`). No run logged `Metal HUD off` or
`ui: undo session` (PLA-82), so none is void.

### Session 1 (flag IPA `8ea52bd9…`): gate, capture, native/free pair

**Gate**, `--until first-frame+10 --shot`; every play reached its first frame, with no
`[kk-pfv-view]` line:

| play | run | first frame |
|---|---|---|
| Hollow Knight, default (Vulkan on this phone) | `ui-runs/20261008T113631` | +10.55 s |
| Hollow Knight, DXMT | `ui-runs/20261008T113722` | +9.99 s |
| Portal 2, default | `ui-runs/20261008T113814` | +5.74 s |
| Hollow Knight, flag | `ui-runs/20261008T113858` | +10.11 s |
| Hollow Knight, D3D12 (`-force-d3d12`), flag | `ui-runs/20261008T113950` | +8.82 s |
| Portal 2, flag | `ui-runs/20261008T114040` | +5.48 s |

The flagged plays' logs carry `MESA_KK_EXPERIMENTAL=narrow_usage`.

**Capture** `gpu-runs/vk-kp-dxvk-nu-1`:

- The command was chunk 9's `vk-kp-dxvk-3` with the flag:
  `pp gpu capture --frame 6600 --secs 240 --settings '{"screen":"native","frameLimit":0,"graphics":"vulkan","graphicsOptions":"MESA_KK_EXPERIMENTAL=narrow_usage"}' --pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk`.
- It caught a King's Pass frame: 29 passes and 103 draws, with the full-res scene passes and
  grab copies.
- The textures were read with chunk 9's `dumptex.py`, through a small summariser
  (`agent-notes/vulkan-perf/c10-usage.py`; descriptor word 11 is usage, word 13 is storage).

Full-res (2736×1260) textures:

| texture | count | DXVK flags off (`vk-kp-dxvk-3`) | chunk 8 flags (`vk-kp-dxvk-pm-2`) | **0019 flag (`vk-kp-dxvk-nu-1`)** |
|---|---|---|---|---|
| RGBA8 scene and post targets | 7 | 8 × `0x17` | 5 × `0x15`, 2 × `0x5`, 1 × `0x17` | **7 × `0x5`**, shared |
| RGBA8 UAV target | 1 | (in the 8 above) | (the `0x17`) | **`0x7`** (shader write kept for storage, no pixel format view) |
| D32FS8 depth | 2 | `0x17` | `0x15` | `0x15` (`Z32_FLOAT_S8X24` keeps pixel format view; DXMT's depth is `0x15` too) |
| BGRA8 swap-chain images | 3 | `0x16` | `0x4` | `0x4` |

Storage is shared (word 13 = 0), because `private_memory` (chunk 8) is not part of this change.
DXMT's targets are private.

**Native/free pair** (`{"screen":"native","frameLimit":0,"graphics":"vulkan"}`, route v2 pads,
`--secs 130`): control `vk-nat-dxvk-nu-ctl`, then flag `vk-nat-dxvk-nu-1`. `pp perf --compare
… --window 85:125`:

| run | thermal | budget min | FPS | p99 ms | GPU ms | gpu% | CPU mW | sys mW | CPU mJ/f | sys mJ/f |
|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxvk-nu-ctl` | serious throughout | 404 mW (client 11, from t = 30) | 40.4 | 50.0 | 18.7 | 85.9 | 149 | 3092 | 3.70 | 76.5 |
| `vk-nat-dxvk-nu-1` | serious throughout | 1099 mW (no client 11) | 49.9 | 41.7 | 12.29 | 72.3 | 167 | 3700 | 3.35 | 74.1 |
| DXMT cooled reference `vk-nat-dxmt-1` | nominal → fair | – | 108.9 | | 7.5 | | | | | 61 |

The 5-s buckets around the start of King's Pass (GPU ms / FPS):

| t | 65 | 70 | 75 | 80 | 85 | 90 |
|---|---|---|---|---|---|---|
| control | 6.88 / 117.6 | 28.74 / 32.1 | 24.88 / 37.4 | 24.15 / 37.5 | 22.43 / 37.3 | 16.32 / 40.6 |
| flag | 10.96 / 57.3 | 23.00 / 43.1 | 15.19 / 48.9 | 11.81 / 45.6 | 10.65 / 46.6 | 10.29 / 49.8 |

- GPU time did not stay at about 7 ms after King's Pass started. Both runs were at `serious` from
  the first second, with the P cores parked from t = 70–75. The GPU's clock under that budget is
  not the cooled reference's.
- **This pair is budget-confounded.** From t = 30 the control ran under a CPMS client-11 budget of
  404 mW, which the flagged run never had (minimum 1099). Part of its GPU-ms gain (−34 %) may be
  that clamp. The energy a frame moved only −3 % (sys) and −9 % (CPU), so the pair did not decide
  keep or revert, and a second pair was run.
- The end screenshots (`shot-ff128.png`) show the same King's Pass spot, drawn the same way.

### Session 2 (flag IPA): native/60 DXVK pair, order reversed

The settings were `{"screen":"native","frameLimit":60,"graphics":"vulkan"}`. The flag ran first
(`vk-n60-dxvk-nu-1`), then the control (`vk-n60-dxvk-nu-ctl`), so that a first-run budget could not
favour the change. At an equal frame rate, power is directly comparable. Window 85–125 s:

| run | thermal | budget min (first s) | FPS | p99 ms | h25 | GPU ms | gpu% | P% | CPU mW | sys mW | CPU mJ/f | sys mJ/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-n60-dxvk-nu-1` (flag) | serious → fair, max pressure 10 | 769 (t = 111) | **59.9** | 25.0 | 63 | 15.07 | 94.5 | 88 | 573 | 4100 | 9.56 | **68.5** |
| `vk-n60-dxvk-nu-ctl` | fair → serious, pressure 20 from t = 25 | 1506 (before the play) | 37.5 | 58.4 | 1029 | 21.3 | 87.9 | 0 | 144 | 3852 | 3.83 | **102.7** |

- The flagged run held 60 FPS from t = 70 to the end. The control fell to 33–41 FPS once King's Pass
  started, with GPU time of 17–28 ms and the P cores parked.
- The flagged run drew 6 % more phone power for 60 % more frames: −33 % sys energy a frame.
- Its GPU ms at the cap (about 15) is the GPU running at a lower clock to fit the 16.7-ms frame, not
  extra work.
- The flagged run's CPU mW is higher because its P cores stayed on (pressure 10). The control's
  were parked at pressure 20.
- The end screenshots show the same spot. The flagged run's Knight is further into the dark cave,
  with the radial light the DXMT 720/60 reference `vk-60-dxmt-1` shows at the same point. The
  control's is still in the lit part.

**Decision (supervisor's criteria):** keep as the default. The changed run had lower GPU ms, held
the cap the control could not hold (GPU headroom), and rendered the same. Its sys mW is higher only
because it drew 60 % more frames, and its energy a frame is lower.

### Session 3 (default IPA `4e6e930d…`): gate, native/60 vkd3d pair

**Gate**: every play reached its first frame, with no `[kk-pfv-view]` line.

| play | run | first frame |
|---|---|---|
| Hollow Knight, default | `ui-runs/20261008T120833` | +10.44 s |
| Hollow Knight, DXMT | `ui-runs/20261008T120924` | +10.02 s |
| Hollow Knight, D3D12 | `ui-runs/20261008T121015` | +8.79 s |
| Portal 2, default | `ui-runs/20261008T121107` | +5.92 s |

**vkd3d pair:** `{"screen":"native","frameLimit":60,"graphics":"vulkan","arguments":"-force-d3d12"}`.
This time the control ran first: `vk-n60-vkd3d-wide-ctl`, with
`"graphicsOptions":"MESA_KK_DEBUG=wide_usage"`. The default followed (`vk-n60-vkd3d-nu-1`). The
control's log shows `graphics options: MESA_KK_DEBUG=wide_usage`. It also has none of the
`MESA_KK_DEBUG=compile` lines the default run has, so the switch replaced the app's `compile`
default and reached KosmicKrisp. Window 85–125 s:

| run | thermal | budget min | FPS | p99 ms | h25 | GPU ms | gpu% | P% | CPU mW | sys mW | CPU mJ/f | sys mJ/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-n60-vkd3d-wide-ctl` (`wide_usage`) | fair → serious, pressure 20 from t = 90 | 769 | 53.5 | 37.5 | 344 | 15.17 | 83.5 | 63 | 481 | 4862 | 8.98 | **90.9** |
| `vk-n60-vkd3d-nu-1` (default) | serious, no pressure | 1617 | **59.7** | 25.0 | 206 | 12.94 | 83.4 | 64 | 555 | **4299** | 9.29 | **72.0** |

- The control held 60 FPS until t = 105, then fell to 39–47 FPS once its P cores parked. The default
  held 60 FPS to t = 125.
- The default drew 12 % less phone power at the higher frame rate: −21 % sys energy a frame. Its
  GPU time was 15 % lower.
- The default's end screenshot shows King's Pass drawn correctly, the same dark-cave spot as the
  DXMT reference.

## Reading

1. **Fact:** under the new rule, no Hollow Knight scene target has pixel format view or shader write
   (`0x5`), as on DXMT. Nothing in the gate or in Portal 2 (DXVK i386) viewed a texture in another
   layout.
2. **Fact:** in two native/60 pairs, one per route and in opposite orders, the change held 60 FPS
   through King's Pass with the GPU below its control. It used 21–33 % less phone energy a frame.
   Its controls reached pressure 20 and dropped frames.
3. **Inference:** the thermal difference is the effect, not the cause. The change starts each pair
   at the same or a hotter state (`serious` against `fair`) and still ends cooler. Less
   uncompressed traffic means less GPU and memory power, and so a smaller thermal load. A
   warm-pair result is still not a cooled one. The exit runs (cooled, native/free and 720/60 per
   backend) are where the gap to DXMT's 7.5 ms and 61 mJ/f is measured next.
4. **Open:** native/free on a warm phone stayed far from DXMT (49.9 FPS, 12.3 ms at `serious`). The
   change is necessary, but whether it is enough is for the cooled exit run. The storage half
   (private memory, chunk 8) and the leads in the [King's Pass capture](2026-10-08-vulkan-perf-kings-pass-capture.md)
   (the depth store in pass 20, the `KK_WORKAROUND_7` sample-mask epilogue) stay as the next
   levers if a gap remains.

## Games observed

| title | IPA | run directory | outcome |
|---|---|---|---|
| Hollow Knight (367520), Vulkan/DXVK default and flag, DXMT, D3D12 flag | `8ea52bd9…` | `ui-runs/20261008T113631`, `T113722`, `T113858`, `T113950` | gate: first frame +8.8 to +10.6 s, ran to `first-frame+10` |
| Portal 2 (620), default and flag | `8ea52bd9…` | `ui-runs/20261008T113814`, `T114040` | gate: first frame +5.5 to +5.7 s |
| Hollow Knight (367520), DXVK native/free, flag | `8ea52bd9…` | `gpu-runs/vk-kp-dxvk-nu-1` | played to `first-frame+240`, King's Pass frame captured |
| Hollow Knight (367520), DXVK native/free and native/60, flag and control | `8ea52bd9…` | `perf-runs/vk-nat-dxvk-nu-ctl`, `-nu-1`, `vk-n60-dxvk-nu-1`, `-nu-ctl` | 130 s each, King's Pass, no crash |
| Hollow Knight (367520), default, DXMT, D3D12 | `4e6e930d…` | `ui-runs/20261008T120833`, `T120924`, `T121015` | gate passed |
| Portal 2 (620), default | `4e6e930d…` | `ui-runs/20261008T121107` | gate passed |
| Hollow Knight (367520), vkd3d native/60, default and `wide_usage` | `4e6e930d…` | `perf-runs/vk-n60-vkd3d-nu-1`, `vk-n60-vkd3d-wide-ctl` | 130 s each, King's Pass, no crash |

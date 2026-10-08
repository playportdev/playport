# Vulkan performance: private-storage memory and narrow texture usage on KosmicKrisp (not kept)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 7 (GPU energy a frame at native). **IPA:** dev
`55ca5c34df9cdb72de6d290533e4a4e622ad58058e30ffe91b8dac9c078276d7` (commit `c8c6016`).

**Result:**

- With `patches/mesa` 0019 and 0020 switched on, DXVK's render targets can live in a private-storage
  Metal heap with no buffer over it, and none of their textures have shader write or pixel format
  view usage.
- That did not move native/free. The Vulkan route's GPU time a frame still doubles when King's Pass
  starts: 6.35 → 13.42 ms with the flags, 6.25 → 14.11 ms without them. In the King's Pass window
  (85–125 s) it is 13.17 ms with the flags against 13.00 without.
- Both patches are **reverted**: their files and series lines went in one commit. Hypothesis
  H1(a) of the investigation is therefore not confirmed. It said that shared storage or the
  whole-heap buffer alias blocks lossless compression.

## Lead

- **When the GPU time doubles.** In the cooled native/free runs of the
  [profile record](2026-10-08-vulkan-perf-profile.md), the Vulkan routes' GPU time a frame doubles
  when King's Pass starts (the t = 75 s bucket). It does not double when thermal pressure arrives:
  DXVK and vkd3d ran King's Pass at 7.2 and 6.6 ms in the t = 70 bucket, already at pressure 10.
  The CPMS budget then clamps. DXMT holds about 7 ms there with no budget at all.
- **DXMT once showed the same signature.** Before `patches/dxmt` 0009 restored lossless
  compression, DXMT went from 6.7 to 13 ms in King's Pass
  ([lossless compression](2026-09-26-hk-lossless-compression.md)).
- **The step-0 captures differ in storage.**
  - All 366 KosmicKrisp textures are shared-storage textures in a sparse placement heap that a
    whole-heap `MTLBuffer` aliases (usage `0x17`).
  - DXMT's render targets are private, standalone textures (usage `0x5`).
- **The usage flags alone did nothing.** The earlier 0019 changed only them and moved nothing.
- **Hypothesis H1(a):** shared storage, or the buffer alias, blocks compression.

## The change

The two patches were drafted in a read-only investigation of the GPU-energy gap that followed
[the profile record](2026-10-08-vulkan-perf-profile.md); its notes are in the build area
(`agent-notes/vk-gpu-energy/`). Both were
reviewed, then integrated as `patches/mesa` 0019 and 0020. Both sit behind `MESA_KK_EXPERIMENTAL`
flags, so one IPA ran the control and the change. The Graphics options field already allows
`MESA_KK_EXPERIMENTAL` (decision 0060).

- **0019 `narrow_usage`.** This is the usage change of the earlier, unkept 0019, behind a flag:
  - Metal shader write only for `STORAGE` images.
  - No pixel format view when the image's format list names only the format and its sRGB or
    linear twin.
- **0020 `private_memory`.**
  - **Memory type.** A `DEVICE_LOCAL`-only memory type is listed first. Its `VkDeviceMemory` is a
    `MTLHeapTypePlacement` heap with `MTLResourceStorageModePrivate` and no buffer over the
    whole heap. The host-visible type moves to index 1.
  - **Image requirements.**
    - Images that cannot be private report only the host-visible type: linear, host image
      copy, sparse and external images.
    - Host-pointer imports also report only the host-visible type.
    - An image that may be private reports the larger texture size and alignment of a shared
      and a private heap. Requirements and binds share one function for this.
  - **Buffers.**
    - Buffers keep every type, because vkd3d-proton clears image memory with a buffer bound
      to it.
    - They take the larger buffer alignment of a shared and a private heap. This line was
      added in review: the draft left it open, and a misaligned `newBufferWithLength:offset:`
      in a private heap would return nil.
    - A buffer placed in a heap takes the heap's resource options.

**Review (no code path found that maps or reads a private allocation):**

- **Mapping.**
  - DXVK maps only memory it requested as `HOST_VISIBLE` (`dxvk_memory.cpp`, the mapped pool).
    Its images and GPU-only buffers ask for `DEVICE_LOCAL` and so take type 0.
  - vkd3d-proton takes the lowest candidate type.
  - The Metal WSI takes `wsi_select_device_memory_type`.
  - winevulkan's wow64 placed maps and host imports apply to host-visible memory only.
- **Index shift.** Nothing found hardcodes the memory type index 0.
- **KosmicKrisp internals.**
  - Every internal allocation (descriptor pools, uploads, queries, events, the sink page)
    still uses `kk_alloc_bo`, which is shared.
  - For a private allocation `bo->map`, `bo->cpu` and `bo->gpu` stay unset. The paths that touch
    such a bo are safe without them:
    - `kk_destroy_bo` and `kk_bo_set_label` check `map`.
    - Buffer binds make their own heap buffer, so a buffer's address is that buffer's.
      `mtl_get_contents` returns NULL for a private buffer.
    - Texel buffer views take the buffer's resource options.
    - An image's `plane->addr` is set and never read.

## Gate (one locked session, `pp install --no-build` first)

| play | settings | run | first frame | result |
|---|---|---|---|---|
| Hollow Knight, default (Vulkan, DXVK) | `{}` | `ui-runs/20261008T102734` | +9.70 s (JIT 2.42 s) | `first-frame+10` |
| Hollow Knight, DXMT | `{"graphics":"dxmt"}` | `ui-runs/20261008T102825` | +9.77 s (JIT 2.69 s) | `first-frame+10` |
| Portal 2, default (DXVK, i386) | `{}` | `ui-runs/20261008T102917` | +5.74 s (JIT 2.63 s) | `first-frame+10` |
| Hollow Knight, flags | `{"graphicsOptions":"MESA_KK_EXPERIMENTAL=narrow_usage,private_memory"}` | `ui-runs/20261008T103001` | +9.75 s (JIT 2.55 s) | `first-frame+10` |
| Hollow Knight D3D12, flags | `{"graphics":"vulkan","arguments":"-force-d3d12","graphicsOptions":"…same"}` | `ui-runs/20261008T103054` | +9.02 s (JIT 2.55 s) | `first-frame+10` |
| Portal 2, flags | `{"graphicsOptions":"…same"}` | `ui-runs/20261008T103146` | +5.79 s (JIT 2.58 s) | `first-frame+10` |

**Memory types with the flags.** The flags took effect. DXVK's device log in the flagged Hollow
Knight and Portal 2 plays lists two types:

```
info:      Type  0: DEVICE_LOCAL
info:      Type  1: DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT | HOST_CACHED
```

Without the flags (control run) it lists one: `Type  0: DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT |
HOST_CACHED`. Every screenshot is drawn correctly:
- the Hollow Knight title menu on DXVK and on D3D12;
- Portal 2's "powered by Source" screen;
- both runs' King's Pass at t = 128 s, the Knight at the same spot.

## The warm native/free pair (route v2, no `--cool`, straight after the gate)

`pp perf --secs 130 --settings '{"screen":"native","frameLimit":0,"graphics":"vulkan"[,"graphicsOptions":"MESA_KK_EXPERIMENTAL=narrow_usage,private_memory"]}' --pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk --shot first-frame+128`.
Run directories are `$PLAYPORT_BUILD/perf-runs/vk-nat-dxvk-pm-ctl` and `…/vk-nat-dxvk-pm-1`. Neither
log has a `Metal HUD off` or `ui: undo session` line (PLA-82).

**Thermal state** (`summary.json`):

| run | `thermal_start` | states | `first_pressure_s` / `max_pressure` | `budget_first_s` | budget start → min (mW) |
|---|---|---|---|---|---|
| `vk-nat-dxvk-pm-ctl` | nominal | nominal, fair, serious | 20 / 20 | 24 | 2874 → 769 |
| `vk-nat-dxvk-pm-1` | **serious** | serious | – / – (serious from the start) | 25 | 3491 → 934 |

**The pair's thermal state differs**, and it is flagged here. The change ran straight after the
control and started at `serious`. Both runs were under a CPMS budget from t ≈ 25 s, before King's
Pass. The cooled references (`vk-nat-dxvk-1`, `vk-nat-dxmt-1`) are shown for orientation only.

**Windows** (`pp perf --compare … --window`). CPU mJ/f = CPU mW / FPS. Sys mW is the battery gauge,
with one sample every 5 s, so it is not reliable within one window (on the charger at 100 %).

| run | window | FPS | p99 | ≥25/50/100 | GPU ms | gpu% | Mi/f | P% | CPU mW | CPU mJ/f | sys mW | sys mJ/f | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxvk-pm-ctl` | 15–40 | 103.8 | 25.01 | 34/13/1 | 8.37 | 91.8 | 45.5 | 77.8 | 554 | 5.3 | 11510 | 110.9 | 12.7 | 2866 |
| `vk-nat-dxvk-pm-1` | 15–40 | 94.4 | 25.01 | 25/18/2 | 9.04 | 90.8 | 45.0 | 62.8 | 465 | 4.9 | 3597 | 38.1 | 13.7 | 2851 |
| `vk-nat-dxvk-pm-ctl` | 85–125 | 58.5 | 33.35 | 265/7/4 | 13.00 | 84.5 | 75.6 | 0 | 203 | 3.5 | 4430 | 75.7 | 18.0 | 3422 |
| `vk-nat-dxvk-pm-1` | 85–125 | 45.7 | 50.02 | 612/23/4 | 13.17 | 72.4 | 82.3 | 0 | 165 | 3.6 | 4869 | 106.6 | 22.1 | 3453 |
| `vk-nat-dxvk-pm-ctl` | 110–135 | 53.6 | 37.51 | 174/3/1 | 15.78 | 89.4 | 73.5 | 0 | 189 | 3.5 | 4597 | 85.8 | 19.2 | 3455 |
| `vk-nat-dxvk-pm-1` | 110–135 | 43.4 | 54.19 | 362/17/3 | 17.41 | 85.2 | 79.4 | 0 | 157 | 3.6 | 3863 | 89.0 | 23.3 | 3490 |
| `vk-nat-dxvk-1` (cooled ref.) | 85–125 | 57.7 | 37.51 | 280/8/3 | 13.40 | 86.0 | 76.6 | 0 | 200 | 3.5 | 5201 | 90.1 | 18.8 | – |
| `vk-nat-dxmt-1` (cooled ref.) | 85–125 | 108.9 | 20.84 | 9/1/1 | 7.46 | – | 53.1 | 75 | 900 | 8.3 | 6660 | 61.2 | 12.4 | – |

**The 5-s buckets around King's Pass.** The menu is t ≈ 15–60 s, King's Pass loads at t ≈ 65 s,
and `hk-walk` starts at t ≈ 80 s. Each cell is FPS / GPU ms / gpu% / P%:

| t | `vk-nat-dxvk-pm-ctl` | `vk-nat-dxvk-pm-1` (flags) | `vk-nat-dxvk-1` (cooled) | `vk-nat-dxmt-1` (cooled) |
|---|---|---|---|---|
| 65 | 81.9 / 6.25 / 80 / 92 | 81.9 / 6.35 / 83 / 93 | 82.3 / 6.13 / 65 / 90 | 89.5 / 6.64 / – / 99 |
| 70 | 68.1 / **14.11** / 98 / 61 | 70.8 / **13.42** / 70 / 71 | 119.0 / 7.22 / 92 / 104 | 119.6 / 6.74 / – / 113 |
| 75 | 64.1 / 14.99 / 98 / 0 | 55.1 / 14.73 / 93 / 0 | 63.2 / **15.70** / 100 / 39 | 120.0 / 6.78 / – / 116 |
| 80 | 60.9 / 12.75 / 87 / 0 | 49.2 / 11.96 / 72 / 0 | 62.5 / 15.07 / 96 / 0 | 119.1 / 6.56 / – / 112 |
| 85 | 59.6 / 12.11 / 83 / 0 | 46.3 / 10.77 / 63 / 0 | 57.1 / 12.65 / 84 / 0 | 120.0 / 6.67 / – / 113 |
| 90 | 61.3 / 11.52 / 80 / 0 | 47.1 / 11.51 / 68 / 0 | 62.4 / 11.57 / 81 / 0 | 119.9 / 6.84 / – / 112 |

**Reading:**

- **GPU ms does not stay near 7 past King's Pass with the flags.** It doubles in the first King's
  Pass bucket, as in the control. The doubling comes one bucket earlier than in the cooled reference,
  because both warm runs were already under the budget (769 and about 1400 mW at t = 65). DXMT,
  under no budget, holds 6.6–6.8 ms there.
- **In the King's Pass window GPU ms is equal:** 13.17 with the flags against 13.00 without, and
  13.40 in the cooled reference. CPU mJ/f is equal (3.6 against 3.5).
  - The flagged run has lower FPS (45.7 against 58.5), lower gpu% (72 against 85), more Mi/f
    (82.3 against 75.6) and more wineserver requests a frame. Those point to the CPU side of a
    hotter phone (`serious` from the start, E cores only), not to the GPU.
  - Sys mJ/f (106.6 against 75.7) follows the gauge's 5-s samples. It is not a GPU measurement.
- **In the menu** (t = 15–20, before either budget bit hard) GPU ms is 6.82 / 7.17 with the flags
  against 7.21 / 7.47 without, about 5 % lower. That matches the earlier 0019 run (7.10 → 6.75), is
  within one run's noise, and cannot account for a doubling.
- The pair is not repeated:
  - The prediction H1(a) makes is that the King's Pass doubling disappears. It did not
    disappear, and that does not depend on the start temperature.
  - A cooler change run would raise its FPS, not halve its GPU time.
  - Rule 3 of the plan: no rerun unchanged.

**Not verified:** whether Metal actually compressed the private render targets. Metal reports only
the requested `compressionType`, and no capture was taken with the flags. The memory types show
that the private type existed and that DXVK saw it. That DXVK placed its render targets there
follows from its code (lowest `DEVICE_LOCAL` type), not from a capture.

## Decision (unattended)

- Not kept. The change does not move GPU ms or mJ/f toward DXMT's (7.5 ms, 61 mJ/f).
- `patches/mesa` 0019 and 0020 are removed with their series lines in one commit. They are not kept
  as diagnostics either. A third form of the same idea would make a better test: render targets as
  dedicated private textures, outside any heap, which is DXMT's layout exactly.
- The patches as tested stay in the build area's notes (`agent-notes/vulkan-perf/chunk8-patches/`)
  for that variant.
- The phone keeps IPA `55ca5c34…`. With the flags off it runs as HEAD after the revert, since the
  patches change nothing without the flags. No reinstall was done.

**Next for item 7:**

1. **A King's Pass capture on both backends** (`pp gpu capture` on DXMT and on DXVK, the same
   frame), compared pass by pass. Look for render-pass splits, forced loads and stores, and
   anything else KosmicKrisp adds there (hypothesis H3). The menu capture had none.
2. **Only if the capture shows no structural difference:** attachment images as dedicated
   private textures. This means `prefersDedicatedAllocation` for attachments and
   `newTextureWithDescriptor` on the device, with no heap and no buffer alias. A null result
   there rules out compression (H1) altogether.

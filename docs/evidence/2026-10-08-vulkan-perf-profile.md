# Vulkan performance: native resolution, power, and Metal's texture compression

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 6 and the GPU-time question that item 5 left open. **IPA:**
dev `b024e1f756b9520af7253bd5eed3e7d476908c60c555bd39e56d698722e57b1a` (commit `80d48bf`)
for the comparison runs. **Status:** in progress. The native/free runs are taken, and
`patches/mesa` 0019 is built for its one run. The rest of this record follows the runs.

## Native resolution, free-running (the comparison mode from now on)

Route v2 (a new game, `hk-walk` at `first-frame+80`, 130 s, cooled to `nominal`, on the
charger), `{"screen":"native","frameLimit":0,…}`. The game runs at 2736×1260.

| run | window | FPS | p50 | p99 | ≥25/50/100 | GPU ms | gpu% | Mi/f | CPU% | P% | CPU mW | sys mW | sys mJ/f | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxmt-1` | 15–40 | 118.5 | 8.34 | 8.34 | 8/4/0 | 6.64 | – | 34.4 | 125 | 83 | 698 | 6203 | 52.3 | 11.7 | 2401 |
| `vk-nat-dxvk-1` | 15–40 | 116.8 | 8.34 | 8.34 | 14/8/1 | 7.10 | 88.6 | 42.5 | 125 | 92 | 745 | 6977 | 59.7 | 11.8 | 2857 |
| `vk-nat-dxmt-1` | 85–125 | 108.9 | 8.34 | 20.84 | 9/1/1 | 7.46 | – | 53.1 | 191 | 75 | 900 | 6660 | 61.2 | 12.4 | 2919 |
| `vk-nat-dxvk-1` | 85–125 | 57.7 | 16.67 | 37.51 | 280/8/3 | 13.40 | 86.0 | 76.6 | 232 | 0 | 200 | 5201 | 90.1 | 18.8 | 3332 |
| `vk-nat-dxmt-1` | 110–135 | 91.4 | 8.34 | 25.01 | 26/1/1 | 8.15 | – | 55.1 | 254 | 8 | 289 | 5130 | 56.1 | 13.8 | 2927 |
| `vk-nat-dxvk-1` | 110–135 | 52.1 | 16.67 | 41.68 | 203/7/2 | 16.15 | 91.2 | 76.6 | 224 | 0 | 182 | 4567 | 87.7 | 20.2 | 3375 |

(`vk-nat-dxmt-1`'s `dvt graphics` sampler returned nothing, so its gpu% is missing.)

- Both reach the 120-Hz ceiling while the phone is cool. DXVK's GPU time is 7 % higher, and
  the phone draws 12 % more for the same frames.
- The thermal pressure reached level 10 at t ≈ 70 s on DXVK and t ≈ 105 s on DXMT. From then
  on both run with the P cores parked. DXMT keeps 91–109 FPS with 7.5–8.2 ms of GPU time.
  DXVK falls to 52–58 FPS, because its GPU time a frame doubles to 13–16 ms with the GPU
  86–91 % busy. The same work taking twice the time points to a GPU clock held down by
  the power budget (no tool here reads the GPU clock), and DXVK's frame then costs 88–90 mJ against DXMT's 56–61.
- **This is not `patches/mesa` 0018.** At 720/free the phone's energy a frame was 53.4 mJ
  before 0018 (`vk-v2-dxvk-notiler-1`) and 53.6 after (`vk-v2-dxvk-p99-2`), against DXMT's
  41.3 ([p99](2026-10-08-vulkan-perf-p99.md)). The Vulkan route has drawn 30 % more a frame
  all along, and CPU power explains only about 200 mW of the 1.5 W. GPU ms at 720 rose with
  0018 because the GPU now always has a frame queued; at native, where the GPU is the limit,
  what counts is the energy a frame.

## The lead: Metal usage flags that turn compression off

The step-0 captures (`gpu-runs/vk-kk-cap1`, `gpu-runs/vk-dxmt-cap1`) list each texture's
Metal usage. DXMT's 1564×720 RGBA8 render target is `0x5` (shader read, render target).
KosmicKrisp creates the same render target, and every DXVK texture, as `0x17`: shader read,
**shader write**, render target, **pixel format view**. Metal does not compress a texture
losslessly when it has either of the two extra usages, so every render target pass on
the Vulkan route reads and writes uncompressed memory.

- `kk_image_layout.c` sets shader write for `VK_IMAGE_USAGE_TRANSFER_DST_BIT`, and DXVK gives
  every texture that usage. KosmicKrisp writes into an image with Metal copies (on its
  compute encoder) and render passes (clears, `vk_meta` blits and resolves), never from a
  shader, so only storage images need it.
- It sets pixel format view for `VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT`. DXVK marks its typed
  colour textures mutable with a format list of the format and its sRGB twin
  (`dxgi_format.cpp`'s families: `R8G8B8A8_UNORM` → {UNORM, SRGB}), and Metal views a
  texture in its sRGB or linear twin without that usage.

`patches/mesa` 0019 sets shader write only for storage images, and leaves pixel format view
out when the image's format list names only sRGB or linear twins of its format. Images
without a format list (vkd3d-proton's typeless resources keep their wider lists), those with
block-texel view compatibility, and `Z32_FLOAT_S8X24` keep it.

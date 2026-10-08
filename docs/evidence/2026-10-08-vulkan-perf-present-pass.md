# Vulkan performance: the extra present pass (work-queue item 4), no change made

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 4. **Result:** no change, so no build, no install and no phone
run. The extra pass cannot be removed safely in KosmicKrisp or the Metal WSI, and the safe
changes that are left touch too little work for one run to show. Nothing is reverted. The
installed IPA is still dev `4349d6a2…` (decision 0066). Next: item 5.

**Read:** Mesa at the pin plus `patches/mesa` 0001–0017, in the patched tree
(`run/mesa/mesa`): `src/vulkan/wsi/wsi_common_metal.c`, `wsi_common_metal_layer.m`,
`wsi_common.c` (swap chain init, `wsi_common_queue_present`),
`src/kosmickrisp/vulkan/kk_wsi.c`, `kk_cmd_meta.c`, `kk_image_view.c`, `kk_queue.c`,
`kk_query_pool.c`, `kk_event.c`. DXVK at its pin plus `patches/dxvk` 0001
(`d3d11_swapchain.cpp` `PresentImage`, `dxvk_swapchain_blitter.cpp`) and vkd3d-proton
(`libs/vkd3d/swapchain.c`). **Capture:** the step-0 KosmicKrisp one-frame capture
`$PLAYPORT_BUILD/gpu-runs/vk-kk-cap1` (frame 600, main menu, DXVK; the
[tooling record](2026-10-06-vulkan-perf-tooling.md#03-gpu-capture-on-kosmickrisp)), read
again with `pp gpu read … --calls`. No later patch touches the WSI, `kk_wsi.c` or
`kk_queue.c` (0017 adds only the capture), so the capture still shows the present path.
No new capture was taken.

## What the passes at present are

The capture's command buffers after the game's scene pass and second pass:

| # | command buffer | what | whose |
|---|---|---|---|
| 2 | the game's, at the end | compute encoder, `dispatchThreads [1,1,1] [1,1,1]`, one address bound, barriers around it | KosmicKrisp's `libkk_write_u32` (`kk_cmd_write`): the immediate write a `vkCmdSetEvent2` or a query's availability makes outside a render pass. It is the game's frame work (a D3D11 event or query, once a frame), one GPU thread. Not a present pass |
| 3 | DXVK's present submit | render pass to the 1564×720 swap-chain `VkImage`, `drawPrimitives` 3 vertices | DXVK's `DxvkSwapchainBlitter::performDraw` (`cmdDraw(3, 1, 0, 0)`): the D3D11 back buffer drawn onto the Vulkan swap-chain image, recorded on `dxvk-cs` from `D3D11SwapChain::PresentImage` |
| 4 | the WSI's blit submit | debug group `meta:vkCmdBlitImage2`, render pass to the BGRA8 drawable, `drawPrimitives` 6 vertices, then `signalDrawable` | the Metal WSI: `wsi_cmd_blit_image_to_image` copies the swap-chain image to `blit.image`, which `kk_bind_drawable_to_vkimage` rebinds to the `CAMetalDrawable`'s texture at every acquire. The copy is `kk_CmdBlitImage2` → `vk_meta_blit_image2`, a sampled draw |

DXMT's frame has one pass after the game's: its present quad, drawn straight to the drawable.
So the Vulkan route has exactly one more full-screen pass, the WSI's copy (4.5 MB read and
4.5 MB written at 1564×720 BGRA8). The compute dispatch is not part of the present: it is
one GPU thread.

## Why the pass stays

1. **DXVK's pass cannot go.** DXVK always draws its back buffer onto the swap-chain image
   (`performDraw`, a 3-vertex draw, with or without scaling: `needsBlit` only changes the
   fragment shader), because the D3D11 back buffer is DXVK's own image and the HUD, cursor
   and colour space go in that draw. vkd3d-proton does the same
   (`dxgi_vk_swap_chain_record_render_pass`, `vkCmdDraw(3, 1, 0, 0)`). Removing it would
   need a DXVK and a vkd3d-proton patch that render the game straight into the swap-chain
   image, a step-9 change outside this item.
2. **Rendering straight into the drawable (no WSI blit) is not safe in KosmicKrisp.** A
   `CAMetalDrawable`'s texture is known only after `nextDrawable`, and changes with every
   acquire. KosmicKrisp fixes the Metal texture of an image view when the view is created
   (`kk_image_view.c`: `mtl_handle_render`, `mtl_handle_sampled`, `mtl_handle_storage` are
   views of `image->planes[0].mtl_handle`), and encodes Metal commands when the Vulkan
   command is recorded (`kk_cmd_draw.c` takes `iview->planes[0].mtl_handle_render` at
   begin rendering). DXVK creates its swap-chain image views once and caches them
   (`GetBackBufferView`, `DxvkImage::createView`). To alias the swap-chain image to the
   drawable, KosmicKrisp would have to re-create every view of that image at each acquire,
   and any application that records a command buffer for a swap-chain image before it
   acquires that image (allowed by Vulkan, and common in native Vulkan games) would draw
   into an old drawable. That is why the WSI blits into a separate `blit.image` that only
   the WSI's own command buffer uses. It would be a redesign of the Metal WSI's image
   model, not a narrow patch.
3. **A cheaper copy is not available.** The drawable is `framebufferOnly`
   (`wsi_metal_layer_configure`: `framebuffer_only = !wsi_device->sw`), so a blit-encoder
   `copyFromTexture` into it is not allowed. Turning `framebufferOnly` off costs the
   drawable its render-only optimisations and moves the same 9 MB. The meta blit already
   loads nothing (load action don't-care, `x` in the capture), samples with `NEAREST` and
   stores once: as cheap as a full-screen copy gets.
4. **The GPU time it costs is not a gap.** The WSI copy is one 1564×720 copy, an estimated
   0.1–0.15 ms of the 5.80 ms frame. With it, Vulkan's GPU time is already 6 % below
   DXMT's (DXVK 5.80, vkd3d 5.86, DXMT 6.19 ms). The exit criteria ask for GPU ms ≤ DXMT
   + 5 %, which both routes meet already. The gaps that remain are p99, work a frame and
   CPU power.

## The safe CPU changes that are left, and why they were not run

- **One submit instead of two at present.** `kk_get_blit_queue` returns the device's only
  queue, so `wsi_common_queue_present` treats the blit as a separate-queue blit: an empty
  submit that waits for the app's semaphores and signals a blit semaphore, then a second
  submit that waits for it and runs the blit command buffer. The capture shows the pair
  (`waitForEvent`/`signalEvent` on one event, value 201, then `waitForEvent` on another,
  and a residency commit for each). Without `get_blit_queue` (KosmicKrisp has one queue
  family with one queue), the blit would go in the first submit. That saves one
  `vkQueueSubmit` and one semaphore round trip a frame on the thread that presents
  (`dxvk-submit`). In the CPU profile `vk-prof-dxvk3`, `dxvk-submit` is 1.6 % of all
  samples, 0.5 of them kernel waits, and no WSI or KosmicKrisp function on it reaches the
  table's 0.1 % rows. One burst run could not show the saving (rule 3).
- **The WSI blit's recording at acquire.** `wsi_metal_swapchain_acquire_next_image`
  re-records the blit every frame, on the thread that calls `vkAcquireNextImageKHR` (for
  DXVK, the game's thread that calls `Present`, inside `PresentImage`; in Hollow Knight that
  is Unity's render thread, `UnityGfxDeviceWorker`). That is one free
  and one allocate of a command buffer, two meta image views (Metal texture views), a
  render pass and a draw. In `vk-prof-dxvk3`, KosmicKrisp does not appear among
  `UnityGfxDeviceWorker`'s modules (the table lists modules from 0.2 % of all samples),
  so this too is below what one run resolves.

Both belong with the plan's per-submit work (step 4.3), which item 6's `--cpu-prof` run
looks at. If that profile shows them, they go together into one `patches/mesa` change.

## Decisions (unattended)

- No code change and no phone run for item 4. The task's own fallback applies: nothing
  safe removes the pass, and the safe CPU trims are below one run's resolution. A run of
  a predicted no-change would only be reverted (rules 3 and 4).
- No new capture: the step-0 capture names every pass, and no patch since changes the
  present path.

## Games observed

None: no phone work in this item.

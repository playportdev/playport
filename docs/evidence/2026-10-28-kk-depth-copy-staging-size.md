# The Witcher 3's per-frame buffer copy is depth to colour; exact staging size breaks GPU captures (PLA-463)

**Linear:** [PLA-463](https://linear.app/playportdev/issue/PLA-463) (under
[PLA-455](https://linear.app/playportdev/issue/PLA-455)).
**Question:** which `vkCmdCopyImage2` makes KosmicKrisp stage 5.95 MiB through a buffer every frame
([trace breakdown § 3](2026-10-28-witcher3-trace-breakdown.md#3-kosmickrisps-command-buffer-heaps)),
and can a texture view make it one blit?
**Result:**
- **Not a format reinterpretation.** The copy reads the **depth aspect** of The Witcher 3's 1300x600
  `D32_SFLOAT_S8_UINT` target into a 1300x600 `R32_SFLOAT` image. Metal has no colour view of a depth
  texture, so the proposed texture view cannot apply. Depth/stencil-to-colour copies stay on the buffer
  path.
- **The buffer is twice what the copy uses.** `kk_CmdCopyImage2` sizes it from the plane's 8-byte
  format (6,240,000 B), but `copy_through_buffer` writes the depth alone, 4 bytes a texel (3,120,000 B).
- **The fix was tried and dropped.** Mesa patch 0129 sized the buffer by the copied aspect. Metal's API
  validation accepted it. Every W3 GPU capture with the patch failed at the capture's end (3 of 3); the
  same capture without it completed (2 of 2). [PLA-464](https://linear.app/playportdev/issue/PLA-464)'s
  pooling already removed the per-frame heap, so the patch would only have saved 4 MiB of one retained BO.
  It was reverted.

## 1. The copy, from the capture

`tools/gputrace.py --calls` and `--json` on `.work/perf/w3-capture/kk-frame3600-*.gputrace` (the PLA-455
capture, before PLA-464) show the frame's only texture↔buffer copies of a full surface:

```
copyFromTexture … 0x7230b44c80 0 0 [0,0,0] [1300,600,1] toBuffer 0x7004135980 0 bytesPerRow=5200 0 options=1
copyFromBuffer 0x7004135980 0 5200 0 [1300,600,1] toTexture 0x700d601680 0 0 [0,0,0] 0
```

- Texture `0x7230b44c80` is `D32FS8` 1300x600, the main depth/stencil target of the frame's render passes.
- Texture `0x700d601680` is `R32F` 1300x600.
- `options=1` is `MTLBlitOptionDepthFromDepthStencil`, and 5200-byte rows are 4 bytes a texel.
- The buffer was allocated as `MTLHeap newBufferWithLength 6240000`, 8 bytes a texel.

A same-format copy would have been a texture-to-texture blit. vkd3d-proton has to copy D3D12's typeless
depth into a colour resource, so this copy is depth→colour.

## 2. Patch 0129 (reverted)

The patch took the copied aspect's format (depth-only or `S8_UINT`) in one helper, used by both the sizing
and the copy. Host checks, all passed:

- `build/mesa-host-test/kk-cmd-pool-test.c` recorded a depth copy and a stencil copy from a 1300x600
  `D32_SFLOAT_S8_UINT` image into colour on the mock driver. It checked the staging BO's class: 4 MiB and
  1 MiB with the patch, 8 MiB without it (red before, green after).
- The full mock-driver host suite (`build/mesa-host-test/run.sh`), `./pp test` and `./pp build`: dev IPA
  `22e72489e8b00bf393b383ace899c3382074fa651d85f965432dabb545eaa679`, 90 checks passed.

## 3. Phone runs

iPhone18,4, iOS 27.0.1, 80 % charge on external power. The app was upgraded in place.

| Run | IPA | Result |
| --- | --- | --- |
| `.work/ui-runs/pla463-hk` | `22e72489` | HK (default backend) first frame +9.98 s, first-frame+10 reached, title menu |
| `.work/ui-runs/pla463-hk-vulkan` | `22e72489` | HK on Vulkan (KosmicKrisp) first frame +9.78 s, first-frame+10 reached |
| `.work/perf/pla463-w3-capture` | `22e72489` | capture at frame 3600; SEGV, null read inside GPUToolsCapture in `vkQueuePresentKHR`, game exit 3; bundle without `index`/`capture` |
| `.work/perf/pla463-w3-capture2` | `22e72489` | the same, same pc offset (`…d9cc`) |
| `.work/perf/pla463-w3-capture-base464` | `51de9407` (PLA-464, no 0129) | capture ended, bundle complete, play to first-frame+150 |
| `.work/perf/pla463-w3-capture3` | `22e72489` | no crash; no frame after 3600 and no `capture ended` until the play stopped; bundle incomplete |
| `.work/perf/pla463-w3-capture-base464b` | `51de9407` | capture ended, play to first-frame+150 |
| `.work/perf/pla463-w3-validate` | `22e72489` | Metal API validation, 100 s of Kaer Morhen walking: no copy or buffer message (only redundant-state and residency messages already seen) |

Every capture used `pp gpu capture --frame 3600 --title app-292030 --secs 150 --pad
first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk --expect-gb 4`. The faulting pc is
in the same image as `GPUToolsCapture`'s `EncodeIncludedSources` (`0x17a3da2c0`), not in KosmicKrisp.

The likely explanation, unproven: the capture layer sizes the `DepthFromDepthStencil` copy from the
texture's 8-byte format, so it reads past the end of a buffer sized for 4 bytes a texel. The 8 MiB BO
hid that. A capture cannot show the staging buffer's size after PLA-464: the pooled BO is created before
the captured frame.

## 4. Outcome

- Patch 0129 and its host test are reverted. The phone runs the rebuilt series again (dev IPA
  `c93828013af67468a32db5cae12146a18e22ae82a98e38b5167bb8b118251486`, 90 checks passed).
- The copy still costs two blits through a 3 MB staging region a frame, in a pooled BO (PLA-464). A
  depth→colour copy without a buffer would need a shader copy (`vk_meta_copy_image` sampling depth, writing
  R32F). It was not pursued: it adds a pass per copy, and W3 is CPU-bound
  ([trace breakdown § 1](2026-10-28-witcher3-trace-breakdown.md#1-where-the-cpu-goes)).
- **Constraint for later changes:** a depth-from-depth/stencil staging buffer smaller than the full
  format's size breaks W3 GPU captures. No code does that after the revert, so no issue was filed; a
  future change to this sizing has to keep W3 capturable.

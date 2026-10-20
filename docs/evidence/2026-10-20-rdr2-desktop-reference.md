# RDR2's stretched 3D: the desktop reference (2026-10-20)

PLA-364. On the phone the gameplay 3D looks stretched or zoomed while the HUD is right. This is the same scene on this
workstation, at the phone's settings, with RenderDoc captures, to tell the phone's `pp gpu capture` what a correct
frame looks like. Host only: nothing here ran on the phone.

## Setup

- Red Dead Redemption 2 (Steam 1174180) under Proton Experimental, RADV on an RX 9070 (Mesa 26.2.4), the Vulkan
  renderer, in the scratch prefix of [the Vulkan runs](2026-10-17-rdr2-vulkan-needs.md#setup), on the agent's sway
  display, with the Steam client already running.
- The phone's `system.xml` (windowed 1280×720, low, Resolution Scale 1/2; and the same at 1/1). As pulled it has
  `configSource Auto`, `locked false` and no `videoCardDescription`, and on this GPU the game re-detected and rewrote
  it (1920×1080, higher presets). The runs used it with `locked true` and this GPU's description, and the game kept
  it. The window was floated in sway at a 1280×720 client area.
- Story mode only: the landing page, Enter, and the latest save loaded into the cabin the phone's runs show (Arthur
  sitting on the bed, a doorway, a window). No movement, no save written.
- **RenderDoc** (1.46) with its layer in every process breaks the launcher: DXVK's d3d11 device fails under it, the
  launcher crashes, and PlayRDR2 says "Unable to launch game". An `LD_PRELOAD` shim that answers
  `ENABLE_VULKAN_RENDERDOC_CAPTURE=1` only in the process whose command line names `RDR2.exe` loads it there alone,
  and RDR2 runs. The capture was triggered through RenderDoc's target control (`qrenderdoc --python`). Keys sent with
  `SendInput` inside the prefix do not trigger it, because RenderDoc reads its hotkeys from X11.
- Scripts, screenshots, captures and the full report stay in the build area (`$PLAYPORT_BUILD/gpu-reference/rdr2/`,
  `REPORT.md`). The game's frames are not ours to publish.

## The correct frame

The same at 1/2 and 1/1, apart from the target sizes. Viewports are y-flipped (negative height); "unbounded" is a
16383×16383 scissor.

| stage | 1/2 | 1/1 |
| --- | --- | --- |
| G-buffer (16 passes, ~890 draws) | 4 colour targets 640×360 (R8G8B8A8 sRGB + 3 UNORM), depth 640×360 D32S8, viewport 0,360 640×-360 | 1280×720, viewport 0,720 1280×-720 |
| lighting, forward, volumetrics | 640×360 (RGBA16F and others) | 1280×720 |
| tonemapped image | 640×360 R11G11B10_FLOAT | 1280×720 R11G11B10_FLOAT |
| final pass | 1 draw into the 1280×720 B8G8R8A8 swapchain, viewport 0,720 1280×-720, sampling the 640×360 image | the same, sampling the 1280×720 image |
| view-projection in the G-buffer draws' uniform data | P00 1.1486, P11 2.0420: aspect **1.7778**, vertical FOV 52.2° | the same |

The 1/1 and 1/2 desktop frames show the scene identically (template match: scale 1.00, offset 0). Resolution Scale
changes target sizes only, not the framing or the projection.

The projection was read from the view-projection matrix VP = P·V. Since V is rigid, the xyz parts of VP's rows 0, 1
and 3 are orthogonal, |row 3| = 1, |row 0| = P00 and |row 1| = P11. So |row 1| / |row 0| is the aspect the game
projected with.

## The phone against it

The phone's 1/2 runs (`20261020T105836-rdr2-s1`, `T112521-rdr2-s2`, IPA `a076ca19`, aspect setting 16:9) show the
same scene from the same camera. Fitting the desktop frame to the phone's 16:9 area by edge-map template matching
over separate x and y scales gives:

- **x ×3.50 (±0.03), y ×1.00 (±0.01)**, the same for three phone shots;
- the phone frame shows the desktop's x 459–825 of 1280, centred at 641, and its full height.

So the phone's 3D is stretched horizontally by about 3.5, about the image centre, with the vertical field of view
unchanged. That is what a wrong P00 alone does. It is not a crop of a corner, it is not a uniform zoom, and it is not
2.17/1.78 = 1.22. The implied P00 is about 4.02 with P11 at 2.042, so the game projected with an aspect of about
**0.507** (0.503–0.510) instead of 1.778. Exactly 0.5 would stretch x by 3.56, 1.5 % above the fit; 720/1280 would
give 3.16 and 737/1600 3.86. The HUD is right, and so is the landing page's panorama strip.

**This supports the hypothesis that the camera's aspect input is wrong.** The Resolution Scale upscale is ruled out:
on the desktop it is one full-viewport draw from 640×360 to 1280×720 and cannot give a centred, x-only ×3.5.
Presentation is ruled out too: it would stretch the HUD as well. Which input gives about 0.5 is not known. The
Resolution Scale reaching the camera on the phone (640/1280) is one candidate, and a phone run at 1/1 decides it. A
phone `pp gpu capture` should show the targets and viewports above with P00 ≈ 4.0. If instead the G-buffer
viewport is about 3.5 times too wide, the fault is in the viewport.

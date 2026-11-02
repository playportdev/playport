# 0088: OpenGL window surfaces, pacing and limits

**Status:** accepted for x86-64, 2026-10-11, carrying out the OpenGL plan's chunk 2
([the plan](https://linear.app/playportdev/issue/PLA-162)); the choices are the worker's conservative ones
(owner away). [PLA-162](https://linear.app/playportdev/issue/PLA-162),
[PLA-180](https://linear.app/playportdev/issue/PLA-180),
[PLA-179](https://linear.app/playportdev/issue/PLA-179),
[PLA-181](https://linear.app/playportdev/issue/PLA-181). Amends
[0087](0087-opengl-through-zink-on-the-host.md): a window's surface is no longer made at its first
`SwapBuffers`, and a second GL window may take the layer.
[Evidence](../evidence/2026-10-11-opengl-wgl-completeness.md).
Amended by [0093](0093-opengl-border-colours-and-fans-on-kosmickrisp.md): Zink gets custom border colours by
default, DXVK and vkd3d-proton still do not.
Amended by [0097](0097-display-mode-emulation.md): a display mode change is emulated on the virtual
monitor.

## Context

0087 made a window's EGL surface at its first `SwapBuffers`, so that the dummy windows games make to
query pixel formats would not hold the game layer. That lost everything drawn before the first swap,
and a dummy that did swap kept the layer: EGL allows one window surface per native window, so the
real window then failed with `EGL_BAD_ALLOC`. Every window of a game shares the game layer (desktop
mode aside). The frame limit, mode changes, custom border colours and caches had not been settled
for GL.

## Decision

- **A window's surface is made at its first make-current** (`patches/madeira-unix` 0115). The layer
  has one presenting drawable:
  - at make-current a window takes the layer if it is free, held by a drawable that has never
    presented, or held by a hidden window while this one is visible (the dummy, even one that
    swapped);
  - a window that swaps without a surface takes the layer from whichever drawable holds it, as a
    Vulkan swap chain made later on the layer replaces the earlier one;
  - the window that lost it draws to no surface until it swaps again, so a loader thread's context
    on a hidden window never takes the layer from the window that presents.
- **No EGL display means no OpenGL** (`patches/wine-unix` 0028): win32u uses its null OpenGL driver,
  and `wglCreateContext` fails as on a system without GL.
- **sRGB windows** get an sRGB EGL surface (`patches/mesa` 0028).
- **The frame limit is the game layer's**, as for DXVK and DXMT: Zink presents through
  KosmicKrisp's swap chain, whose drawables `PacedMetalLayer` paces. There is no GL-specific limit.
  `wglSwapIntervalEXT` 0 or 1 changes nothing visible on iOS: the layer presents at the display's
  rate, and the player's limit holds either way.
- **Mode changes are not emulated** (`EmulateModeset` stays off): `ChangeDisplaySettings` succeeds
  without changing the screen, and a window of the mode's size has a swap chain of that size, which
  the layer aspect-fits, as DXVK's.
- **Custom border colours stay off by default.** KosmicKrisp has them only as an experimental
  feature. Turning it on for every launch would change every Vulkan title too, and it cannot be
  turned on for GL alone: win32u lists the Vulkan GPUs through KosmicKrisp in every process before
  any GL call, and KosmicKrisp reads its flags once. A dev build's per-game Graphics option
  `MESA_KK_EXPERIMENTAL=custom_border` (decision 0060) turns it on, and the probe then reads the
  right `GL_CLAMP_TO_BORDER` colour; a title that needs it in the release app needs a later decision.
- **Zink keeps no disk cache** (0087 unchanged). KosmicKrisp's pipeline cache serves Zink's shaders
  across launches, without stale pipelines in the probe's checks.

## Limits

- The in-game menu's screenshot finds no frame for GL, nor for DXVK: KosmicKrisp's drawables are
  framebuffer-only, unlike DXMT's. Not changed here.
- A multisampled context made current to a new surface after its window lost the layer crashes in
  Zink at its next swap. Single-sample windows do not.
- Two GL windows presenting at the same time take the layer from each other at every swap, and each
  loses what it drew before its swap. Neither the probe nor any title does this.

## Consequences

- A game's first frame draws: the probe reads its first frame back before any swap with no GL error.
  The dummy-window pattern works, whether or not the dummy swaps. Neverwinter Nights: Enhanced
  Edition reaches gameplay at about 50 fps.
- Pixel formats with depth and stencil, sRGB and 4x MSAA, pbuffers, shared contexts, resize, swap
  interval and background/foreground work on x86-64.

# OpenGL through Zink on the host: the route on x86-64 (OpenGL chunk 1b)

**Date:** 2026-10-11. **Kind:** phone runs (dev app) and a desktop-Wine check of the probe.
**Linear:** [PLA-162](https://linear.app/playportdev/issue/PLA-162);
plan [2026-10-11-opengl-zink](https://linear.app/playportdev/issue/PLA-162), chunk 1b;
[decision 0087](../decisions/0087-opengl-through-zink-on-the-host.md).
**Build:** `patches/mesa` 0001–0027, `patches/madeira-unix` 0001–0114 (0114 is this chunk's Wine
side), the frameworks of [chunk 1a](2026-10-11-mesa-gl-ios-build.md).
**IPA:** `Playport-26.5-78bd08ad.ipa` (dev), sha256
`78bd08ada2838e6f63d7c697587babd172d2d09193db039bfafefb1d48feedc0`, installed in place; all
three runs below in one `pp phone lock` session. Run directories under `$PLAYPORT_BUILD/ui-runs/`.

## The probe

`tools/compat/probes/gl21.c`, built by `tools/compat/probes/build.sh` with llvm-mingw for x86-64
into `$PLAYPORT_BUILD/compat/probes/gl21/gl21.exe`: a screen-sized `WS_POPUP` window,
`ChoosePixelFormat`/`SetPixelFormat` (double-buffered RGBA 32, depth 24, stencil 8),
`wglCreateContext`/`wglMakeCurrent`, `GL_VERSION`/`GL_RENDERER`/`GL_VENDOR`/
`GL_SHADING_LANGUAGE_VERSION`/`GL_EXTENSIONS` through `OutputDebugString`, then for 20 s each
frame: clear to dark teal, a fixed-function `glBegin`/`glEnd` triangle with red, green and blue
corners on the left, a GLSL 1.20 program's solid yellow triangle on the right, `SwapBuffers`;
it logs the frame count and exits 0. Under desktop Wine (xvfb, llvmpipe) it logs GL 4.6
compatibility and exits 0 after 3 s.

It was put into the container's `Documents/Import/gl21` (a scratch AFC copy, as for the
GDI-windows reproducer) and added through the UI: `pp ui --action import:Import/gl21` (the Local
title `dir-gl21`).

## Results

- **`dir-gl21`** (`20261011T143813`): `--until first-frame+10` ok; `first frame` +3.33 s (runtime
  +2.93 s, game +3.20 s). The log:
  - `[unixlib] module … (opengl32.dll) -> opengl32_unix_call_funcs`
  - `[winios] opengl: EGL backend ready`
  - `gl21: pixel format 107: flags 0x802d, colour 32, depth 24, stencil 8`
  - `gl21: GL_VERSION 3.3 (Compatibility Profile) Mesa 26.3.0-devel (git-0941025971)`
  - `gl21: GL_RENDERER zink Vulkan 1.4(Apple A19 Pro GPU (MESA_KOSMICKRISP))`,
    `GL_VENDOR Mesa`, `GL_SHADING_LANGUAGE_VERSION 3.30`, `GL_EXTENSIONS` 7,514 characters
  - `[winios] opengl: zink Vulkan 1.4(Apple A19 Pro GPU (MESA_KOSMICKRISP)) (Mesa), core 3.3, compat 3.3`
    (win32u's probe of the core and compatibility versions)
  - `[winios] opengl: window surface for hwnd 0x1002c layer … 1564x720 -> … (error 0)`
  - `gl21: done: 1201 frames in 20.0 s, 60.0 fps`; `title: done … exit=0x00000000 after_s=20`
  - Zink's warning `the selected Vulkan device (Apple A19 Pro GPU) doesn't support base Zink
    requirements: have_EXT_custom_border_color` (KosmicKrisp has it only behind
    `KK_EXPERIMENTAL`).
  - `gl21: first frame drawn (glGetError 0x506)`: the window's EGL surface is made at its first
    `SwapBuffers` (decision 0087), so the first frame drew to no surface
    (`GL_INVALID_FRAMEBUFFER_OPERATION`) and is lost; every later frame drew.

  The screenshot (`screen-stop.png`, not published): the teal clear filling the screen, the
  left triangle shaded from red (bottom left) through green (bottom right) to blue (top), and
  the solid yellow right triangle, both the expected size and place (the probe's window and
  the swap chain are the virtual screen's 1564×720, scaled to the layer).
- **Hollow Knight (`app-367520`, DXMT)** (`20261011T143856`): `--until first-frame+10` ok,
  `first frame` +10.33 s, the main menu on the screenshot. Its log has no EGL, Mesa or Zink
  line: the game loads `opengl32.dll`, which now gets `opengl32_unix_call_funcs`, but makes no
  GL call on a DC, so win32u never loads Mesa's EGL.
- **Portal 2 (`app-620`, i386, DXVK)** (`20261011T143946`): `--until first-frame+10` ok,
  `first frame` +6.02 s, the "powered by Source" intro on the screenshot. No EGL, Mesa or Zink
  line (an i386 child keeps opengl32's GL-absent table).

## What it took

- **`patches/madeira-unix` 0114** (win32u, ntdll-unix): `SONAME_LIBEGL` is
  `@rpath/MesaEGL.framework/MesaEGL` (no more `-USONAME_LIBEGL`); `winios_OpenGLInit` keeps
  win32u's EGL backend (surfaceless display, `EGL_NO_CONFIG_KHR` contexts, pbuffers) and gives a
  window an EGL window surface on the `CAMetalLayer` from `macdrv_view_create_metal_view`, made
  at the first swap, with the layer's `drawableSize` set to the window's size; opengl32's unix
  side is compiled into `libntdll_unix.a` and handed to an x86-64 `opengl32.dll`, an i386 one
  keeps the GL-absent table; `sysparams_ios.c` does not list OpenGL GPUs (that would load Mesa
  and start Zink in every process listing its display devices).
- **`patches/mesa` 0027, kk: enumerate no instance layers.** The first phone run failed in
  `eglInitialize` with no Zink message: Zink gives up silently when `vkGetInstanceProcAddr` has
  no `vkEnumerateInstanceLayerProperties`, which a Vulkan loader answers and KosmicKrisp never
  had. Found with a temporary instrumented build (Zink's failure lines logged), not shipped.
- **Sizing (0023, 0024 revised before this run):** kopper sizes a Metal swap chain from the
  drawable size the loader gives, as on Wayland, and Mesa's surfaceless platform takes it from
  the layer's `drawableSize` (bounds × `contentsScale` before it has one). The first design,
  the surface's current extent as on X11, would have sized the swap chain to the layer's
  bounds × `contentsScale` rather than the window.

Not covered here (chunk 2): a dummy window that swaps, resize, `wglSwapIntervalEXT` 0,
pbuffers, MSAA and sRGB formats, background/foreground, the in-game menu screenshot.

# OpenGL through Zink: WGL completeness on x86-64 (OpenGL chunk 2)

**Date:** 2026-10-11. **Kind:** phone runs (dev app), with a desktop-Wine check of the probe.
**Linear:** [PLA-162](https://linear.app/playportdev/issue/PLA-162) (chunk 2),
[PLA-180](https://linear.app/playportdev/issue/PLA-180), [PLA-179](https://linear.app/playportdev/issue/PLA-179),
[PLA-181](https://linear.app/playportdev/issue/PLA-181);
plan [2026-10-11-opengl-zink](https://linear.app/playportdev/issue/PLA-162);
decisions [0087](../decisions/0087-opengl-through-zink-on-the-host.md) and
[0088](../decisions/0088-opengl-window-surfaces-and-pacing.md).
**Build:** `patches/madeira-unix` 0001–0115, `patches/wine-unix` 0001–0028, `patches/mesa` 0001–0028
(commit 22e2abc). **IPA:** `Playport-26.5-2e27a299.ipa` (dev), sha256
`2e27a299fe031310b9692fa0e027cf493149b4be7a5e6bf6f59d1c10a9529109`, the build of 22e2abc's content,
installed in place. The probe runs under "Probe checks" before the last one were on its predecessor
`d753af1774598eba8ae9f009d13ba298d80f143fee9d1b4c301dca38721b85a3`, the same code (only 0115's
message changed after it). Run directories under `$PLAYPORT_BUILD/ui-runs/`.

## What changed

- **`patches/madeira-unix` 0115 (PLA-180).** A window's EGL surface is made when a context is first
  made current to it, not at its first `SwapBuffers`, so the first frame draws. The game layer has
  one presenting drawable at a time: a window takes it at make-current if it is free, held by a
  drawable that never presented, or held by a hidden window while this one is visible (a dummy
  window, even one that swapped); a window that swaps without a surface takes it from whoever holds
  it. A pixel format EGL refuses a window surface is not retried every frame.
- **`patches/wine-unix` 0028 (PLA-179).** When the EGL display does not initialize, win32u falls
  back to its null OpenGL driver: `wglCreateContext` fails and the game goes on, instead of the
  process crashing in `parse_extensions` on a NULL extension string. Not exercised on the phone
  (nothing a game's options can set makes Mesa's EGL fail); it compiles into the build above.
- **`patches/mesa` 0028.** Surfaceless with kopper adds the driver's sRGB configs to the window
  configs (as Wayland does), so `EGL_GL_COLORSPACE_SRGB` finds one. Before it, an sRGB-capable WGL
  pixel format got `EGL_BAD_MATCH` (0x3009) and no surface (run `20261011T150258`).
- **`tools/compat/probes/wgl.c`** (`build.sh` builds it beside `gl21`): the WGL behaviours games use,
  checked in order with read-backs, each logged `wgl: CHECK <name>: ok|FAIL`. A dummy hidden window
  with its own context that swaps once and stays alive; the game window (`wglChoosePixelFormatARB`
  RGBA8, depth 24, stencil 8; a GL 3.3 compatibility context) reading its colour back before its
  first swap; a stencil mask and a depth test; `wglSwapIntervalEXT` 1 and 0; a pbuffer with a
  context sharing the window context's texture, and `wglShareLists`; a second visible window that
  presents and goes, then the first again; `GL_CLAMP_TO_BORDER`'s colour; the window at half size;
  `ChangeDisplaySettings` to the largest smaller mode with the window that size. `wgl.exe SECONDS
  srgb` or `msaa` gives the game window an sRGB-capable or 4x multisampled format. Under desktop Wine
  (xvfb, llvmpipe) every check passes except sRGB (no such visual), MSAA (the window is not
  multisampled there) and the mode change (one mode). It was put into the imported title's folder
  (`dir-wgl`, `C:\Games\wgl`) with a scratch AFC copy.

## Probe checks

| Run | Settings | Result |
|---|---|---|
| `20261011T164450` (final IPA) | 20 s | every check ok but `border`; first frame +3.2 s; 60.0 fps |
| `20261011T151846` | 20 s | the same; scene 60.0 fps |
| `20261011T152059` | `10 srgb` | `srgb: ok format 243, capable 1, linear 0.5 reads 188` |
| `20261011T151955` | `10 msaa` | `msaa: ok format 148, GL_SAMPLES 4, an edge pixel 128`; then a crash at the hand-back (below) |
| `20261011T152427` | limit Off | interval 1 116.6 fps, interval 0 119.3 fps, scene 119.9 fps |
| `20261011T152523` | limit 30 | interval 1 30.2 fps, interval 0 30.0 fps, scene 30.0 fps |
| `20261011T152614` | `MESA_KK_EXPERIMENTAL=custom_border` | `border: ok GL_CLAMP_TO_BORDER blue reads 0,0,255,255`; Zink's custom-border warning gone; exit 0 |
| `20261011T152724` | menu screenshot | menu opened over the probe; `screenshot: No frame to save` |
| `20261011T152912` | background | backgrounded at +45 s for about 12 s, then foregrounded: 60 fps after, exit as normal |

The final IPA's run logs:

- `[winios] opengl: window surface for hwnd 0x1002c layer … 64x64 -> … (error 0)` (the dummy, at its make-current)
- `wgl: CHECK dummy: ok format 108, swapped once, kept alive`
- `[winios] opengl: hwnd 0x10032 takes layer … from hwnd 0x1002c (presented)`; `window surface for hwnd 0x10032 … 1564x720`
- `wgl: CHECK first-frame: ok before the first swap: glGetError 0, centre reads 0,255,0` (1b's probe saw 0x506 here)
- `wgl: CHECK depth-stencil: ok depth 24 stencil 8, stencil left 255,0,0 right 0,0,0, depth centre 0,0,255`
- `wgl: CHECK interval: ok interval 1 60.3 fps, interval 0 60.0 fps` (the default 60 FPS limit)
- `wgl: CHECK pbuffer: ok format 35 256x256, read 255,0,255`; `share-context: ok`; `share-lists: ok`
- `wgl: CHECK second-window: ok format 137, after its first swap reads 102,26,102`; `hand-back: ok … 0,0,255`
- `wgl: CHECK border: FAIL GL_CLAMP_TO_BORDER blue reads 0,0,0,0` (no custom border colours by default)
- `wgl: CHECK resize: ok client 782x360 (asked 782x360), corner reads 0,255,0`
- `wgl: CHECK modeset: ok ChangeDisplaySettings 800x600 -> 0, window 800x600, screen then 1564x720, corner reads 255,255,0`
- `wgl: done: 1201 frames in 20.0 s, 60.0 fps, 1 failed`; exit 1 (the border check)

What the runs show:

- **Swap interval and the frame limit.** GL presents through KosmicKrisp's swap chain on the game
  layer, so Playport's frame limit (`PacedMetalLayer.nextDrawable`) paces it as it paces DXVK and
  DXMT: 60 and 30 FPS hold whatever the interval; with the limit Off, interval 0 and 1 both reach the
  display's 120 Hz (iOS presents at the display's rate, so interval 0 does not tear or exceed it).
- **Mode changes.** Playport does not emulate mode sets (`EmulateModeset` is off):
  `ChangeDisplaySettings` succeeds and the screen stays 1564×720; a game that fills the mode it set
  has a window, and so a swap chain, of that size, which the layer aspect-fits, as DXVK's.
  Resizing a window resizes its swap chain (the corner pixel of the half-size frame reads back).
- **Background.** The app was sent to the background with the probe drawing (another app launched
  on the phone, then Playport brought back): the GPU gate closed and opened, the task was suspended
  11.5 s, and drawing resumed at 60 fps; the probe finished its 60 s.
- **Mesa caches across launches.** Zink keeps no disk cache (0026). KosmicKrisp's pipeline cache
  serves Zink's shaders across launches: the first probe launch built two Metal pipelines over
  20 ms (179 and 123 ms, `[kk-compile]`), later launches of the same probe built none over 20 ms,
  and their read-backs all passed (no stale pipeline). The custom-border run built three new ones
  (different shader keys).
- **Custom border colours (PLA-181).** With `MESA_KK_EXPERIMENTAL=custom_border` (an allowed
  per-game Graphics option, decision 0060) KosmicKrisp exposes `VK_EXT_custom_border_color`, Zink
  stops warning and the border colour reads back right; every other check still passed. It stays off
  by default (decision 0088).
- **The in-game menu's screenshot does not work for GL**: "No frame to save" over the probe and over
  Neverwinter Nights. It does not work for DXVK either: Portal 2's menu says the same
  (`20261011T163711`). KosmicKrisp's swap chain makes the layer's drawables framebuffer-only
  (`wsi_metal_layer_configure`, unlike DXMT's), which the screenshot's Core Image read most likely
  refuses. Not changed here (it is the Vulkan path's present cost, decided in the Vulkan
  performance work); a follow-up.
- **An MSAA context rebound to a new surface crashes in Zink.** In the `msaa` run the game window's
  4x context, made current again to its window after the second window had held the layer, crashed
  at its next swap in `zink_kopper_acquired` (a use of a destroyed swap chain;
  `begin_rendering` → `zink_batch_rp` → `kopperSwapBuffersWithDamage`). The non-multisampled and
  sRGB runs pass the same steps. A multisampled game that recreates its window could hit it; a
  follow-up.

## Real titles

- **DDNet (Steam 412220) and Teeworlds (Steam 380840)** are not on the test account: `install:412220`
  and `install:380840` end with "no installable Windows depot" (no licence), and Playport's UI cannot
  add a free licence. Their queued entries were cancelled in Downloads.
- **Baldur's Gate: Enhanced Edition (GOG 1207666353; x86-64, OpenGL)** installed and exited at once,
  `0xc0000135`: `Library OpenAL32.dll … not found` (the game ships `oalinst.exe`, which nothing runs).
  Not an OpenGL failure; uninstalled through the UI.
- **Neverwinter Nights: Enhanced Edition (GOG 1097893768; x86-64, OpenGL 3.3)** reaches gameplay.
  - `20261011T154229`: first frame +7.05 s (its intro movie), at its default 1024×768 window
    (aspect-fitted, black at the sides). Two 10×10 dummy windows each got a surface at make-current
    and went, then the game window. Its log has no `err:wgl` or `err:opengl` line.
  - Its `settings.tml` (in the prefix's `Documents\Neverwinter Nights`) was set to
    `graphics.window.mode = "fullscreen"` (its fullscreen size was already the screen's 1564×720)
    and `graphics.movies.intro.enabled = false`; from then the game window is 1564×720.
    `20261011T154444`: the main menu at +45 s (screenshot: the menu over its painted art, full width).
  - A tapped route (New › Official › The Wailing Death › Prelude › Start › Select Premade Character ›
    Play, the campaign's opening movie tapped through) reaches the Prelude: `20261011T160751` shows the
    premade wizard in the Academy's first room in the 3D view, with the chat, quickbar and portrait.
  - **Numbers** (`20261011T162802`, the same route with the Metal HUD on, about 2 min in-game, idle in
    that room; `pp perf --analyze` of the run, frames from the layer's `[frames]` lines, as `pp perf`
    cannot tap through menus): 50.0 fps mean over the in-game window (t = 115–235 s), 53–55 fps in
    the first minute and 44–48 fps in the second, the phone's thermal state `serious` from the start
    (after a long session); CPU 123 % (P 101.5 %, E 21.8 %), 1.10 W CPU; 172 wineserver requests a
    frame. The movies run at 30 fps. The HUD's GPU figures were not parsed from this run.
  - The in-game menu opened over it; its screenshot gave "No frame to save" (above); Quit game closed
    it. Uninstalled through the UI afterwards.

## Direct3D titles on the same IPA

- **Hollow Knight (`app-367520`, DXMT)** (`20261011T163526`): `--until first-frame+10` ok, first
  frame +10.20 s, the main menu on the screenshot. No EGL or Zink line in its log (its one Mesa
  line is KosmicKrisp's shader-cache path, logged at every launch).
- **Portal 2 (`app-620`, i386, DXVK)** (`20261011T163623`): `--until first-frame+10` ok, first frame
  +6.07 s, the "powered by Source" intro on the screenshot. No EGL or Zink line.

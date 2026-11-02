# 0087: OpenGL through Zink on the host

**Status:** accepted for x86-64, 2026-10-11, carrying out the owner's "do Zink"
([the plan](https://linear.app/playportdev/issue/PLA-162), settled 2026-10-11) by the route that plan
recommends; the worker's choices below are the conservative ones (owner away). The i386 route is
open until the plan's chunk 3 gate amends this record.
[PLA-162](https://linear.app/playportdev/issue/PLA-162).
Evidence: [the frameworks](../evidence/2026-10-11-mesa-gl-ios-build.md),
[the route on the phone](../evidence/2026-10-11-opengl-zink-route.md).
Amended by [0088](0088-opengl-window-surfaces-and-pacing.md): a window's surface is made at its
first make-current, and the game layer is handed between windows.
Amended by [0089](0089-opengl-i386-route-gate.md): host-side Zink serves i386 too, through
opengl32's WoW64 thunks converted through the window.
Amended by [0093](0093-opengl-border-colours-and-fans-on-kosmickrisp.md): Zink has custom border colours, and draws
no triangle fans on KosmicKrisp.

## Context

Playport had no OpenGL: the iOS display driver's `OpenGLInit` was the null one, win32u was built
without EGL, and opengl32 got a GL-absent unix table, so a Windows game that draws with WGL
failed. Wine 11.19's win32u already implements WGL on EGL (a surfaceless display, contexts,
pixel formats, pbuffers, framebuffer emulation), and Mesa's Zink runs OpenGL on Vulkan, which
Playport has in KosmicKrisp ([0014](0014-vulkan-through-kosmickrisp.md)).

## Decision

- **Host side.** OpenGL is Mesa's EGL and OpenGL frontend with Zink, built for iOS from the
  KosmicKrisp tree (`build/stages/mesa.sh`, `patches/mesa` 0022–0027), embedded as
  `MesaEGL.framework` and `MesaGallium.framework` beside `KosmicKrisp.framework`. Wine's PE
  `opengl32` and its unix thunks stay as WineHQ ships them; win32u's EGL backend dlopens
  MesaEGL (`patches/madeira-unix` 0114). Zink loads KosmicKrisp by its framework install name;
  no MoltenVK code or header is built in.
- **Presentation.** A window's GL drawable is an EGL window surface on the `CAMetalLayer`
  IOSDisplayShim gives DXMT and Vulkan for it (the game layer, or the window's own in desktop
  mode), presented by Zink's kopper through KosmicKrisp's Metal swap chain, opaque. The swap
  chain is the window's size (the layer's `drawableSize`), scaled to the layer, as DXVK's are.
  The surface is made at the window's first `SwapBuffers`, so the dummy windows and contexts
  games make to query pixel formats never present; that first frame's drawing is lost.
- **Loaded on demand.** Nothing loads MesaEGL until a game calls GL on a DC with a pixel format:
  win32u's display-device listing does not enumerate OpenGL GPUs on iOS. (dyld maps the two
  frameworks at launch, as it maps KosmicKrisp, because the app links them.)
- **x86-64 only for now.** opengl32's unix side serves x86-64 processes. An i386 child keeps the
  GL-absent table until the WoW64 thunks convert guest pointers through the window, with the
  pointer-or-offset cases the plan lists; the plan's chunk 3 measures host-side i386 against a
  guest-side fallback and amends this record.
- **Zink keeps no disk cache on iOS** until reuse across launches is checked on KosmicKrisp;
  KosmicKrisp's own pipeline cache still applies.

## The GL ceiling and limits

- **OpenGL 3.3, core and compatibility** (GLSL 3.30): Zink on KosmicKrisp reports no more because
  KosmicKrisp has no `shaderFloat64`, which GL 4.0 requires. Every OpenGL title reported so far
  needs 3.3 or less. A per-title version override is not offered without evidence.
- **Missing Zink requirements:** `VK_EXT_custom_border_color` (KosmicKrisp has it only behind
  `KK_EXPERIMENTAL`), so `GL_CLAMP_TO_BORDER` colours can be wrong; line rasterization is
  Bresenham only (no wide, smooth or stippled lines natively).
- **One presenter per layer:** a title presenting GL and Direct3D to the game layer at once is
  not supported; nor are two GL windows presenting at once (EGL allows one surface per layer).
- **Persistent buffer maps on i386** will need Zink's placed maps (no opaque-fd export in
  KosmicKrisp); out of scope until chunk 3.

## Consequences

- An x86-64 OpenGL title can draw on the phone: the `gl21` probe (fixed function and GLSL 1.20)
  runs at 60 fps with its first frame at +3.3 s. Wider WGL behaviour (resize, swap interval 0,
  pbuffers, MSAA and sRGB formats, background) is the plan's chunk 2.
- The IPA grows by about 5 MB deflated (about 20 MB in the bundle); Direct3D titles' launches
  are unchanged (Hollow Knight and Portal 2 show no EGL or Zink line).
- wined3d (Wine's Direct3D ≤ 11 on GL) gains a real GL under x86-64; decision 0047's routing is
  unchanged.
- Mesa's EGL, GL and Zink files ship under Mesa's licences (mostly MIT; SGI-B-2.0 and Khronos
  notices), carried by the notices tooling's Mesa component.

# Mesa's EGL and Zink build for iOS (OpenGL chunk 1a)

**Date:** 2026-10-11. **Kind:** workstation build, host test, and a Hollow Knight
smoke run on the phone. Nothing on the phone calls the new libraries yet.
**Linear:** [PLA-162](https://linear.app/playportdev/issue/PLA-162);
plan [2026-10-11-opengl-zink](https://linear.app/playportdev/issue/PLA-162), chunk 1a.
**Tree:** Mesa `b39d173ca9369c19fda2635be6655d308067e52d` (the `mesa` pin) plus
`patches/mesa` 0001–0026, built by `build/stages/mesa.sh`.
**IPA:** `Playport-26.5-7254816c.ipa`, sha256
`7254816cb205c7caece183cb3e469a7e0af3cd68cfb51238847df28335d388ea` (dev).

## Result

- **Mesa's EGL and OpenGL frontend with Zink build for `arm64-apple-ios26.0`**,
  from the KosmicKrisp tree, in a second build directory (`run/mesa/ios-gl`):
  `-Dgallium-drivers=zink -Dvulkan-drivers= -Dopengl=true -Degl=enabled
  -Dplatforms=macos -Dgles1=disabled -Dgles2=disabled -Dglx=disabled
  -Dgbm=disabled -Dglvnd=disabled -Dzstd=disabled -Dllvm=disabled
  -Dexpat=disabled -Dvideo-codecs= -Dvulkan-loader-rpath= -Dunversion-libgallium=true`,
  release. EGL's native platform is surfaceless.
- **Two frameworks:** `libEGL` as `MesaEGL.framework` (961,324 bytes staged)
  linking `libgallium_dri` as `MesaGallium.framework` (19,013,736 bytes staged:
  the OpenGL frontend, GLSL compiler, NIR, Zink). In the IPA they take
  993,326 + 19,275,160 = 20,268,486 bytes (signed bundles). The deflated IPA
  is 403,538,278 bytes, 5,163,170 more than the previous build
  (`20261011-132355-b392cd08`, 398,375,108 bytes).
- **Every import resolves on iOS.** `check-macho-imports.py`: MesaGallium links
  libSystem, libz, libobjc and libc++ (C++ against the SDK's libc++ headers,
  PLA-5); MesaEGL links libSystem, libobjc and MesaGallium, whose exports
  resolve its imports (`--with`, new); MesaEGL exports what win32u's EGL backend
  calls (`eglGetProcAddress`, `eglGetPlatformDisplay`, `eglInitialize`,
  `eglCreateContext`, `eglCreateWindowSurface`, `eglSwapBuffers`). Neither names
  the repository or `$HOME` (`-ffile-prefix-map`, and the empty
  `vulkan-loader-rpath` drops Mesa's default `/usr/local/lib` rpath).
- **No MoltenVK.** The iOS build includes no MoltenVK header (0022); Zink
  dlopens `@rpath/KosmicKrisp.framework/KosmicKrisp`.
- **Host test: Zink accepts KosmicKrisp's device and translates its shaders.**
  `build/stages/mesa.sh .work/run/mesa hosttest` (KosmicKrisp's 24 pipelines,
  as before, then `zink-host-test.c` on the same mock driver) prints
  `GL_RENDERER zink Vulkan 1.4(Mock Apple A19 Pro GPU (MESA_KOSMICKRISP))`,
  `GL_VERSION 3.3 (Compatibility Profile) Mesa 26.3.0-devel`, `GLSL 3.30`, and
  `zink-host-test: ok` after a clear, a fixed-function triangle, a GLSL 1.20
  triangle, a `glBlitFramebuffer` and a `glReadPixels` with no GL error; 25 MSL
  libraries, all translated (debug build, NIR validation on). Zink warns that
  the device lacks `VK_EXT_custom_border_color` (KosmicKrisp has it only behind
  `KK_EXPERIMENTAL`). GL 3.3 is the ceiling the plan predicted: no `shaderFloat64`.
- **The app is unchanged on the phone.** The app links and embeds the two
  frameworks as it does KosmicKrisp (dyld maps them at launch; MesaGallium has
  one static initializer, the GLSL builtins' C++ one); nothing calls them.
  `pp verify`: 86 checks passed, each framework the staged build and signed.
  Hollow Knight (`app-367520`) after `pp install` in the same lock session:
  `--until first-frame+10` ok, first frame at +10.04 s, main menu on the
  screenshot (run `$PLAYPORT_BUILD/ui-runs/20261011T135804`); its log has no
  EGL or Zink line.

## What had to change (`patches/mesa`)

- 0022 **zink: build for iOS without MoltenVK** — no `moltenvk-dir` needed for
  an iOS host; MoltenVK headers and `MVK_VERSION` code left out when
  `TARGET_OS_IPHONE`; `VK_LIBNAME` is KosmicKrisp's framework; `-lobjc`.
- 0023 **zink: kopper presents to Metal surfaces** — `KOPPER_METAL` for
  `VkMetalSurfaceCreateInfoEXT` (`vkCreateMetalSurfaceEXT`, keyed by the layer,
  sized from the surface's current extent like X11/Win32, resize through the
  surface capabilities).
- 0024 **egl: surfaceless window surfaces on a CAMetalLayer** — on Apple with
  Zink/kopper: configs carry `EGL_WINDOW_BIT`, `eglCreateWindowSurface` takes a
  `CAMetalLayer`, swaps present opaque through kopper, swap interval 0–1.
- 0025 **egl: Zink on surfaceless without DRM** — eglInitialize's Zink step runs
  Zink without a DRM device when none has a driver (iOS has none), without
  `LIBGL_ALWAYS_SOFTWARE` (which would make Zink want a CPU device).
- 0026 **zink: no disk cache on iOS** — until reuse across launches is checked
  on KosmicKrisp; KosmicKrisp's own pipeline cache still applies.

Window presentation (0023, 0024) is not exercised by the host test (it has no
`CAMetalLayer`); chunk 1b proves it on the phone.

## Notices

The notice collection adds Mesa's `include/GL`, `include/EGL` and `include/KHR`
headers to its full-header superset (`build/notices-mesa.py`), and
`build/app-notices.json` gives the two frameworks a part (`MesaGL`) covered by
the Mesa component, now "Mesa (KosmicKrisp, Zink, EGL)". Mesa's licence texts
(`licenses/`, including SGI-B-2.0) were already carried whole. This edit has
not had the owner's licensing review.

# Vulkan Direct3D backend: first IPA

**Date:** 2026-09-26. **Kind:** a build. The phone run is recorded separately.
**IPA (dev):** sha256 `5c089de5206b39735f849c393126d26446775bc89b2b3b26a3b8d7f45073e7fc`.
verify-ipa: 62 checks passed, 0 failed.

## What the IPA carries for the Vulkan backend (decision 0014)

- **KosmicKrisp:** `Frameworks/KosmicKrisp.framework`. This is Mesa `82d4f86`
  with `patches/mesa` 0001–0008, built by `build/stages/mesa.sh`. The
  executable links it by `@rpath/KosmicKrisp.framework/KosmicKrisp`, and
  win32u dlopens the same name (`patches/madeira-unix` 0029).
- **Wine's Vulkan:** win32u's Vulkan, with a Metal-surface user driver for
  the window's CAMetalLayer, and winevulkan's unix side, both in
  `libntdll_unix.a` and `libwin32u_unix.a` (0029). The PE
  `vulkan-1.dll` and `winevulkan.dll` are in `Runtime/arm64ec-windows`.
- **Direct3D layers:** DXVK `52fe923` (d3d8, d3d9, d3d10core, d3d11, dxgi)
  and vkd3d-proton `472989a` (d3d12, d3d12core). They are arm64ec, built
  unmodified by `build/stages/vulkan-pe.sh`, marked Wine builtins, and
  shipped in `Runtime/vulkan/arm64ec-windows`, which a launch set to
  Vulkan puts first on `WINEDLLPATH`.

## Not shown by the build

- **Any device run.** The first run on the phone is in its own record.
- **DXMT launches load KosmicKrisp too.** The executable links the
  framework, so dyld maps it at every app start. A DXMT launch makes no
  Vulkan call, so only the mapping costs anything.

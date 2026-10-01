# 0015: The Vulkan backend ships, opt-in beside DXMT

**Status:** accepted, 2026-09-27. Accepts the Vulkan path that
[0014](0014-vulkan-through-kosmickrisp.md) proposed, and supersedes 0014
where it says no IPA carries Vulkan or DXVK. 0014's design (the driver, the
switch, the order) stands. [0003](0003-runtime-backend.md) still holds:
DXMT stays the default Direct3D layer.

## Decision

- Every IPA carries the Vulkan backend, built by the `vulkan` stage of
  `pp build`:
  - KosmicKrisp (Mesa's Vulkan on Metal) at the `mesa` pin plus
    `patches/mesa`, as `KosmicKrisp.framework`;
  - Wine's Vulkan (`winevulkan.dll`, `vulkan-1.dll` and win32u's Vulkan on
    the iOS user driver);
  - DXVK `52fe923` (Direct3D 8 to 11) and vkd3d-proton `472989a`
    (Direct3D 12), both unmodified, for `arm64ec-windows`, under
    `Runtime/vulkan/`.
- It is opt-in: the **Direct3D** picker in Settings or on a game's page
  chooses DXMT or Vulkan, and a game's own choice wins (0014, "The switch").
  DXMT stays the default.
- The Vulkan backend starts with `DXVK_CONFIG=dxvk.numCompilerThreads = 2`
  (PlayportKit `GraphicsBackend.runtimeEnvironment`). A game's own
  variables override it.

## Why

Hollow Knight reaches its menu at 120 fps with the Metal HUD reading
`Direct` on Direct3D 11 through DXVK and on Direct3D 12 through vkd3d-proton,
and gameplay ran on both ([record](../evidence/2026-09-26-vulkan-d3d11-d3d12.md)).
That completes 0014's order: the driver, Wine, DXVK and the device gate.
D3D 8, 9 and 12 titles have no other path here, since DXMT covers D3D 10/11
only.

## What it costs

- **Known gaps.** The Witcher 3 (Direct3D 11 only) stalls after its first
  frame on Vulkan: DXVK fails to change the display mode. Only one title has
  been played through the backend. Longer play and the release variant are
  not shown.
- **The compiler-thread limit works around FEX's host band; it does not fix
  it.** Every guest thread carries FEX state in the 16 GB host band, and a
  Unity title's threads plus DXVK's default compiler pool exhausted it. A
  title with more threads may still run out.
- The IPA grows by the driver and the seven DLLs (`app/artifacts.tsv`), and
  every build needs the Mesa host dependencies 0014 lists.
- Three more upstreams in the notices and the source offer: Mesa (MIT and
  others, per file), DXVK (zlib/libpng) and vkd3d-proton (LGPL-2.1-or-later)
  ([LICENSING.md](../LICENSING.md), [NOTICES.md](../NOTICES.md)).

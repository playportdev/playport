# 0032: vkd3d-proton carries a patch series; Direct3D 12 reports feature level 12_0 and shader model 6.6 on KosmicKrisp

**Status:** accepted, 2026-09-30. Changes [0015](0015-vulkan-backend-accepted.md)
where it says vkd3d-proton ships unmodified (the rest of 0015 stands; DXVK
stays unmodified). The runs are in the
[evidence record](../evidence/2026-09-30-d3d12-feature-level-12.md).

## Decision

- **`patches/vkd3d-proton`**, applied onto the `vkd3d-proton` pin by
  `build/stages/vulkan-pe.sh` like every other series (`ensure_series`), and
  part of the `vulkan` stage's inputs.
- **Feature level 12_0 without sparse binding** (0001). On a driver with no
  sparse binding at all (KosmicKrisp), vkd3d-proton reaches 12_0 without
  tiled resources tier 2. `TiledResourcesTier` itself still reports 0.
- **Shader model 6.6 on KosmicKrisp** (0002). It is exposed without float
  controls, compute shader derivatives or 64-bit buffer atomics, which Metal
  does not offer. A shader that uses one of these fails to compile.
- **Placement where Vulkan allows it** (0003). A placed resource at an offset
  that is not a multiple of its 64 KiB alignment is taken when its Vulkan
  memory allows the offset.
- **A failed resource creation is logged as an error** (0004).

## Why

Unreal Engine 5's Direct3D 12 renderer requires feature level 12_0 and
SM 6.6, and treats any failed resource creation as fatal. Without these
patches, no UE5 game runs on Direct3D 12 here. With them, MultiVersus plays
offline on Direct3D 12, and En Garde! gets past device creation. Faking the
level with `VKD3D_FEATURE_LEVEL=12_0` (Proton's `vkd3dfl12`) would also
report tiled resources tier 2, which KosmicKrisp cannot back, and it would
not give SM 6.6.

## What it costs

- The device claims more than KosmicKrisp does. A game that needs 64-bit
  atomics or derivatives in compute shaders (Nanite, for one) gets shader
  compile failures instead of a clean refusal at start.
- The patches are Playport's own (class `feature` and `diagnostics`) and must
  be carried over each move of the `vkd3d-proton` pin.

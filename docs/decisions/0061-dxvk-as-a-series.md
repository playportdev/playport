# 0061: DXVK carries a patch series, starting with a fix for devices that cannot share memory

**Status:** accepted, 2026-10-06, taken unattended under the owner's answer 4 in the
[Vulkan performance plan](../plans/2026-10-06-vulkan-performance.md) (DXVK and
vkd3d-proton patches are not ruled out; each needs its own record). Changes
[0015](0015-vulkan-backend-accepted.md) and [0032](0032-vkd3d-proton-as-a-series.md)
where they say DXVK stays unmodified.

## Decision

- **`patches/dxvk`**, applied onto the `dxvk` pin by `build/stages/vulkan-pe.sh`
  (`ensure_series`) like `patches/vkd3d-proton`, and part of the `vulkan` stage's
  inputs.
- **0001** (class `upstream-bug`): a texture or fence the game asks to share, on a
  device without `VK_KHR_external_memory_win32`/`_semaphore_win32` (KosmicKrisp), is
  created unshared as DXVK already intends, without calling the device's
  `vkGet*Win32HandleKHR`, which is NULL there. DXVK `master` (read 2026-10-06) has the
  same code.
- Playport's lines in `patches/dxvk` are offered under DXVK's licence (zlib/libpng),
  as 0040 does for the other upstream series.

## Why

Hollow Knight's Media Foundation video path creates a `D3D11_RESOURCE_MISC_SHARED`
texture. DXVK refused to share it but still called the NULL function, and the game ended
with `0xc0000005` 54 s into a new game, on the Direct3D 12 route (4 of 5 plays) and on
DXVK without tiler mode
([evidence](../evidence/2026-10-06-vulkan-perf-baseline.md#stability)). The plan's
stability bar (10/10 plays) cannot be met with it. The bug is DXVK's: KosmicKrisp
correctly does not offer Win32 external memory, and Wine correctly returns no function
for an extension that was not enabled. The fix is the one-line condition the code
already implies (`m_shared`), so it is the change upstream would take.

## Costs

One more series to carry over each `dxvk` pin move, checked by hand against DXVK's
`dxvk_image.cpp` and `dxvk_fence.cpp` there.

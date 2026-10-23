# KosmicKrisp memory priority: host results

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[kk-proton-parity](../plans/2026-10-22-kk-proton-parity.md#b1-vk_ext_memory_priority-and-vk_ext_pageable_device_local_memory),
chunk B1. **Where:** the workstation's host mock of KosmicKrisp (`build/mesa-host-test`), from
the side copy `.work/worktrees/kkparity` (decision 0117). **Not run on the phone.**

**Rebase note (2026-10-23):** These are historical side-copy results, not validation of the
rebased driver. Original Mesa 0104 is now 0119, experimental bit 16, on main base
`26699f6`; fresh validation and the B1 phone gate are in
[phone evidence](2026-10-23-kk-memory-priority-phone.md).

## What changed: `patches/mesa` 0104 (2026-10-22)

- `MESA_KK_EXPERIMENTAL=memory_priority` (`KK_EXPERIMENTAL_MEMORY_PRIORITY`, `1ull << 7`)
  advertises `VK_EXT_memory_priority` and `VK_EXT_pageable_device_local_memory` with their
  `memoryPriority` and `pageableDeviceLocalMemory` features. Without the flag nothing changes.
- A priority changes nothing. `vkAllocateMemory` accepts a `VkMemoryPriorityAllocateInfoEXT`, and
  `vkSetDeviceMemoryPriorityEXT` is a no-op. Every heap stays in the device's one
  `MTLResidencySet`: Metal has no per-allocation priority, and `setPurgeableState` may discard
  the contents.
- With `MESA_KK_DEBUG=memory` and the flag, the `[kk-mem]` line ends in
  `| priority allocations=N sets=N`. The two counts are the allocations that came with a priority
  and the calls to `vkSetDeviceMemoryPriorityEXT`.
- No MSL or cache-key change.

## Host test

`build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest`
exits 0 with 59 `ok` lines. `check_memory_priority` in `kk-host-test.c` makes a device of its own
before the main device:

- **Without the flag** (every other run in `run.sh`): neither extension nor its feature is
  reported, and `vkGetDeviceProcAddr` gives no `vkSetDeviceMemoryPriorityEXT`.
- **With `MESA_KK_EXPERIMENTAL=memory_priority MESA_KK_DEBUG=memory`** (`memory-priority.log`):
  both extensions and features are reported and enabled. One 64 KiB allocation has priority 1.0,
  and `vkSetDeviceMemoryPriorityEXT` is called on it with 0.0 and then 0.5 through the device's
  dispatch:

  ```
  ok memory_priority: an allocation with priority 1.0, then vkSetDeviceMemoryPriorityEXT 0.0 and 0.5
  [kk-mem] metal=0 bos=1 memory=2/0 internal=1/0 descriptor=0/0 query=3/0 command=1/0 | shaders=2 pipelines=1 msl=0.0 | cache raw=0/0.0 precomp=0/0.0 | allocators=1/0.0 MiB | priority allocations=1 sets=2
  MESA_KK_EXPERIMENTAL=memory_priority: 181 MSL libraries, each the one made without it
  ```
- **MSL.** `run.sh` compares every `.metal` from the flag run with the flag-off run: 181/181 are
  byte-identical.
  - Against the MSL saved before 0104, all files are byte-identical: 164/164 `msl`, 217/217
    `msl-gpl` and 25/25 `zink`.
  - From file 34 on, the flag-off numbering is shifted by 17. These 17 files are the internal
    libraries of the extra test device, and each repeats files 17–33 byte for byte.

## Build

`./pp build` in the side copy exits 0. It reran `vulkan` (series changed), `stage`, `notices`, `app`
and `verify`. The IPA is `.work/out/20261022-091048-3393f48f/Playport-26.5-3393f48f.ipa` (in the
side copy), sha256 `3393f48fa071084b53939e63422e79d3c35908e88663da2d20d55aa1559ac3e6`. verify-ipa:
89 checks passed, 0 failed. `./pp test --quick` passes.

## Phone gate: not run

Queued for the main checkout, after the branch moves there:

- Hollow Knight first frame +10 with the flag off;
- the same on DXVK and on `-force-d3d12` (vkd3d-proton), each with `graphicsOptions`
  `MESA_KK_EXPERIMENTAL=memory_priority MESA_KK_DEBUG=memory`.

It passes when the DXVK and vkd3d logs name the extensions, the `[kk-mem]` line counts priorities,
and there are no GPU errors.

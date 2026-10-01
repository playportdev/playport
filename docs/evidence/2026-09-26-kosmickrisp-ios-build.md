# KosmicKrisp builds for iOS

**Date:** 2026-09-26. **Kind:** workstation build only. Nothing was run on the
phone, and no IPA contains the driver.
**Tree:** Mesa `82d4f86a0a1e9f76b2de4fa77c6c8e6acaf06aa9` (`main`,
2026-09-26) plus `patches/mesa` 0001–0004, built by `build/stages/mesa.sh`.
**Toolchain:** host clang/lld 22.1.8, LLVM 22.1.8, SPIRV-LLVM-Translator 22.1.0,
libclc 0.2.0, meson 1.12.1, and xtool's darwin SDK (iPhoneOS26.5.sdk,
MacOSX26.5.sdk).

## Result

- **`libvulkan_kosmickrisp.dylib` builds for `arm64-apple-ios26.0`.** It is a
  thin arm64 Mach-O, `LC_BUILD_VERSION` platform ios, minos 26.0, sdk 26.5,
  14 MB, and it exports the three `vk_icd*` entry points.
- **All its imports resolve on iOS.** `build/check-macho-imports.py` finds
  every non-weak undefined symbol exported, for arm64-ios, by the SDK stubs of
  the nine libraries it links: libSystem, libz, libobjc, libc++, Foundation,
  CoreFoundation, Metal, QuartzCore and CoreGraphics. The weak undefined
  `kk_*` symbols are Mesa's weak entry points and are expected.
- **No Metal API it calls is newer than iOS 26.0.** The 16 Objective-C files
  compile cleanly with `-Wunguarded-availability-new` (the build itself turns
  that warning off for the bridge).
- **macOS is unchanged.** The same patched tree, built for
  `arm64-apple-macos26.0`, resolves every import against MacOSX26.5.sdk.
- **The dylib names no workstation path.** The stage's prefix maps do their
  job, and the check finds neither the repository nor `$HOME` in it.

## What had to change (`patches/mesa`)

Only two compile errors stood between upstream and iOS. Two more problems
compiled without error and would have shown only on the phone.

| Patch | Found by | Change |
| --- | --- | --- |
| 0001 wsi/metal: no displaySyncEnabled on iOS | compile error (the property is unavailable on iOS) | leave vsync to the layer; advertise FIFO only |
| 0002 vulkan: link CoreGraphics for the Metal WSI | the import check: `CGColorSpace*` and `kCGColorSpace*` imported, and no linked iOS library exports them | name CoreGraphics |
| 0003 kk: use the vm_* calls on iOS for placed maps | compile error (`mach_vm.h unsupported`) | `vm_remap`, `vm_map`, `vm_deallocate` on iOS |
| 0004 util: available memory on iOS is the process's limit | reading `os_get_available_system_memory` | `os_proc_available_memory()` for the Vulkan memory budget |

Before 0002, the driver linked without error, because it links with
`-undefined dynamic_lookup`. dyld would have refused it on the phone.

## What this does not show

- That the driver creates a device on the A19 Pro, or which features, limits
  and workarounds it picks there. They depend on the Metal GPU family (10) and
  the OS version (iOS 27), and only a device run can show them.
- That DXVK runs on it. DXVK `52fe923` requires `geometryShader` and
  `fillModeNonSolid`, and KosmicKrisp at this pin advertises neither. This is
  the same on macOS ([decision 0014](../decisions/0014-vulkan-through-kosmickrisp.md)).
- Anything about Wine. Nothing in Wine can reach Vulkan on iOS yet.

## Reproduce

```sh
build/stages/mesa.sh "$PLAYPORT_BUILD/run/mesa"   # src host ios check
```
